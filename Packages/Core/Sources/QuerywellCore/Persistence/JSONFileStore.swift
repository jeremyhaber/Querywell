import Foundation

/// Shared JSON configuration and atomic file writing for on-disk state.
public enum JSONFileStore {
    /// Sorted keys, pretty printed, ISO8601 dates.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Writes `data` atomically, creating parent directories and optionally setting POSIX permissions.
    public static func writeAtomically(_ data: Data, to url: URL, permissions: Int? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if let permissions {
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }
}
