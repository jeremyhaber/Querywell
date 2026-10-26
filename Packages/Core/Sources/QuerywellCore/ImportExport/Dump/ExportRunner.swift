import Foundation

// Executes an ``ExportPlan``: runs the steps, streams their stdout through the local stages
// (gunzip → collation rewrite → gzip, as the plan requires) into the destination file, reports
// per-table progress parsed from the tools' `--verbose` stderr, and cleans up on failure or cancel.

public enum ExportEvent: Sendable, Equatable {
    case started(steps: Int)
    /// A table began dumping. `total` is known when the plan lists the tables.
    case table(name: String, index: Int, total: Int?)
    /// Bytes written to the destination so far (throttled).
    case bytes(Int64)
    /// A stderr line that is not routine progress (warnings, ssh notices, errors).
    case log(String)
}

public struct ExportSummary: Sendable, Equatable {
    public var destination: URL
    public var bytesWritten: Int64
    public var tables: [String]
    public var duration: Duration
    public var warnings: [String]
}

public enum ExportError: Error, Sendable, Equatable, LocalizedError {
    case ssh(SSHTunnelError)
    case processFailed(status: Int32, stderrTail: String)
    case launchFailed(String)
    case io(String)
    case gzip(String)

    public var errorDescription: String? {
        switch self {
        case .ssh(let e): "SSH: \(e)"
        case .processFailed(let status, let tail):
            tail.isEmpty ? "The dump command failed (exit status \(status))." : "The dump command failed (exit status \(status)): \(tail)"
        case .launchFailed(let m): "Could not start the dump command: \(m)"
        case .io(let m): "Could not write the export: \(m)"
        case .gzip(let m): m
        }
    }
}

// MARK: - Stream pipeline

/// The local byte stages between the dump process and the file. One instance per export.
final class ExportStreamPipeline: @unchecked Sendable {
    // @unchecked Sendable: only one stdout reader thread writes at a time (steps run sequentially); the
    // owning task touches it again only after that reader has finished (dispatch-group join).
    private let decompressor: GzipDecompressor?
    private let rewriter: CollationRewriter?
    private let compressor: GzipCompressor?
    private let handle: FileHandle
    private(set) var bytesWritten: Int64 = 0

    init(plan: ExportPlan, handle: FileHandle) throws {
        self.handle = handle
        let needsGunzip = plan.remoteCompressed && (plan.collation != nil || !plan.outputCompressed)
        let needsGzip = plan.outputCompressed && (!plan.remoteCompressed || plan.collation != nil)
        decompressor = needsGunzip ? try GzipDecompressor() : nil
        rewriter = plan.collation.map { CollationRewriter(mapping: $0) }
        compressor = needsGzip ? try GzipCompressor() : nil
    }

    func write(_ chunk: Data) throws {
        var data = chunk
        if let decompressor { data = try decompressor.decompress(data) }
        if let rewriter { data = rewriter.feed(data) }
        if let compressor { data = try compressor.compress(data) }
        try emit(data)
    }

    func finish() throws {
        var tail = Data()
        if let decompressor { try decompressor.finish() }
        if let rewriter { tail = rewriter.finish() }
        if let compressor {
            tail = try compressor.compress(tail)
            tail.append(try compressor.finish())
        }
        try emit(tail)
    }

    private func emit(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        bytesWritten += Int64(data.count)
    }
}

// MARK: - Progress parsing

/// Turns mysqldump / pg_dump `--verbose` stderr lines into table events.
struct DumpProgressParser {
    enum Item: Equatable {
        case table(String)
        case routine
        case other(String)
    }

    var structureOnly = false
    private var sawStructureForCurrent = false

    init(structureOnly: Bool = false) { self.structureOnly = structureOnly }

    mutating func parse(_ line: String) -> Item {
        // mysqldump
        if let name = Self.capture(#"^-- Retrieving table structure for table (.+?)\.\.\.$"#, line) {
            sawStructureForCurrent = true
            return .table(name)
        }
        if line.hasPrefix("-- Sending SELECT query") {
            if sawStructureForCurrent { sawStructureForCurrent = false; return .routine }
            return .table("")  // data-only: the tool doesn't name the table
        }
        if line.hasPrefix("-- Retrieving") || line.hasPrefix("-- Connecting to") || line.hasPrefix("-- Disconnecting from") {
            return .routine
        }
        // pg_dump
        if let name = Self.capture(#"^pg_dump: dumping contents of table "(.+)"$"#, line) { return .table(name) }
        if structureOnly, let name = Self.capture(#"^pg_dump: creating TABLE "(.+)"$"#, line) { return .table(name) }
        if line.hasPrefix("pg_dump: ") && !line.contains("error") && !line.contains("warning") && !line.contains("cannot") { return .routine }
        return .other(line)
    }

    private static func capture(_ pattern: String, _ line: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: line) else { return nil }
        return String(line[r])
    }
}

// MARK: - Runner

public struct ExportRunner: Sendable {
    public let secretStore: any SecretStore

    public init(secretStore: any SecretStore) {
        self.secretStore = secretStore
    }

    /// Runs `plan`, writing the dump to `destination`.
    ///
    /// The file is written next to the destination as a hidden `.part` file and moved into place only on
    /// success; on failure or cancellation it is deleted, so a partial dump never masquerades as a backup.
    /// Cancelling the calling task terminates the ssh / dump process and throws `CancellationError`. A
    /// cancelled *remote* export ends because the SSH connection closes: the server-side dump dies on its
    /// next write (SIGPIPE) and the temp credentials file is removed by the script's trap.
    @discardableResult
    public func run(plan: ExportPlan, to destination: URL,
                    onEvent: @escaping @Sendable (ExportEvent) -> Void = { _ in }) async throws -> ExportSummary {
        let clock = ContinuousClock()
        let start = clock.now
        let fm = FileManager.default
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).part")
        guard fm.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ExportError.io("cannot create \(partial.path)")
        }
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: partial) } catch {
            try? fm.removeItem(at: partial)
            throw ExportError.io(error.localizedDescription)
        }
        let control = RunControl()
        let tracker = TableTracker(known: plan.tables, structureOnly: plan.steps.contains { $0.arguments.contains("--no-data") || $0.arguments.contains("--schema-only") },
                                   onEvent: onEvent)
        do {
            let pipeline = try ExportStreamPipeline(plan: plan, handle: handle)
            onEvent(.started(steps: plan.steps.count))
            try await withTaskCancellationHandler {
                for step in plan.steps {
                    try Task.checkCancellation()
                    try await runStep(step, plan: plan, pipeline: pipeline, control: control, tracker: tracker, onEvent: onEvent)
                }
                if control.isCancelled { throw CancellationError() }
                try pipeline.finish()
            } onCancel: {
                control.cancel()
            }
            try handle.synchronize()
            try handle.close()
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: partial, to: destination)
            onEvent(.bytes(pipeline.bytesWritten))
            return ExportSummary(destination: destination, bytesWritten: pipeline.bytesWritten, tables: tracker.tables,
                                 duration: clock.now - start, warnings: plan.warnings)
        } catch {
            try? handle.close()
            try? fm.removeItem(at: partial)
            if error is CancellationError || control.isCancelled { throw CancellationError() }
            if let e = error as? GzipError { throw ExportError.gzip(e.localizedDescription) }
            throw error
        }
    }

    // MARK: One step

    private func runStep(_ step: CommandStep, plan: ExportPlan, pipeline: ExportStreamPipeline, control: RunControl,
                         tracker: TableTracker, onEvent: @escaping @Sendable (ExportEvent) -> Void) async throws {
        let fm = FileManager.default
        var secretDir: URL?
        var askpass: SSHAskpass?
        defer {
            if let secretDir { try? fm.removeItem(at: secretDir) }
            askpass?.cleanup()
        }

        var arguments = step.arguments
        if !step.secretFiles.isEmpty {
            let dir = fm.temporaryDirectory.appendingPathComponent("querywell-secret-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            secretDir = dir
            for file in step.secretFiles {
                let url = dir.appendingPathComponent(file.name)
                guard fm.createFile(atPath: url.path, contents: file.contents, attributes: [.posixPermissions: 0o600]) else {
                    throw ExportError.io("cannot write a temporary credentials file")
                }
            }
            arguments = arguments.map { $0.replacingOccurrences(of: DumpPlaceholders.secretDirectory, with: dir.path) }
        }

        var env = ProcessInfo.processInfo.environment
        for (k, v) in step.environment { env[k] = v }
        if step.usesSSH {
            env["SSH_ASKPASS"] = nil
            env["SSH_ASKPASS_REQUIRE"] = nil
            env["DISPLAY"] = nil
            if let key = plan.sshSecretKey, let secret = try? secretStore.read(key), !secret.isEmpty {
                let a = try SSHAskpass.create(secret: secret)
                askpass = a
                env.merge(a.environment) { _, new in new }
            }
        }

        guard fm.isExecutableFile(atPath: step.executable) else {
            throw step.usesSSH ? ExportError.ssh(.sshNotFound(step.executable)) : ExportError.launchFailed("\(step.executable) was not found")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: step.executable)
        process.arguments = arguments
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = step.standardInput == nil ? FileHandle.nullDevice : stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let state = StepState()
        let group = DispatchGroup()
        let exited = ExitSignal()
        process.terminationHandler = { _ in exited.fire() }
        do { try process.run() } catch { throw ExportError.launchFailed(error.localizedDescription) }
        control.set(process)
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        if step.standardInput != nil { try? stdin.fileHandleForReading.close() }

        if let input = step.standardInput {
            group.enter()
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
                group.leave()
            }
        }
        group.enter()
        DispatchQueue.global().async {
            var lastReport = ContinuousClock.now
            let reader = stdout.fileHandleForReading
            while true {
                guard let chunk = try? reader.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
                do { try pipeline.write(chunk) } catch {
                    state.setFailure(error)
                    control.terminateProcess()
                    // keep draining so the child isn't blocked on a full pipe while it dies
                    while let rest = try? reader.read(upToCount: 256 * 1024), !rest.isEmpty {}
                    break
                }
                if ContinuousClock.now - lastReport > .milliseconds(150) {
                    lastReport = ContinuousClock.now
                    onEvent(.bytes(pipeline.bytesWritten))
                }
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            let reader = stderr.fileHandleForReading
            var buffer = Data()
            func handle(_ line: String) {
                guard !line.isEmpty else { return }
                state.appendTail(line)
                tracker.consume(line)
            }
            while let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    handle(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                    buffer.removeSubrange(buffer.startIndex...nl)
                }
            }
            handle(String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            group.leave()
        }

        await exited.wait()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { c.resume() }
        }
        control.clear()

        if control.isCancelled { throw CancellationError() }
        if let failure = state.failure { throw failure }
        let status = process.terminationStatus
        if status != 0 {
            let tail = state.tail
            if step.usesSSH, status == 255 { throw ExportError.ssh(SSHErrorMapper.map(status: status, stderr: tail)) }
            throw ExportError.processFailed(status: status, stderrTail: Self.cleanTail(tail))
        }
    }

    static func cleanTail(_ tail: String) -> String {
        // Drop routine verbose chatter so the failure reason is what the user sees.
        tail.split(separator: "\n").filter { !$0.hasPrefix("-- ") && !$0.hasPrefix("WARNING: option --ssl-verify-server-cert") }
            .suffix(8).joined(separator: "\n")
    }
}

// MARK: - Run plumbing

/// Tracks the process of the running step so a cancellation can terminate it.
final class RunControl: @unchecked Sendable {
    // @unchecked Sendable: all state is guarded by `lock`.
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func set(_ p: Process) {
        let shouldKill = lock.withLock { () -> Bool in
            process = p
            return cancelled
        }
        if shouldKill { terminate(p) }
    }

    func clear() { lock.withLock { process = nil } }

    func cancel() {
        let p = lock.withLock { () -> Process? in
            cancelled = true
            return process
        }
        if let p { terminate(p) }
    }

    func terminateProcess() {
        if let p = lock.withLock({ process }) { terminate(p) }
    }

    private func terminate(_ p: Process) {
        guard p.isRunning else { return }
        let pid = p.processIdentifier
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }
}

final class StepState: @unchecked Sendable {
    // @unchecked Sendable: all state is guarded by `lock`.
    private let lock = NSLock()
    private var _failure: (any Error)?
    private var _tail: [String] = []

    var failure: (any Error)? { lock.withLock { _failure } }
    var tail: String { lock.withLock { _tail.joined(separator: "\n") } }

    func setFailure(_ e: any Error) { lock.withLock { if _failure == nil { _failure = e } } }
    func appendTail(_ line: String) {
        lock.withLock {
            _tail.append(line)
            if _tail.count > 200 { _tail.removeFirst(_tail.count - 200) }
        }
    }
}

/// One-shot async signal fired from a termination handler.
final class ExitSignal: @unchecked Sendable {
    // @unchecked Sendable: all state is guarded by `lock`.
    private let lock = NSLock()
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?

    func fire() {
        let w = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            fired = true
            defer { waiter = nil }
            return waiter
        }
        w?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if fired { return true }
                waiter = c
                return false
            }
            if resumeNow { c.resume() }
        }
    }
}

/// Converts parsed stderr lines into table events with index/total.
final class TableTracker: @unchecked Sendable {
    // @unchecked Sendable: all state is guarded by `lock`; the callback is invoked outside the lock.
    private let lock = NSLock()
    private var parser: DumpProgressParser
    private var seen: [String] = []
    private let known: [String]?
    private let onEvent: @Sendable (ExportEvent) -> Void

    init(known: [String]?, structureOnly: Bool, onEvent: @escaping @Sendable (ExportEvent) -> Void) {
        self.known = known
        self.parser = DumpProgressParser(structureOnly: structureOnly)
        self.onEvent = onEvent
    }

    var tables: [String] { lock.withLock { seen } }

    func consume(_ line: String) {
        let event: ExportEvent? = lock.withLock {
            switch parser.parse(line) {
            case .routine: return nil
            case .other(let text): return .log(text)
            case .table(var name):
                if name.isEmpty { name = known.flatMap { seen.count < $0.count ? $0[seen.count] : nil } ?? "table \(seen.count + 1)" }
                if seen.last == name { return nil }
                seen.append(name)
                return .table(name: name, index: seen.count, total: known?.count)
            }
        }
        if let event { onEvent(event) }
    }
}
