import Foundation
import Testing

@testable import QuerywellCore

@Suite("Dump tool discovery")
struct DumpToolsTests {
    @Test(arguments: [
        ("mysqldump  Ver 8.0.36 for macos14.2 on arm64 (Homebrew)", "mysqldump", ToolFlavour.mysql, ToolVersion(8, 0, 36)),
        ("mysqldump  Ver 8.4.0 for macos14 on arm64 (Homebrew)", "mysqldump", .mysql, ToolVersion(8, 4, 0)),
        ("mysqldump  Ver 10.13 Distrib 5.7.44, for Linux (x86_64)", "mysqldump", .mysql, ToolVersion(5, 7, 44)),
        ("mysqldump  Ver 10.19 Distrib 10.11.6-MariaDB, for debian-linux-gnu (x86_64)", "mysqldump", .mariadb, ToolVersion(10, 11, 6)),
        ("mariadb-dump from 11.8.2-MariaDB, client 10.19 for osx10.20 (arm64)", "mariadb-dump", .mariadb, ToolVersion(11, 8, 2)),
        ("mysql from 11.8.2-MariaDB, client 15.2 for osx10.20 (arm64) using  EditLine wrapper", "mysql", .mariadb, ToolVersion(11, 8, 2)),
        ("mysql  Ver 15.1 Distrib 10.5.18-MariaDB, for debian-linux-gnu (x86_64) using  EditLine wrapper", "mysql", .mariadb, ToolVersion(10, 5, 18)),
        ("mysql  Ver 8.0.36-0ubuntu0.22.04.1 for Linux on x86_64 ((Ubuntu))", "mysql", .mysql, ToolVersion(8, 0, 36)),
        ("pg_dump (PostgreSQL) 16.4 (Homebrew)", "pg_dump", .postgres, ToolVersion(16, 4, 0)),
        ("pg_dump (PostgreSQL) 14.12 (Ubuntu 14.12-0ubuntu0.22.04.1)", "pg_dump", .postgres, ToolVersion(14, 12, 0)),
        ("pg_dump (PostgreSQL) 17beta1", "pg_dump", .postgres, ToolVersion(17, 0, 0)),
        ("psql (PostgreSQL) 18devel", "psql", .postgres, ToolVersion(18, 0, 0)),
        ("pg_restore (PostgreSQL) 15.3.1", "pg_restore", .postgres, ToolVersion(15, 3, 1)),
    ])
    func versionParsing(line: String, name: String, flavour: ToolFlavour, version: ToolVersion) {
        let parsed = DumpToolVersionParser.parse(line + "\n", toolName: name)
        #expect(parsed?.flavour == flavour)
        #expect(parsed?.version == version)
    }

    @Test func unparseableOutputIsNil() {
        #expect(DumpToolVersionParser.parse("command not found", toolName: "mysqldump") == nil)
        #expect(DumpToolVersionParser.parse("", toolName: "pg_dump") == nil)
    }

    // MARK: locator

    struct FakeFS: ToolFileSystem {
        var executables: Set<String>
        var directories: [String: [String]] = [:]
        var links: [String: String] = [:]
        func isExecutable(_ path: String) -> Bool { executables.contains(path) }
        func contents(ofDirectory path: String) -> [String] { directories[path] ?? [] }
        func resolveSymlinks(_ path: String) -> String { links[path] ?? path }
    }

    struct FakeRunner: ProcessRunning {
        var outputs: [String: String]
        func run(executable: String, arguments: [String]) async throws -> ProcessOutput {
            guard let out = outputs[executable] else { return ProcessOutput(status: 127, stdout: "", stderr: "nope") }
            return ProcessOutput(status: 0, stdout: out + "\n", stderr: "")
        }
    }

    @Test func locatorFindsHomebrewPostgresAppAndPathToolsWithoutDuplicates() async {
        let fs = FakeFS(
            executables: [
                "/opt/homebrew/bin/mysqldump", "/opt/homebrew/bin/mariadb-dump", "/opt/homebrew/opt/mariadb/bin/mysqldump",
                "/opt/homebrew/opt/libpq/bin/pg_dump", "/opt/homebrew/opt/postgresql@16/bin/pg_dump", "/opt/homebrew/opt/postgresql@16/bin/psql",
                "/Applications/Postgres.app/Contents/Versions/17/bin/pg_dump", "/usr/local/bin/pg_restore",
                "/custom/bin/mysql",
            ],
            directories: [
                "/opt/homebrew/opt": ["postgresql@16", "libpq", "mariadb", "python@3"],
                "/Applications/Postgres.app/Contents/Versions": ["17", "latest"],
            ],
            links: [
                "/opt/homebrew/bin/mysqldump": "/opt/homebrew/Cellar/mariadb/11.8.2/bin/mariadb-dump",
                "/opt/homebrew/opt/mariadb/bin/mysqldump": "/opt/homebrew/Cellar/mariadb/11.8.2/bin/mariadb-dump",
            ])
        let runner = FakeRunner(outputs: [
            "/opt/homebrew/bin/mysqldump": "mysqldump from 11.8.2-MariaDB, client 10.19 for osx10.20 (arm64)",
            "/opt/homebrew/bin/mariadb-dump": "mariadb-dump from 11.8.2-MariaDB, client 10.19 for osx10.20 (arm64)",
            "/opt/homebrew/opt/libpq/bin/pg_dump": "pg_dump (PostgreSQL) 18.6",
            "/opt/homebrew/opt/postgresql@16/bin/pg_dump": "pg_dump (PostgreSQL) 16.4 (Homebrew)",
            "/opt/homebrew/opt/postgresql@16/bin/psql": "psql (PostgreSQL) 16.4 (Homebrew)",
            "/Applications/Postgres.app/Contents/Versions/17/bin/pg_dump": "pg_dump (PostgreSQL) 17.0",
            "/usr/local/bin/pg_restore": "pg_restore (PostgreSQL) 15.3",
            "/custom/bin/mysql": "mysql  Ver 8.0.36 for macos14.2 on arm64 (Homebrew)",
        ])
        let locator = DumpToolLocator(fileSystem: fs, runner: runner, pathEnvironment: "/custom/bin:/opt/homebrew/bin")
        let dirs = locator.searchDirectories()
        #expect(dirs.first == "/opt/homebrew/bin")
        #expect(dirs.contains("/opt/homebrew/opt/postgresql@16/bin"))
        #expect(dirs.contains("/Applications/Postgres.app/Contents/Versions/17/bin"))
        #expect(dirs.contains("/custom/bin"))
        #expect(dirs.filter { $0 == "/opt/homebrew/bin" }.count == 1)

        let tools = await locator.locate()
        #expect(tools.filter { $0.name == "mysqldump" }.count == 1)  // symlink targets deduplicated
        #expect(Set(tools.filter { $0.name == "pg_dump" }.map(\.version.major)) == [16, 17, 18])
        #expect(tools.first { $0.name == "mysql" }?.flavour == .mysql)
        #expect(tools.first { $0.name == "pg_restore" }?.role == .restore)
    }

    // MARK: selection

    private func tool(_ name: String, _ flavour: ToolFlavour, _ v: ToolVersion, role: ToolRole = .dump) -> ToolInfo {
        ToolInfo(path: "/bin/\(name)-\(v)", name: name, role: role, flavour: flavour, version: v, versionOutput: "")
    }

    private func server(_ e: DatabaseEngine, _ major: Int, _ minor: Int = 0) -> ServerInfo {
        ServerInfo(engine: e, versionString: "\(major).\(minor)", major: major, minor: minor, patch: 0, tlsActive: false)
    }

    @Test func pgDumpMustBeAtLeastServerMajorAndPicksTheClosest() {
        let tools = [tool("pg_dump", .postgres, ToolVersion(14, 12)), tool("pg_dump", .postgres, ToolVersion(17, 0)),
                     tool("pg_dump", .postgres, ToolVersion(18, 6))]
        let sel = DumpToolSelector.select(for: server(.postgresql, 16, 4), from: tools)
        #expect(sel.tool?.version.major == 17)
        #expect(sel.isUsable)
        let old = DumpToolSelector.select(for: server(.postgresql, 17, 2), from: [tool("pg_dump", .postgres, ToolVersion(14, 12))])
        #expect(old.tool == nil)
        #expect(old.issues == [.pgToolOlderThanServer(toolMajor: 14, serverMajor: 17)])
        #expect(!old.isUsable)
        #expect(old.issues.first?.message.contains("pg_dump 14") == true)
    }

    @Test func missingToolsAreReported() {
        let sel = DumpToolSelector.select(for: server(.mysql, 8, 4), from: [tool("pg_dump", .postgres, ToolVersion(16)),])
        #expect(sel.tool == nil)
        #expect(sel.issues == [.noToolFound(wanted: ["mysqldump", "mariadb-dump"])])
    }

    @Test func mysqlFamilyPrefersMatchingFlavour() {
        let tools = [tool("mysqldump", .mysql, ToolVersion(8, 4, 0)), tool("mariadb-dump", .mariadb, ToolVersion(11, 4, 2))]
        #expect(DumpToolSelector.select(for: server(.mariadb, 11, 4), from: tools).tool?.flavour == .mariadb)
        #expect(DumpToolSelector.select(for: server(.mysql, 8, 4), from: tools).tool?.flavour == .mysql)
        let only = DumpToolSelector.select(for: server(.mysql, 8, 4), from: [tool("mariadb-dump", .mariadb, ToolVersion(11, 8, 2))])
        #expect(only.tool?.flavour == .mariadb)
        #expect(only.issues.contains(.flavourMismatch(tool: .mariadb, server: .mysql)))
        #expect(only.isUsable)
    }

    @Test func quirkFlagsForMySQLEightAgainstOtherServers() {
        let my8 = tool("mysqldump", .mysql, ToolVersion(8, 0, 36))
        #expect(DumpToolQuirks.arguments(tool: my8, server: server(.mariadb, 11, 4)).contains("--column-statistics=0"))
        #expect(DumpToolQuirks.arguments(tool: my8, server: server(.mysql, 5, 7)).contains("--column-statistics=0"))
        #expect(!DumpToolQuirks.arguments(tool: my8, server: server(.mysql, 8, 4)).contains("--column-statistics=0"))
        #expect(DumpToolQuirks.arguments(tool: my8, server: server(.mysql, 8, 4)).contains("--set-gtid-purged=OFF"))
        #expect(DumpToolQuirks.arguments(tool: my8, server: server(.mysql, 8, 4)).contains("--no-tablespaces"))
        let maria = tool("mariadb-dump", .mariadb, ToolVersion(11, 4, 2))
        let mariaArgs = DumpToolQuirks.arguments(tool: maria, server: server(.mariadb, 11, 4))
        #expect(!mariaArgs.contains("--column-statistics=0"))
        #expect(!mariaArgs.contains("--set-gtid-purged=OFF"))
        let my57 = tool("mysqldump", .mysql, ToolVersion(5, 7, 44))
        #expect(!DumpToolQuirks.arguments(tool: my57, server: server(.mysql, 5, 7)).contains("--column-statistics=0"))
        #expect(DumpToolQuirks.arguments(tool: tool("pg_dump", .postgres, ToolVersion(16)), server: server(.postgresql, 16)).isEmpty)
    }

    @Test func selectionCarriesQuirkArguments() {
        let sel = DumpToolSelector.select(for: server(.mariadb, 11, 4), from: [tool("mysqldump", .mysql, ToolVersion(8, 0, 36))])
        #expect(sel.extraArguments.contains("--column-statistics=0"))
        #expect(sel.issues.contains(.flavourMismatch(tool: .mysql, server: .mariadb)))
    }
}

@Suite("Gzip stream")
struct GzipTests {
    private func sampleData(_ n: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        var d = Data()
        let words = ["INSERT INTO `wp_posts` VALUES", "(1,'Hello','world'),", "utf8mb4_unicode_ci", "\n", "Zażółć gęślą jaźń 🙂 "]
        while d.count < n {
            d.append(Data(words[Int(rng.next() % UInt64(words.count))].utf8))
            if rng.next() % 7 == 0 { d.append(UInt8(truncatingIfNeeded: rng.next())) }
        }
        return d
    }

    @Test func roundTripsInOddlySizedChunks() throws {
        let original = sampleData(3_000_000)
        let c = try GzipCompressor()
        var gz = Data()
        var i = 0
        while i < original.count {
            let n = min(original.count - i, 1 + (i % 70_001))
            gz.append(try c.compress(original[i..<(i + n)]))
            i += n
        }
        gz.append(try c.finish())
        #expect(gz.count < original.count)

        let d = try GzipDecompressor()
        var back = Data()
        var j = 0
        while j < gz.count {
            let n = min(gz.count - j, 1 + (j % 997))
            back.append(try d.decompress(gz[j..<(j + n)]))
            j += n
        }
        try d.finish()
        #expect(back == original)
    }

    @Test func interoperatesWithSystemGzip() throws {
        let original = sampleData(200_000)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("qw-gz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // ours -> gzip -dc
        let ours = tmp.appendingPathComponent("ours.gz")
        try Gzip.compress(original).write(to: ours)
        #expect(try runTool("/usr/bin/gzip", ["-dc", ours.path]) == original)
        // gzip -c -> ours
        let plain = tmp.appendingPathComponent("plain")
        try original.write(to: plain)
        let theirs = try runTool("/usr/bin/gzip", ["-c", plain.path])
        #expect(try Gzip.decompress(theirs) == original)
    }

    @Test func concatenatedMembersAndTrailingPadding() throws {
        let a = Data("first part\n".utf8), b = Data("second part\n".utf8)
        var gz = try Gzip.compress(a)
        gz.append(try Gzip.compress(b))
        #expect(try Gzip.decompress(gz) == a + b)
        gz.append(Data(repeating: 0, count: 16))
        #expect(try Gzip.decompress(gz) == a + b)
    }

    @Test func truncatedAndCorruptInputAreDetected() throws {
        let gz = try Gzip.compress(sampleData(50_000))
        #expect(throws: GzipError.truncated) { _ = try Gzip.decompress(gz.prefix(gz.count / 2)) }
        var bad = gz
        bad[bad.count / 2] ^= 0xFF
        #expect(throws: GzipError.self) { _ = try Gzip.decompress(bad) }
        #expect(throws: GzipError.self) { _ = try Gzip.decompress(Data("not gzip at all".utf8)) }
    }

    @Test func emptyInputRoundTrips() throws {
        let gz = try Gzip.compress(Data())
        #expect(try Gzip.decompress(gz).isEmpty)
    }
}

/// Runs a tool synchronously and returns stdout (tests only).
func runTool(_ path: String, _ args: [String], stdin: Data? = nil, environment: [String: String]? = nil) throws -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let environment { p.environment = environment }
    let out = Pipe(), inp = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
    try p.run()
    if let stdin {
        try? inp.fileHandleForReading.close()
        try? inp.fileHandleForWriting.write(contentsOf: stdin)
        try? inp.fileHandleForWriting.close()
    }
    try? out.fileHandleForWriting.close()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return data
}
