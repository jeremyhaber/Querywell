import Foundation
import Testing

@testable import QuerywellCore

private let integrationEnabled = ProcessInfo.processInfo.environment["QUERYWELL_INTEGRATION"] == "1"

@Suite("Cancelling running statements", .serialized, .enabled(if: integrationEnabled))
struct CancelIntegrationTests {
    private func sleepSQL(_ target: DBTarget, seconds: Int = 10) -> String {
        target.isPostgres ? "SELECT pg_sleep(\(seconds))" : "SELECT SLEEP(\(seconds))"
    }

    @Test("cancelCurrentQuery aborts a running statement and the session stays usable", arguments: DBTarget.all)
    func stopButton(_ target: DBTarget) async throws {
        let session = try await target.connect()
        let sql = sleepSQL(target)
        let running = Task { () -> Result<QueryResult, any Error> in
            do { return .success(try await session.execute(sql)) } catch { return .failure(error) }
        }
        try await Task.sleep(for: .milliseconds(400))
        let clock = ContinuousClock()
        let start = clock.now
        try await session.cancelCurrentQuery()
        let outcome = await running.value
        let elapsed = start.duration(to: clock.now)
        #expect(elapsed < .seconds(5), "cancel took \(elapsed)")
        switch outcome {
        case .success(let result):
            // MySQL's SLEEP returns 1 when interrupted instead of failing.
            if target.isPostgres { Issue.record("pg_sleep was not interrupted: \(result.rows)") }
            else { #expect(result.rows.first?.first == .integer(1) || result.rows.first?.first == .text("1")) }
        case .failure(let error):
            #expect((error as? DatabaseError)?.isCancelled == true, "unexpected error: \(error)")
        }
        // The next statement is not affected by the earlier kill.
        let after = try await session.execute("SELECT 42")
        #expect(after.rows.first?.first.map { Record.int(from: $0) } == 42)
        await session.close()
    }

    @Test("cancelling the awaiting task aborts only its own statement", arguments: DBTarget.all)
    func taskCancellation(_ target: DBTarget) async throws {
        let session = try await target.connect()
        let sql = sleepSQL(target)
        let clock = ContinuousClock()
        let start = clock.now
        let running = Task { () -> Result<QueryResult, any Error> in
            do { return .success(try await session.execute(sql, interruptible: true)) } catch { return .failure(error) }
        }
        try await Task.sleep(for: .milliseconds(400))
        running.cancel()
        let outcome = await running.value
        #expect(start.duration(to: clock.now) < .seconds(6))
        if case .failure(let error) = outcome {
            #expect(error is CancellationError, "got \(error)")
        } else if target.isPostgres {
            Issue.record("pg_sleep was not interrupted")
        }
        #expect(try await session.execute("SELECT 1").rows.count == 1)
        await session.close()
    }

    @Test("a cancelled statement waiting behind another never reaches the server", arguments: DBTarget.all)
    func queuedCancel(_ target: DBTarget) async throws {
        let session = try await target.connect()
        let first = Task { try? await session.execute(sleepSQL(target, seconds: 2)) }
        try await Task.sleep(for: .milliseconds(300))
        let queued = Task { () -> Bool in
            do { _ = try await session.execute("SELECT 7", interruptible: true); return false } catch { return error is CancellationError }
        }
        try await Task.sleep(for: .milliseconds(100))
        queued.cancel()
        _ = await first.value
        #expect(await queued.value)
        // The long statement was not the cancel target.
        #expect(try await session.execute("SELECT 1").rows.count == 1)
        await session.close()
    }

    @Test("cancelCurrentQuery when idle is a no-op", arguments: DBTarget.all)
    func idleCancel(_ target: DBTarget) async throws {
        let session = try await target.connect()
        try await session.cancelCurrentQuery()
        #expect(try await session.execute("SELECT 1").rows.count == 1)
        await session.close()
    }
}
