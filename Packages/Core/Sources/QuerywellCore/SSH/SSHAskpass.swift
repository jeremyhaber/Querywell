import Foundation

/// A throwaway SSH_ASKPASS helper: a 0700 temp directory holding the secret (0600) and a tiny script (0700)
/// that prints it. The secret never appears in argv or the environment. Call ``cleanup()`` as soon as ssh
/// has authenticated (or failed).
public struct SSHAskpass: Sendable {
    public let directory: URL
    public let scriptURL: URL
    public let secretURL: URL

    public static func create(secret: String, in base: URL = FileManager.default.temporaryDirectory) throws -> SSHAskpass {
        let dir = base.appendingPathComponent("querywell-askpass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let secretURL = dir.appendingPathComponent("secret")
        let scriptURL = dir.appendingPathComponent("askpass.sh")
        do {
            try writeExclusive(Data(secret.utf8), to: secretURL, mode: 0o600)
            let quoted = "'" + secretURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            try writeExclusive(Data("#!/bin/sh\nexec /bin/cat \(quoted)\n".utf8), to: scriptURL, mode: 0o700)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return SSHAskpass(directory: dir, scriptURL: scriptURL, secretURL: secretURL)
    }

    /// Environment additions that make ssh use the helper even without a TTY or DISPLAY.
    public var environment: [String: String] {
        ["SSH_ASKPASS": scriptURL.path, "SSH_ASKPASS_REQUIRE": "force"]
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func writeExclusive(_ data: Data, to url: URL, mode: mode_t) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        defer { close(fd) }
        fchmod(fd, mode)  // independent of umask
        try data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 { throw CocoaError(.fileWriteUnknown) }
                offset += n
            }
        }
    }
}
