import Foundation

// Locating and choosing the local command-line clients (mysqldump, pg_dump, …) used by export/import.

public enum ToolFlavour: String, Sendable, Hashable {
    case mysql, mariadb, postgres
}

public enum ToolRole: String, Sendable, Hashable {
    /// `mysqldump`, `mariadb-dump`, `pg_dump`
    case dump
    /// `mysql`, `mariadb`, `psql`
    case client
    /// `pg_restore`
    case restore
}

public struct ToolVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (a: ToolVersion, b: ToolVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

public struct ToolInfo: Sendable, Hashable {
    /// Absolute path of the executable (as found, symlinks not resolved).
    public var path: String
    /// File name, e.g. `mysqldump`.
    public var name: String
    public var role: ToolRole
    public var flavour: ToolFlavour
    /// The *tool's* version. For MariaDB tools this is the MariaDB release (10.11.6, 11.4.2), not the
    /// client library number (`Ver 10.19`) printed by the same binary.
    public var version: ToolVersion
    /// First line of `--version`, for display and diagnostics.
    public var versionOutput: String

    public init(path: String, name: String, role: ToolRole, flavour: ToolFlavour, version: ToolVersion, versionOutput: String) {
        self.path = path
        self.name = name
        self.role = role
        self.flavour = flavour
        self.version = version
        self.versionOutput = versionOutput
    }
}

// MARK: - Version parsing

public enum DumpToolVersionParser {
    /// Parses the output of `<tool> --version`. Real-world shapes handled:
    ///
    /// ```
    /// mysqldump  Ver 8.0.36 for macos14.2 on arm64 (Homebrew)
    /// mysqldump  Ver 10.13 Distrib 5.7.44, for Linux (x86_64)
    /// mysqldump  Ver 10.19 Distrib 10.11.6-MariaDB, for debian-linux-gnu (x86_64)
    /// mariadb-dump from 11.8.2-MariaDB, client 10.19 for osx10.20 (arm64)
    /// mysql  Ver 15.1 Distrib 10.5.18-MariaDB, for debian-linux-gnu (x86_64) using  EditLine wrapper
    /// pg_dump (PostgreSQL) 16.4 (Homebrew)      pg_dump (PostgreSQL) 17beta1      psql (PostgreSQL) 14.12 (Ubuntu …)
    /// ```
    public static func parse(_ output: String, toolName: String) -> (flavour: ToolFlavour, version: ToolVersion)? {
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? output
        if toolName.hasPrefix("pg_") || toolName == "psql" {
            guard let m = firstMatch(#"\(PostgreSQL\)\s+(\d+)(?:\.(\d+))?(?:\.(\d+))?"#, in: line),
                  let major = Int(m[1] ?? "") else { return nil }
            return (.postgres, ToolVersion(major, Int(m[2] ?? "") ?? 0, Int(m[3] ?? "") ?? 0))
        }
        let isMaria = line.localizedCaseInsensitiveContains("mariadb")
        let patterns = [
            #"Distrib\s+(\d+)\.(\d+)(?:\.(\d+))?"#,   // server-release number for old-style output
            #"from\s+(\d+)\.(\d+)(?:\.(\d+))?-MariaDB"#,
            #"Ver\s+(\d+)\.(\d+)(?:\.(\d+))?"#,
        ]
        for p in patterns {
            // For MariaDB the bare "Ver 10.19" is the client library number, only usable as a last resort.
            if let m = firstMatch(p, in: line), let major = Int(m[1] ?? "") {
                return (isMaria ? .mariadb : .mysql, ToolVersion(major, Int(m[2] ?? "") ?? 0, Int(m[3] ?? "") ?? 0))
            }
        }
        return nil
    }

    /// Capture groups (index 0 = whole match) of the first match, `nil` entries for unmatched groups.
    static func firstMatch(_ pattern: String, in text: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) }
        }
    }
}

// MARK: - Process runner / file system seams

public struct ProcessOutput: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs a short-lived process to completion. Injected so tests don't need real tools.
public protocol ProcessRunning: Sendable {
    func run(executable: String, arguments: [String]) async throws -> ProcessOutput
}

/// `Process`-based runner with a timeout (default 10 s).
public struct SystemProcessRunner: ProcessRunning {
    public var timeout: Duration

    public init(timeout: Duration = .seconds(10)) { self.timeout = timeout }

    public func run(executable: String, arguments: [String]) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let outBox = DataBox(), errBox = DataBox()
        let group = DispatchGroup()
        group.enter(); group.enter()
        DispatchQueue.global().async { outBox.set(out.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        DispatchQueue.global().async { errBox.set(err.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        try process.run()
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        let deadline = ContinuousClock.now + timeout
        while process.isRunning {
            if ContinuousClock.now >= deadline { process.terminate(); break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Poll instead of waitUntilExit(), which can wedge a cooperative-pool thread.
        while process.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { c.resume() }
        }
        return ProcessOutput(status: process.terminationStatus,
                             stdout: String(decoding: outBox.get(), as: UTF8.self),
                             stderr: String(decoding: errBox.get(), as: UTF8.self))
    }
}

final class DataBox: @unchecked Sendable {
    // @unchecked Sendable: written once by a reader thread, read after the dispatch group completes.
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.withLock { data = d } }
    func get() -> Data { lock.withLock { data } }
}

public protocol ToolFileSystem: Sendable {
    func isExecutable(_ path: String) -> Bool
    /// Entry names (not paths) of a directory; empty when it doesn't exist.
    func contents(ofDirectory path: String) -> [String]
    func resolveSymlinks(_ path: String) -> String
}

public struct LocalToolFileSystem: ToolFileSystem {
    public init() {}
    public func isExecutable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
    public func contents(ofDirectory path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
    public func resolveSymlinks(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

// MARK: - Locator

/// Finds mysqldump / mariadb-dump / mysql / mariadb / pg_dump / psql / pg_restore on this Mac.
public struct DumpToolLocator: Sendable {
    public static let toolNames: [(name: String, role: ToolRole)] = [
        ("mysqldump", .dump), ("mariadb-dump", .dump), ("mysql", .client), ("mariadb", .client),
        ("pg_dump", .dump), ("psql", .client), ("pg_restore", .restore),
    ]

    public var fileSystem: any ToolFileSystem
    public var runner: any ProcessRunning
    /// Value of `$PATH`; searched last.
    public var pathEnvironment: String
    /// Install prefixes to look under (`<prefix>/bin`, `<prefix>/opt/<pkg>/bin`).
    public var prefixes: [String]
    public var postgresAppVersionsDirectory: String

    public init(
        fileSystem: any ToolFileSystem = LocalToolFileSystem(),
        runner: any ProcessRunning = SystemProcessRunner(),
        pathEnvironment: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        prefixes: [String] = ["/opt/homebrew", "/usr/local"],
        postgresAppVersionsDirectory: String = "/Applications/Postgres.app/Contents/Versions"
    ) {
        self.fileSystem = fileSystem
        self.runner = runner
        self.pathEnvironment = pathEnvironment
        self.prefixes = prefixes
        self.postgresAppVersionsDirectory = postgresAppVersionsDirectory
    }

    /// Directories searched, in priority order.
    public func searchDirectories() -> [String] {
        var dirs: [String] = []
        let fixedPackages = ["mysql-client", "mysql", "mariadb", "libpq", "postgresql"]
        for prefix in prefixes {
            dirs.append(prefix + "/bin")
            for pkg in fixedPackages { dirs.append("\(prefix)/opt/\(pkg)/bin") }
            // Versioned formulae: postgresql@16, mysql@8.4, mariadb@11.4, libpq@18 …
            let opt = prefix + "/opt"
            let versioned = fileSystem.contents(ofDirectory: opt).filter {
                ["postgresql@", "mysql@", "mariadb@", "mysql-client@", "libpq@"].contains(where: $0.hasPrefix)
            }.sorted(by: Self.descendingNatural)
            for pkg in versioned { dirs.append("\(opt)/\(pkg)/bin") }
        }
        for v in fileSystem.contents(ofDirectory: postgresAppVersionsDirectory).sorted(by: Self.descendingNatural) {
            dirs.append("\(postgresAppVersionsDirectory)/\(v)/bin")
        }
        dirs += pathEnvironment.split(separator: ":").map(String.init)
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Every distinct tool found (a Homebrew symlink and its target count once), with versions probed.
    public func locate() async -> [ToolInfo] {
        var candidates: [(path: String, name: String, role: ToolRole)] = []
        var seenReal = Set<String>()
        for dir in searchDirectories() {
            for (name, role) in Self.toolNames {
                let path = dir + "/" + name
                guard fileSystem.isExecutable(path) else { continue }
                // Same binary reachable under the same name from several dirs counts once.
                guard seenReal.insert(name + "|" + fileSystem.resolveSymlinks(path)).inserted else { continue }
                candidates.append((path, name, role))
            }
        }
        var found: [ToolInfo] = []
        for c in candidates {
            guard let out = try? await runner.run(executable: c.path, arguments: ["--version"]), out.status == 0 else { continue }
            let text = out.stdout.isEmpty ? out.stderr : out.stdout
            guard let parsed = DumpToolVersionParser.parse(text, toolName: c.name) else { continue }
            found.append(ToolInfo(path: c.path, name: c.name, role: c.role, flavour: parsed.flavour, version: parsed.version,
                                  versionOutput: text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text))
        }
        return found
    }

    private static func descendingNatural(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }
}

// MARK: - Selection

public enum ToolIssue: Sendable, Equatable {
    case noToolFound(wanted: [String])
    /// `pg_dump` must be at least as new as the server. Blocking.
    case pgToolOlderThanServer(toolMajor: Int, serverMajor: Int)
    /// Works, but a native tool for the server's flavour is preferable.
    case flavourMismatch(tool: ToolFlavour, server: DatabaseEngine)
    /// Tool is older than the server (MySQL family); may fail on new auth plugins / syntax.
    case toolOlderThanServer(tool: ToolVersion, server: ToolVersion)

    public var isBlocking: Bool {
        switch self {
        case .noToolFound, .pgToolOlderThanServer: true
        case .flavourMismatch, .toolOlderThanServer: false
        }
    }

    public var message: String {
        switch self {
        case .noToolFound(let names): "No \(names.joined(separator: " / ")) found on this Mac. Install the database client tools (for example `brew install libpq` or `brew install mysql-client`)."
        case .pgToolOlderThanServer(let t, let s): "pg_dump \(t) is older than the PostgreSQL \(s) server; pg_dump must be the same version or newer. Install a newer client (`brew install libpq`)."
        case .flavourMismatch(let t, let s): "The available dump tool is from \(t.rawValue) but the server is \(s.displayName); it usually works, a matching tool is safer."
        case .toolOlderThanServer(let t, let s): "The dump tool (\(t.major).\(t.minor)) is older than the server (\(s.major).\(s.minor)); newer server features may not dump correctly."
        }
    }
}

public struct ToolSelection: Sendable, Equatable {
    public var tool: ToolInfo?
    public var issues: [ToolIssue]
    /// Compatibility flags to add to the dump command (see ``DumpToolQuirks``).
    public var extraArguments: [String]

    public var isUsable: Bool { tool != nil && !issues.contains(where: \.isBlocking) }
}

public enum DumpToolSelector {
    /// Best dump tool for `server` among `tools`.
    public static func select(for server: ServerInfo, from tools: [ToolInfo], role: ToolRole = .dump) -> ToolSelection {
        let serverVersion = ToolVersion(server.major, server.minor, server.patch)
        switch server.engine {
        case .postgresql:
            let pg = tools.filter { $0.flavour == .postgres && $0.role == role }
            let wanted = role == .restore ? ["pg_restore"] : (role == .client ? ["psql"] : ["pg_dump"])
            guard !pg.isEmpty else { return ToolSelection(tool: nil, issues: [.noToolFound(wanted: wanted)], extraArguments: []) }
            let compatible = pg.filter { $0.version.major >= server.major }.sorted { $0.version < $1.version }
            if let best = compatible.first {
                return ToolSelection(tool: best, issues: [], extraArguments: DumpToolQuirks.arguments(tool: best, server: server))
            }
            let newest = pg.max { $0.version < $1.version }!
            return ToolSelection(tool: nil, issues: [.pgToolOlderThanServer(toolMajor: newest.version.major, serverMajor: server.major)],
                                 extraArguments: [])
        case .mysql, .mariadb:
            let mine = tools.filter { $0.flavour != .postgres && $0.role == role }
            let wanted = role == .client ? ["mysql", "mariadb"] : ["mysqldump", "mariadb-dump"]
            guard !mine.isEmpty else { return ToolSelection(tool: nil, issues: [.noToolFound(wanted: wanted)], extraArguments: []) }
            func score(_ t: ToolInfo) -> Int {
                var s = 0
                let nativeFlavour: ToolFlavour = server.engine == .mariadb ? .mariadb : .mysql
                if t.flavour == nativeFlavour { s += 1000 }
                if t.version >= serverVersion || t.version.major >= server.major { s += 100 }
                let distance = abs((t.version.major * 100 + t.version.minor) - (server.major * 100 + server.minor))
                s -= min(distance, 99)
                // Prefer the canonical name for the flavour on ties.
                if t.name == "mysqldump" || t.name == "mysql" { s += 1 }
                return s
            }
            let best = mine.max { score($0) < score($1) }!
            var issues: [ToolIssue] = []
            let nativeFlavour: ToolFlavour = server.engine == .mariadb ? .mariadb : .mysql
            if best.flavour != nativeFlavour { issues.append(.flavourMismatch(tool: best.flavour, server: server.engine)) }
            if best.version.major < server.major && best.flavour == nativeFlavour {
                issues.append(.toolOlderThanServer(tool: best.version, server: serverVersion))
            }
            return ToolSelection(tool: best, issues: issues, extraArguments: DumpToolQuirks.arguments(tool: best, server: server))
        }
    }
}

/// Command-line flags a particular tool/server pairing needs.
public enum DumpToolQuirks {
    /// Only for `role == .dump` tools.
    ///
    /// - `--column-statistics=0`: MySQL 8's `mysqldump` queries `information_schema.COLUMN_STATISTICS`,
    ///   which MariaDB and MySQL 5.7 don't have (ERROR 1109).
    /// - `--set-gtid-purged=OFF`: MySQL's `mysqldump` otherwise probes GTID variables (fails on MariaDB) and
    ///   writes `SET @@GLOBAL.GTID_PURGED`, which breaks restores on servers without GTID. Unknown to `mariadb-dump`.
    /// - `--no-tablespaces`: avoids needing the global `PROCESS` privilege (MySQL 8 servers).
    public static func arguments(tool: ToolInfo, server: ServerInfo) -> [String] {
        guard tool.role == .dump else { return [] }
        var args: [String] = []
        switch tool.flavour {
        case .mysql:
            if tool.version.major >= 8, server.engine == .mariadb || server.major < 8 {
                args.append("--column-statistics=0")
            }
            if tool.version >= ToolVersion(5, 6) { args.append("--set-gtid-purged=OFF") }
            if tool.version >= ToolVersion(8, 0, 21) || (tool.version.major == 5 && tool.version >= ToolVersion(5, 7, 31)) {
                args.append("--no-tablespaces")
            }
        case .mariadb:
            if tool.version >= ToolVersion(10, 6) { args.append("--no-tablespaces") }
        case .postgres:
            break
        }
        return args
    }
}
