import Foundation

/// Opens tunnels with the system OpenSSH client (`ssh -N -L`). See DECISIONS #13.
public struct SystemSSHTunnelProvider: SSHTunnelProvider {
    public var options: SSHClientOptions

    public init(options: SSHClientOptions = SSHClientOptions()) {
        self.options = options
    }

    public func open(_ request: SSHTunnelRequest) async throws -> any SSHTunnel {
        // The free port is probed then handed to ssh, so another socket (another tunnel, or any
        // outbound connection's ephemeral port) can take it in between. ssh then exits with
        // "Address already in use" (ExitOnForwardFailure); retry on a fresh port.
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await openOnce(request)
            } catch let error as SSHTunnelError {
                guard attempt < 3, case .forwardFailed(let text) = error,
                      text.lowercased().contains("address already in use") else { throw error }
            }
        }
    }

    private func openOnce(_ request: SSHTunnelRequest) async throws -> any SSHTunnel {
        guard FileManager.default.isExecutableFile(atPath: options.sshExecutable) else {
            throw SSHTunnelError.sshNotFound(options.sshExecutable)
        }
        let secret = request.secret.flatMap { $0.isEmpty ? nil : $0 }
        let needsSecret: Bool
        switch request.ssh.auth {
        case .password, .keyFile: needsSecret = secret != nil
        case .agent: needsSecret = false
        }

        var askpass: SSHAskpass?
        if needsSecret, let secret { askpass = try SSHAskpass.create(secret: secret) }
        defer { askpass?.cleanup() }  // tunnel is up, failed or cancelled by then

        let comps = request.connectTimeout.components
        let seconds = max(1, Int((Double(comps.seconds) + Double(comps.attoseconds) / 1e18).rounded(.up)))
        let localPort = try LoopbackPort.findFree()
        let args = SSHCommandBuilder.tunnelArguments(
            for: request.ssh, options: options, hasSecret: needsSecret, localPort: localPort,
            remoteHost: request.remoteHost, remotePort: request.remotePort, connectTimeoutSeconds: seconds)

        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = nil
        env["SSH_ASKPASS_REQUIRE"] = nil
        env["DISPLAY"] = nil
        if let askpass { env.merge(askpass.environment) { _, new in new } }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: options.sshExecutable)
        process.arguments = args
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        let collector = StderrCollector()
        do {
            try process.run()
        } catch {
            throw SSHTunnelError.sshNotFound("\(options.sshExecutable): \(error.localizedDescription)")
        }
        try? errPipe.fileHandleForWriting.close()
        collector.startReading(errPipe.fileHandleForReading)
        let tunnel = SystemSSHTunnel(process: process, localPort: localPort, stderr: collector)

        let deadline = ContinuousClock.now + request.connectTimeout + .seconds(2)
        do {
            while true {
                try Task.checkCancellation()
                if !process.isRunning {
                    await collector.waitForEOF(timeout: 1.5)
                    throw SSHErrorMapper.map(status: process.terminationStatus, stderr: collector.text)
                }
                if LoopbackPort.isInUse(localPort) { break }
                if ContinuousClock.now >= deadline { throw SSHTunnelError.timeout }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            await tunnel.close()
            throw error
        }
        return tunnel
    }
}

/// Drains ssh's stderr continuously (so the pipe never fills) keeping the last 64 KB.
final class StderrCollector: @unchecked Sendable {
    // @unchecked Sendable: all mutable state is guarded by `lock`.
    private let lock = NSLock()
    private var buffer = Data()
    private var eof = false

    func startReading(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                buffer.append(chunk)
                if buffer.count > 65_536 { buffer.removeFirst(buffer.count - 65_536) }
                lock.unlock()
            }
            lock.lock()
            eof = true
            lock.unlock()
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }

    private var isEOF: Bool { lock.withLock { eof } }

    func waitForEOF(timeout: Double) async {
        let end = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < end {
            if isEOF { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// A running `ssh -N -L` process.
public final class SystemSSHTunnel: SSHTunnel, @unchecked Sendable {
    // @unchecked Sendable: `Process` is not Sendable, but it is only configured before the tunnel is
    // published and afterwards only queried (`isRunning`) or signalled via kill(2); the `closing` flag
    // is guarded by `lock`.
    public let localHost = "127.0.0.1"
    public let localPort: Int
    private let process: Process
    private let stderr: StderrCollector
    private let lock = NSLock()
    private var closing = false

    init(process: Process, localPort: Int, stderr: StderrCollector) {
        self.process = process
        self.localPort = localPort
        self.stderr = stderr
    }

    public var isRunning: Bool { process.isRunning }

    /// Recent ssh stderr output, for diagnostics.
    public var stderrOutput: String { stderr.text }

    public var forwardFailure: String? {
        SSHErrorMapper.forwardFailure(in: stderr.text)
    }

    public func close() async {
        let already = markClosing()
        guard process.isRunning else { return }
        if !already { kill(process.processIdentifier, SIGTERM) }
        if await waitForExit(seconds: 2) { return }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        _ = await waitForExit(seconds: 2)
    }

    private func markClosing() -> Bool {
        lock.withLock {
            let was = closing
            closing = true
            return was
        }
    }

    private func waitForExit(seconds: Double) async -> Bool {
        let end = ContinuousClock.now + .seconds(seconds)
        while process.isRunning {
            if ContinuousClock.now >= end { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    deinit {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
