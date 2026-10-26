import Foundation

/// Locations of the app's on-disk state.
public enum AppDirectories {
    public static let connectionsFileName = "connections.json"

    /// `~/Library/Application Support/<appName>`, created if needed.
    public static func applicationSupport(
        appName: String = "Querywell",
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent(appName, isDirectory: true)
        // Owner-only, so files inside are never briefly world-readable during atomic writes.
        try fileManager.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// The `connections.json` location inside the app's Application Support directory.
    public static func connectionsFileURL(
        appName: String = "Querywell",
        fileManager: FileManager = .default
    ) throws -> URL {
        try applicationSupport(appName: appName, fileManager: fileManager)
            .appendingPathComponent(connectionsFileName, isDirectory: false)
    }
}
