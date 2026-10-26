import Foundation

public enum MaintenanceEvent: Sendable, Hashable {
    case started(MaintenanceStep)
    case finished(MaintenanceStep, Duration)
    case failed(MaintenanceStep, String)
    case skipped(MaintenanceStep, String)
    /// Always the last event.
    case completed(MaintenanceReport)
}

public enum MaintenanceStepOutcome: Sendable, Hashable {
    case succeeded(Duration)
    case failed(String)
    case skipped(String)
    /// Never started: the run was cancelled, or stopped after an earlier error.
    case notRun(NotRunReason)

    public enum NotRunReason: Sendable, Hashable { case cancelled, stoppedAfterError }
}

public struct MaintenanceReport: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public var step: MaintenanceStep
        public var outcome: MaintenanceStepOutcome
    }

    public var entries: [Entry]
    public var wasCancelled: Bool
    public var stoppedOnError: Bool
    public var duration: Duration

    public var succeededCount: Int { entries.filter { if case .succeeded = $0.outcome { true } else { false } }.count }
    public var failedCount: Int { entries.filter { if case .failed = $0.outcome { true } else { false } }.count }
    public var skippedCount: Int { entries.filter { if case .skipped = $0.outcome { true } else { false } }.count }
    public var notRunCount: Int { entries.filter { if case .notRun = $0.outcome { true } else { false } }.count }
    /// Every step either succeeded or was skipped.
    public var isClean: Bool { failedCount == 0 && notRunCount == 0 }
}

/// Runs a ``MaintenancePlan`` sequentially on one session with progress events.
public actor MaintenanceRunner {
    private let session: any DatabaseSession
    private var task: Task<MaintenanceReport, Never>?

    public init(session: any DatabaseSession) {
        self.session = session
    }

    /// Starts the run and returns a stream of progress events, ending with `.completed(report)`.
    /// Cancelling (``cancel()`` or dropping the stream) stops after the statement in flight.
    public func run(_ plan: MaintenancePlan, stopOnError: Bool = true) -> AsyncStream<MaintenanceEvent> {
        task?.cancel()
        let (stream, continuation) = AsyncStream<MaintenanceEvent>.makeStream(bufferingPolicy: .unbounded)
        let session = self.session
        let newTask = Task.detached {
            let report = await Self.execute(plan, stopOnError: stopOnError, session: session) { continuation.yield($0) }
            continuation.yield(.completed(report))
            continuation.finish()
            return report
        }
        task = newTask
        continuation.onTermination = { _ in newTask.cancel() }
        return stream
    }

    /// Runs to the end (honouring cancellation of the calling task) and returns the final report.
    public func runToCompletion(_ plan: MaintenancePlan, stopOnError: Bool = true) async -> MaintenanceReport {
        await Self.execute(plan, stopOnError: stopOnError, session: session) { _ in }
    }

    /// Stops after the current statement; remaining steps are reported as not run.
    public func cancel() {
        task?.cancel()
    }

    private static func execute(
        _ plan: MaintenancePlan, stopOnError: Bool, session: any DatabaseSession,
        emit: @Sendable (MaintenanceEvent) -> Void
    ) async -> MaintenanceReport {
        let clock = ContinuousClock()
        let runStart = clock.now
        var entries: [MaintenanceReport.Entry] = []
        var cancelled = false
        var stopped = false

        for step in plan.steps {
            if let reason = step.skipped {
                emit(.skipped(step, reason))
                entries.append(.init(step: step, outcome: .skipped(reason)))
                continue
            }
            if Task.isCancelled || cancelled {
                cancelled = true
                entries.append(.init(step: step, outcome: .notRun(.cancelled)))
                continue
            }
            if stopped {
                entries.append(.init(step: step, outcome: .notRun(.stoppedAfterError)))
                continue
            }
            emit(.started(step))
            let start = clock.now
            do {
                _ = try await session.execute(step.sql)
                let elapsed = clock.now - start
                emit(.finished(step, elapsed))
                entries.append(.init(step: step, outcome: .succeeded(elapsed)))
            } catch {
                let message = EditSession.describe(error)
                emit(.failed(step, message))
                entries.append(.init(step: step, outcome: .failed(message)))
                if stopOnError { stopped = true }
            }
        }
        return MaintenanceReport(
            entries: entries, wasCancelled: cancelled, stoppedOnError: stopped, duration: clock.now - runStart)
    }
}
