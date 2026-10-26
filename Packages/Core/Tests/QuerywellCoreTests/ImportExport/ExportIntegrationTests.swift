import Foundation
import Testing

@testable import QuerywellCore

// MARK: - Shared helpers (also used by the import tests)

/// SSH test material: copies of the generated keys plus a throwaway known_hosts.
final class SSHTestBed: @unchecked Sendable {
    // @unchecked Sendable: immutable after init.
    let dir: URL
    let keyPath: String
    let knownHosts: String

    init() throws {
        guard let src = ProcessInfo.processInfo.environment["QUERYWELL_TEST_SSH_DIR"] else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "QUERYWELL_TEST_SSH_DIR not set"])
        }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("qw-exp-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dst = dir.appendingPathComponent("id_ed25519")
        try FileManager.default.copyItem(atPath: src + "/id_ed25519", toPath: dst.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
        keyPath = dst.path
        knownHosts = dir.appendingPathComponent("known_hosts").path
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    var options: SSHClientOptions { SSHClientOptions(knownHostsFile: knownHosts, useUserSSHConfig: false) }
    var config: SSHTunnelConfig { SSHTunnelConfig(host: "127.0.0.1", port: 12222, user: "querywell", auth: .keyFile(path: keyPath)) }
}

extension DBTarget {
    /// Service name + port of the database as seen from the SSH bastion.
    var bastionEndpoint: ExportTarget.Endpoint {
        switch name {
        case "mysql-8.4": .init(host: "mysql8", port: 3306)
        case "mariadb-11.4": .init(host: "mariadb11", port: 3306)
        default: .init(host: "postgres16", port: 5432)
        }
    }

    /// Admin credentials the export tests dump as.
    var adminUser: String { isPostgres ? "querywell" : "root" }
    var adminPassword: String { isPostgres ? "querywell_pw" : "root_pw" }
}

/// Runs a docker CLI command (integration tests only).
func dockerOutput(_ args: [String]) -> String? {
    let path = "/usr/local/bin/docker"
    guard FileManager.default.isExecutableFile(atPath: path),
          let data = try? runTool(path, args, environment: ProcessInfo.processInfo.environment) else { return nil }
    return String(decoding: data, as: UTF8.self)
}

/// Samples `ps -ef` on the bastion at ~50 Hz while an export runs, through one long-lived `docker exec`
/// (so the sampling rate isn't limited by docker's per-call overhead). The remote loop is bounded (≈30 s)
/// and also ends when the stop file appears.
final class BastionProcessWatcher: @unchecked Sendable {
    // @unchecked Sendable: `data` guarded by `lock`; the process is only touched by start/stop.
    private let lock = NSLock()
    private var data = Data()
    private var process: Process?
    private let stopFile = "/tmp/qw-watch-stop-\(UUID().uuidString)"

    func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        let loop = "i=0; while [ ! -f \(stopFile) ] && [ $i -lt 1500 ]; do ps -ef; echo =====SAMPLE=====; i=$((i+1)); sleep 0.02; done; rm -f \(stopFile)"
        p.arguments = ["exec", "querywell-test-sshd-1", "sh", "-c", loop]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try? p.run()
        try? out.fileHandleForWriting.close()
        process = p
        DispatchQueue.global().async { [self] in
            while let chunk = try? out.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                lock.withLock { data.append(chunk) }
            }
        }
    }

    /// Waits until at least one sample has arrived.
    func waitForFirstSample() async {
        for _ in 0..<100 {
            if lock.withLock({ data.count }) > 0 { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func stop() async -> [String] {
        _ = dockerOutput(["exec", "querywell-test-sshd-1", "touch", stopFile])
        for _ in 0..<200 where process?.isRunning == true { try? await Task.sleep(for: .milliseconds(25)) }
        if process?.isRunning == true { process?.terminate() }
        let text = String(decoding: lock.withLock { data }, as: UTF8.self)
        return text.components(separatedBy: "=====SAMPLE=====")
    }
}

func tempOutputDirectory() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("qw-export-out-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// Collects export events thread-safely.
final class EventLog: @unchecked Sendable {
    // @unchecked Sendable: guarded by `lock`.
    private let lock = NSLock()
    private var _events: [ExportEvent] = []
    func add(_ e: ExportEvent) { lock.withLock { _events.append(e) } }
    var events: [ExportEvent] { lock.withLock { _events } }
    var tables: [String] { events.compactMap { if case .table(let n, _, _) = $0 { n } else { nil } } }
    var maxBytes: Int64 { events.compactMap { if case .bytes(let b) = $0 { b } else { nil } }.max() ?? 0 }
}

// MARK: - Fixture

/// A schema with WordPress-like tables (and optionally a large table).
struct ExportFixture {
    let f: SchemaFixture
    var pg: Bool { f.target.isPostgres }
    var q: String { f.q }

    func create() async throws {
        let big = pg ? "text" : "longtext"
        // MySQL 8 spelling of the 8.0 default collation; MariaDB 11.4's own default is uca1400, so no explicit clause is needed.
        let coll = (f.target.name == "mysql-8.4") ? " COLLATE utf8mb4_0900_ai_ci" : ""
        let tail = pg ? "" : " DEFAULT CHARSET=utf8mb4\(coll)"
        try await f.run("CREATE TABLE \(q).wp_options (option_id bigint NOT NULL \(pg ? "PRIMARY KEY" : "AUTO_INCREMENT, PRIMARY KEY (option_id)"), option_name varchar(191) NOT NULL, option_value \(big) NOT NULL)\(tail)")
        try await f.run("CREATE TABLE \(q).wp_posts (ID bigint NOT NULL PRIMARY KEY, post_title varchar(200) NOT NULL, post_content \(big) NOT NULL)\(tail)")
        let d = f.dialect
        func opt(_ id: Int, _ n: String, _ v: String) async throws {
            try await f.run("INSERT INTO \(q).wp_options (option_id, option_name, option_value) VALUES (\(id), \(d.quoteString(n)), \(d.quoteString(v)))")
        }
        try await opt(1, "siteurl", "http://old.example.com")
        try await opt(2, "blogname", "Zażółć 'quoted' \"double\" back\\slash")
        try await opt(3, "_transient_feed_abc", "transient-value-1")
        try await opt(4, "_transient_timeout_feed_abc", "1700000000")
        try await opt(5, "_site_transient_update_core", "site-transient-value")
        try await opt(6, "my_transient_like", "keep-me")
        try await f.run("INSERT INTO \(q).wp_posts (ID, post_title, post_content) VALUES (1, 'Hello', \(d.quoteString("A post about utf8mb4_0900_ai_ci and COLLATE utf8mb4_unicode_ci in data"))), (2, 'Two', 'second ✓ 🙂')")
    }

    func createBig() async throws {
        if pg {
            try await f.run("CREATE TABLE \(q).big (id bigserial PRIMARY KEY, payload text NOT NULL)")
            try await f.run("INSERT INTO \(q).big (payload) SELECT repeat('x', 200) || g FROM generate_series(1, 131072) g")
        } else {
            try await f.run("CREATE TABLE \(q).big (id bigint NOT NULL AUTO_INCREMENT PRIMARY KEY, payload varchar(255) NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4")
            try await f.run("INSERT INTO \(q).big (payload) VALUES (REPEAT('x', 200))")
            for _ in 0..<17 { try await f.run("INSERT INTO \(q).big (payload) SELECT payload FROM \(q).big") }
        }
    }

    /// Table names as the export options / progress total should list them.
    func tableNames(big: Bool = false) -> [String] {
        let names = ["wp_options", "wp_posts"] + (big ? ["big"] : [])
        return pg ? names.map { "\(f.schema).\($0)" } : names
    }

    var databaseName: String { pg ? "querywell_test" : f.schema }

    func target(user: String? = nil, password: String? = nil, bed: SSHTestBed) -> ExportTarget {
        ExportTarget(engine: f.target.engine, database: databaseName, user: user ?? f.target.adminUser,
                     password: password ?? f.target.adminPassword, remoteEndpoint: f.target.bastionEndpoint,
                     localEndpoint: .init(host: "127.0.0.1", port: f.target.port), ssh: bed.config,
                     sshSecretKey: SecretKey(ownerID: "test", kind: .sshKeyPassphrase))
    }

    func options(_ build: (inout ExportOptions) -> Void = { _ in }, big: Bool = false) -> ExportOptions {
        var o = ExportOptions(tables: pg ? tableNames(big: big) : nil, optionsTables: ["wp_options"])
        if !pg, big { o.tables = nil }
        build(&o)
        return o
    }

    func gunzipped(_ url: URL) throws -> String {
        String(decoding: try Gzip.decompress(try Data(contentsOf: url)), as: UTF8.self)
    }
}

// MARK: - Remote export (through the docker sshd bastion)

@Suite("Export over SSH integration", .serialized, .enabled(if: schemaIntegrationEnabled))
struct ExportIntegrationTests {
    let runner = ExportRunner(secretStore: InMemorySecretStore())

    @Test(arguments: DBTarget.all)
    func remoteExportProducesAGzippedDump(target: DBTarget) async throws {
        let bed = try SSHTestBed()
        try await SchemaFixture.with(target) { f in
            let fx = ExportFixture(f: f)
            try await fx.create()
            var plan = try ExportPlanner.plan(target: fx.target(bed: bed), options: fx.options(), sshOptions: bed.options)
            plan.tables = fx.tableNames()
            let out = try tempOutputDirectory()
            defer { try? FileManager.default.removeItem(at: out) }
            let log = EventLog()
            let dest = out.appendingPathComponent(plan.outputFilename)
            let summary = try await runner.run(plan: plan, to: dest) { log.add($0) }

            #expect(summary.bytesWritten > 0)
            #expect(FileManager.default.fileExists(atPath: dest.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == [plan.outputFilename])
            let sql = try fx.gunzipped(dest)
            #expect(sql.contains("CREATE TABLE"))
            #expect(sql.contains("wp_options") && sql.contains("wp_posts"))
            #expect(sql.contains(target.isPostgres ? "COPY " : "INSERT INTO"))
            #expect(sql.contains("http://old.example.com"))
            #expect(sql.contains(target.isPostgres ? "DROP TABLE IF EXISTS" : "DROP TABLE IF EXISTS"))
            #expect(sql.contains("Zażółć"))
            // per-table progress with index/total
            let tableEvents = log.events.compactMap { e -> (String, Int, Int?)? in if case .table(let n, let i, let t) = e { (n, i, t) } else { nil } }
            #expect(tableEvents.count >= 2, "events: \(log.events)")
            #expect(tableEvents.first?.1 == 1)
            #expect(tableEvents.allSatisfy { $0.2 == 2 })
            #expect(tableEvents.contains { $0.0.hasSuffix("wp_options") })
            #expect(log.maxBytes == summary.bytesWritten)
            #expect(!plan.displayCommand.contains(target.adminPassword))
        }
    }

    @Test(arguments: [DBTarget.mysql8, DBTarget.mariadb11])
    func transientsAreExcludedOnlyWhenAsked(target: DBTarget) async throws {
        let bed = try SSHTestBed()
        try await SchemaFixture.with(target) { f in
            let fx = ExportFixture(f: f)
            try await fx.create()
            let out = try tempOutputDirectory()
            defer { try? FileManager.default.removeItem(at: out) }

            var withAll = try ExportPlanner.plan(target: fx.target(bed: bed), options: fx.options(), sshOptions: bed.options)
            withAll.tables = nil
            let a = out.appendingPathComponent("all.sql.gz")
            try await runner.run(plan: withAll, to: a)
            let all = try fx.gunzipped(a)
            #expect(all.contains("_transient_feed_abc") && all.contains("_site_transient_update_core"))

            let filtered = try ExportPlanner.plan(target: fx.target(bed: bed), options: fx.options { $0.skipWordPressTransients = true }, sshOptions: bed.options)
            let b = out.appendingPathComponent("filtered.sql.gz")
            try await runner.run(plan: filtered, to: b)
            let sql = try fx.gunzipped(b)
            #expect(!sql.contains("_transient_feed_abc"))
            #expect(!sql.contains("_transient_timeout_feed_abc"))
            #expect(!sql.contains("_site_transient_update_core"))
            #expect(sql.contains("my_transient_like"))  // not a WordPress transient
            #expect(sql.contains("siteurl") && sql.contains("blogname"))
            #expect(sql.contains("CREATE TABLE `wp_options`") && sql.contains("CREATE TABLE `wp_posts`"))
            #expect(sql.contains("A post about"))
        }
    }

    @Test(arguments: [DBTarget.mysql8, DBTarget.mariadb11])
    func collationRewriteIsAppliedToTheDownloadedStream(target: DBTarget) async throws {
        let bed = try SSHTestBed()
        try await SchemaFixture.with(target) { f in
            let fx = ExportFixture(f: f)
            try await fx.create()
            let out = try tempOutputDirectory()
            defer { try? FileManager.default.removeItem(at: out) }

            let keep = try ExportPlanner.plan(target: fx.target(bed: bed), options: fx.options(), sshOptions: bed.options)
            let k = out.appendingPathComponent("keep.sql.gz")
            try await runner.run(plan: keep, to: k)
            let original = try fx.gunzipped(k)
            let nativeCollation = target.name == "mysql-8.4" ? "utf8mb4_0900_ai_ci" : "utf8mb4_uca1400_ai_ci"
            #expect(original.contains("COLLATE=\(nativeCollation)"), "kept dump should carry the native collation")

            let plan = try ExportPlanner.plan(
                target: fx.target(bed: bed), options: fx.options { $0.collation = .mysql57MariaDBCompatible }, sshOptions: bed.options)
            #expect(plan.localStages == ["gunzip", "collation rewrite", "gzip"])
            let r = out.appendingPathComponent("rewritten.sql.gz")
            try await runner.run(plan: plan, to: r)
            let sql = try fx.gunzipped(r)
            #expect(!sql.contains("COLLATE=\(nativeCollation)"))
            #expect(sql.contains("utf8mb4_unicode_520_ci"))
            // data payloads are never touched, even when they spell a collation name
            #expect(sql.contains("A post about utf8mb4_0900_ai_ci and COLLATE utf8mb4_unicode_ci in data"))
        }
    }

    @Test(arguments: [DBTarget.mysql8, DBTarget.postgres16])
    func cancelMidwayDeletesThePartialFile(target: DBTarget) async throws {
        let bed = try SSHTestBed()
        try await SchemaFixture.with(target) { f in
            let fx = ExportFixture(f: f)
            try await fx.create()
            try await fx.createBig()
            var plan = try ExportPlanner.plan(target: fx.target(bed: bed), options: fx.options({ $0.gzip = false }, big: true), sshOptions: bed.options)
            plan.tables = fx.tableNames(big: true)
            let out = try tempOutputDirectory()
            defer { try? FileManager.default.removeItem(at: out) }
            let dest = out.appendingPathComponent("cancelled.sql")

            let box = CancelBox()
            let runner = self.runner
            let task = Task { try await runner.run(plan: plan, to: dest) { e in
                if case .bytes(let b) = e, b > 300_000 { box.cancel() }
            } }
            box.task = task
            do {
                _ = try await task.value
                Issue.record("export finished before it could be cancelled")
            } catch is CancellationError {
                // expected
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty, "partial file must be removed")

            // the server-side dump ends too (SIGPIPE on its next write)
            var gone = false
            for _ in 0..<60 {
                let ps = dockerOutput(["exec", "querywell-test-sshd-1", "ps", "-ef"]) ?? ""
                if !ps.contains(fx.databaseName) { gone = true; break }
                try await Task.sleep(for: .milliseconds(250))
            }
            #expect(gone, "the remote dump process should end after the connection closes")
        }
    }

    @Test(arguments: DBTarget.all)
    func nastyPasswordsWorkAndNeverReachTheServersProcessList(target: DBTarget) async throws {
        guard dockerOutput(["version", "--format", "{{.Client.Version}}"]) != nil else { return }
        let bed = try SSHTestBed()
        let marker = "ZqNasty" + UUID().uuidString.prefix(6)
        // PostgreSQL password files can't carry line breaks, so the newline variant is MySQL-only.
        var passwords = [
            "\(marker) with 'single' \"double\" $HOME `id` $(id) \\back; | & > <",
            "\(marker)#%!*?[x]{y}~ünï🙂",
            "\(marker)\\",
        ]
        if !target.isPostgres { passwords.append("\(marker)\nsecond line\ttab") }
        try await SchemaFixture.with(target) { f in
            let fx = ExportFixture(f: f)
            try await fx.create()
            try await fx.createBig()
            for pw in passwords {
                let user = "qwn_" + UUID().uuidString.prefix(8).lowercased()
                let d = f.dialect
                if target.isPostgres {
                    try await f.run("CREATE ROLE \(user) LOGIN PASSWORD \(d.quoteString(pw))")
                    try await f.run("GRANT USAGE ON SCHEMA \(f.q) TO \(user)")
                    try await f.run("GRANT SELECT ON ALL TABLES IN SCHEMA \(f.q) TO \(user)")
                    try await f.run("GRANT SELECT ON ALL SEQUENCES IN SCHEMA \(f.q) TO \(user)")
                } else {
                    try await f.run("CREATE USER '\(user)'@'%' IDENTIFIED BY \(d.quoteString(pw))")
                    try await f.run("GRANT SELECT, LOCK TABLES, SHOW VIEW, TRIGGER ON \(f.q).* TO '\(user)'@'%'")
                }

                var plan = try ExportPlanner.plan(
                    target: fx.target(user: user, password: pw, bed: bed), options: fx.options(big: true), sshOptions: bed.options)
                plan.tables = fx.tableNames(big: true)
                let out = try tempOutputDirectory()
                defer { try? FileManager.default.removeItem(at: out) }
                let dest = out.appendingPathComponent(plan.outputFilename)

                let watcher = BastionProcessWatcher()
                watcher.start()
                await watcher.waitForFirstSample()
                let summary: ExportSummary
                do { summary = try await runner.run(plan: plan, to: dest) } catch {
                    _ = await watcher.stop()
                    await Self.dropUser(f, user)
                    throw error
                }
                let samples = await watcher.stop()
                await Self.dropUser(f, user)

                #expect(summary.bytesWritten > 0)
                let sql = try fx.gunzipped(dest)
                #expect(sql.contains("wp_options") && sql.contains("siteurl"))
                // Evidence the watcher saw the dump running, and that the password never appeared.
                let sawDump = samples.contains { $0.contains(target.isPostgres ? "pg_dump" : "mysqldump") || $0.contains("mariadb-dump") }
                #expect(sawDump, "watcher never observed the remote dump process (\(samples.count) samples)")
                #expect(samples.allSatisfy { !$0.contains(marker) }, "password leaked into the server's process list")
                #expect(!plan.displayCommand.contains(marker))
            }
        }
    }

    @Test(arguments: [DBTarget.mysql8, DBTarget.postgres16])
    func wrongPasswordFailsWithTheToolsMessageAndLeavesNothingBehind(target: DBTarget) async throws {
        let bed = try SSHTestBed()
        try await SchemaFixture.with(target) { f in
            let fx = ExportFixture(f: f)
            try await fx.create()
            let plan = try ExportPlanner.plan(target: fx.target(password: "definitely-wrong", bed: bed), options: fx.options(), sshOptions: bed.options)
            let out = try tempOutputDirectory()
            defer { try? FileManager.default.removeItem(at: out) }
            do {
                _ = try await runner.run(plan: plan, to: out.appendingPathComponent("x.sql.gz"))
                Issue.record("expected a failure")
            } catch let ExportError.processFailed(_, tail) {
                #expect(tail.lowercased().contains("denied") || tail.lowercased().contains("authentication"), "tail: \(tail)")
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
        }
    }

    @Test func sshFailureIsReportedAsSSHError() async throws {
        let bed = try SSHTestBed()
        var cfg = bed.config
        cfg.user = "nobody-here"
        let target = ExportTarget(engine: .mysql, database: "x", user: "root", password: "root_pw",
                                  remoteEndpoint: .init(host: "mysql8", port: 3306), ssh: cfg)
        let plan = try ExportPlanner.plan(target: target, options: ExportOptions(), sshOptions: bed.options)
        let out = try tempOutputDirectory()
        defer { try? FileManager.default.removeItem(at: out) }
        do {
            _ = try await runner.run(plan: plan, to: out.appendingPathComponent("x.sql.gz"))
            Issue.record("expected failure")
        } catch ExportError.ssh {
            // expected
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    static func dropUser(_ f: SchemaFixture, _ user: String) async {
        if f.target.isPostgres {
            _ = try? await f.session.execute("DROP OWNED BY \(user)")
            _ = try? await f.session.execute("DROP ROLE IF EXISTS \(user)")
        } else {
            _ = try? await f.session.execute("DROP USER IF EXISTS '\(user)'@'%'")
        }
    }
}

final class CancelBox: @unchecked Sendable {
    // @unchecked Sendable: guarded by `lock`.
    private let lock = NSLock()
    private var _task: Task<ExportSummary, any Error>?
    private var cancelled = false
    var task: Task<ExportSummary, any Error>? {
        get { lock.withLock { _task } }
        set { lock.withLock { _task = newValue } }
    }
    func cancel() {
        let t = lock.withLock { () -> Task<ExportSummary, any Error>? in
            if cancelled { return nil }
            cancelled = true
            return _task
        }
        t?.cancel()
    }
}

// MARK: - Local tool through direct connection / tunnel

@Suite("Export with local tools integration", .serialized, .enabled(if: schemaIntegrationEnabled))
struct LocalExportIntegrationTests {
    let runner = ExportRunner(secretStore: InMemorySecretStore())

    @Test(arguments: DBTarget.all)
    func localToolDumpsThroughTheDirectPort(target: DBTarget) async throws {
        let tools = await DumpToolLocator().locate()
        let bed = try SSHTestBed()
        try await SchemaFixture.with(target) { f in
            let selection = DumpToolSelector.select(for: f.session.serverInfo, from: tools)
            guard selection.isUsable else { return }  // no suitable client tool installed on this Mac
            let fx = ExportFixture(f: f)
            try await fx.create()
            var plan = try ExportPlanner.plan(
                target: fx.target(bed: bed), options: fx.options { $0.location = .localThroughTunnel; $0.skipWordPressTransients = !target.isPostgres },
                tool: selection)
            plan.tables = fx.tableNames()
            let out = try tempOutputDirectory()
            defer { try? FileManager.default.removeItem(at: out) }
            let dest = out.appendingPathComponent(plan.outputFilename)
            let log = EventLog()
            let summary = try await runner.run(plan: plan, to: dest) { log.add($0) }
            let sql = try fx.gunzipped(dest)
            #expect(sql.contains("CREATE TABLE") && sql.contains("siteurl"))
            if !target.isPostgres { #expect(!sql.contains("_transient_feed_abc")) }
            #expect(log.tables.count >= 2, "events: \(log.events)")
            #expect(summary.tables.count >= 2)
            // no credentials file left behind
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?
                .filter { $0.hasPrefix("querywell-secret-") } ?? []
            #expect(leftovers.isEmpty)
        }
    }

    @Test func localToolThroughASSHTunnel() async throws {
        let tools = await DumpToolLocator().locate()
        let bed = try SSHTestBed()
        let target = DBTarget.mysql8
        try await SchemaFixture.with(target) { f in
            let selection = DumpToolSelector.select(for: f.session.serverInfo, from: tools)
            guard selection.isUsable else { return }
            let fx = ExportFixture(f: f)
            try await fx.create()
            let tunnel = try await SystemSSHTunnelProvider(options: bed.options).open(
                SSHTunnelRequest(ssh: bed.config, secret: nil, remoteHost: "mysql8", remotePort: 3306))
            defer { Task { await tunnel.close() } }
            var t = fx.target(bed: bed)
            t.localEndpoint = .init(host: tunnel.localHost, port: tunnel.localPort)
            let plan = try ExportPlanner.plan(target: t, options: ExportOptions(location: .localThroughTunnel), tool: selection)
            let out = try tempOutputDirectory()
            defer { try? FileManager.default.removeItem(at: out) }
            let dest = out.appendingPathComponent(plan.outputFilename)
            try await runner.run(plan: plan, to: dest)
            #expect(try fx.gunzipped(dest).contains("CREATE TABLE `wp_posts`"))
        }
    }
}
