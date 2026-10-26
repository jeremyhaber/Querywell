import Foundation
import Testing

@testable import QuerywellCore

let nastyPasswords: [String] = [
    "simple",
    "with space and 'single' quotes",
    #"double "quotes" and \backslash\"#,
    "dollar $HOME $(id) `id` ${PATH}",
    "semi; pipe | amp & redirect > < glob * ? [a]",
    "hash # percent % bang !",
    "new\nline and\ttab and\rCR",
    "ünïcödé 🙂 pässwörd",
    "'",
    "''",
    "\\",
    "end with space ",
]

private let utc = TimeZone(identifier: "UTC")!
private let fixedNow = Date(timeIntervalSince1970: 1_793_028_600)  // 2026-10-26 15:30 UTC

private func target(
    engine: DatabaseEngine = .mysql, password: String? = "s3cr3t'pw", database: String = "wp_db",
    ssh: SSHTunnelConfig? = SSHTunnelConfig(host: "bastion.example.com", port: 2222, user: "deploy", auth: .keyFile(path: "/Users/me/.ssh/id_ed25519"))
) -> ExportTarget {
    ExportTarget(engine: engine, database: database, user: "wpuser", password: password,
                 remoteEndpoint: .init(host: "db.internal", port: engine == .postgresql ? 5432 : 3306),
                 localEndpoint: .init(host: "127.0.0.1", port: 54321), ssh: ssh,
                 sshSecretKey: SecretKey(ownerID: "abc", kind: .sshKeyPassphrase))
}

private func plan(_ t: ExportTarget, _ o: ExportOptions, tool: ToolSelection? = nil) throws -> ExportPlan {
    try ExportPlanner.plan(target: t, options: o, tool: tool, now: fixedNow, timeZone: utc)
}

private func localTool(_ name: String, _ flavour: ToolFlavour, extra: [String] = []) -> ToolSelection {
    ToolSelection(tool: ToolInfo(path: "/opt/homebrew/bin/\(name)", name: name, role: .dump, flavour: flavour,
                                 version: ToolVersion(8, 0, 36), versionOutput: ""), issues: [], extraArguments: extra)
}

@Suite("Shell quoting")
struct ShellQuotingTests {
    @Test(arguments: nastyPasswords)
    func posixQuotingRoundTripsThroughRealSh(_ s: String) throws {
        let out = try runTool("/bin/sh", ["-c", "printf %s \(ShellQuoting.posix(s))"])
        #expect(String(decoding: out, as: UTF8.self) == s)
    }

    @Test func safeStringsAreLeftBare() {
        #expect(ShellQuoting.posix("--host=db.internal") == "--host=db.internal")
        #expect(ShellQuoting.posix("") == "''")
        #expect(ShellQuoting.posix("a b") == "'a b'")
        #expect(ShellQuoting.posix("it's") == #"'it'\''s'"#)
    }

    @Test func optionFileValuesEscape() {
        #expect(ShellQuoting.mysqlOptionValue(#"a"b\c"#) == #""a\"b\\c""#)
        #expect(ShellQuoting.mysqlOptionValue("x\ny") == #""x\ny""#)
        #expect(ShellQuoting.pgpassField(#"a:b\c"#) == #"a\:b\\c"#)
    }

    /// The real MariaDB/MySQL option-file parser must read back exactly what we wrote.
    @Test(arguments: nastyPasswords.filter { !$0.contains("\n") && !$0.contains("\t") && !$0.contains("\r") && !$0.hasSuffix(" ") })
    func optionFileIsParsedByRealMysqldump(_ pw: String) throws {
        let tool = ["/opt/homebrew/bin/mysqldump", "/usr/local/bin/mysqldump"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let tool else { return }  // no local client: covered by the integration tests
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qw-cnf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cnf = dir.appendingPathComponent("c.cnf")
        try Data("[client]\nuser=\(ShellQuoting.mysqlOptionValue("u"))\npassword=\(ShellQuoting.mysqlOptionValue(pw))\n".utf8).write(to: cnf)
        let out = String(decoding: try runTool(tool, ["--defaults-extra-file=\(cnf.path)", "--print-defaults"]), as: UTF8.self)
        #expect(out.contains("--password=\(pw)"), "parsed: \(out)")
    }
}

@Suite("Export command planning")
struct ExportPlanningTests {
    @Test func filenameIsDatabaseAndTimestamp() throws {
        let p = try plan(target(), ExportOptions())
        #expect(p.outputFilename == "wp_db-20261026-1530.sql.gz")
        #expect(try plan(target(), ExportOptions(gzip: false)).outputFilename == "wp_db-20261026-1530.sql")
        #expect(ExportPlanner.outputFilename(database: "we/ird db", gzip: true, now: fixedNow, timeZone: utc) == "we_ird_db-20261026-1530.sql.gz")
    }

    @Test func remotePlanSendsScriptOnStdinAndNeverPutsPasswordInArguments() throws {
        let t = target(password: "s3cr3t'pw\"$x")
        let p = try plan(t, ExportOptions(tables: ["a", "b"]))
        #expect(p.steps.count == 1)
        let step = p.steps[0]
        #expect(step.usesSSH)
        #expect(step.arguments.suffix(3) == ["-T", "deploy@bastion.example.com", "sh -s"])
        #expect(step.arguments.contains("2222"))
        #expect(step.arguments.joined(separator: " ").contains("s3cr3t") == false)
        #expect(step.environment.isEmpty)
        let script = String(decoding: step.standardInput ?? Data(), as: UTF8.self)
        #expect(script.contains(ShellQuoting.mysqlOptionValue("s3cr3t'pw\"$x")))
        #expect(script.contains("--single-transaction"))
        #expect(script.contains("| gzip -c"))
        #expect(script.contains("umask 077"))
        #expect(script.contains("trap 'rm -rf \"$QW_T\"' EXIT"))
        #expect(p.remoteCompressed && p.outputCompressed && p.localStages.isEmpty)

        #expect(!p.displayCommand.contains("s3cr3t"))
        #expect(p.displayCommand.contains("password=\"****\""))
        #expect(p.displayCommand.contains("sh -s <<'QW_SCRIPT'"))
        #expect(p.displayCommand.hasPrefix("# "))
        #expect(p.displayCommand.contains("> wp_db-20261026-1530.sql.gz"))
        #expect(p.displayCommand.contains("deploy@bastion.example.com"))
        #expect(p.displayCommand.hasSuffix("QW_SCRIPT"))
    }

    @Test func remoteRequiresSSH() {
        #expect(throws: ExportPlanError.sshRequiredForRemoteExport) { _ = try plan(target(ssh: nil), ExportOptions()) }
        #expect(throws: ExportPlanError.emptyDatabaseName) { _ = try plan(target(database: ""), ExportOptions()) }
    }

    @Test func localStagesFollowTheOptions() throws {
        let tool = localTool("mysqldump", .mysql)
        let m = CollationMapping.mysql57MariaDBCompatible
        #expect(try plan(target(), ExportOptions(collation: m)).localStages == ["gunzip", "collation rewrite", "gzip"])
        #expect(try plan(target(), ExportOptions(gzip: false, collation: m)).localStages == ["collation rewrite"])
        #expect(try plan(target(), ExportOptions(gzip: false)).localStages.isEmpty)
        #expect(try plan(target(), ExportOptions(location: .localThroughTunnel), tool: tool).localStages == ["gzip"])
        #expect(try plan(target(), ExportOptions(collation: m, location: .localThroughTunnel), tool: tool).localStages == ["collation rewrite", "gzip"])
        let withRewrite = try plan(target(), ExportOptions(collation: m))
        #expect(withRewrite.displayCommand.contains("<Querywell collation rewrite>"))
        #expect(withRewrite.displayCommand.contains("gunzip -c"))
    }

    @Test func mysqlFlagsFollowTheOptions() throws {
        let o = ExportOptions(
            scope: .structureOnly, singleTransaction: false, addDropTable: false, includeRoutines: true, includeTriggers: false,
            includeEvents: true, extendedInserts: false, hexBlob: true, location: .localThroughTunnel)
        let args = try plan(target(), o, tool: localTool("mysqldump", .mysql, extra: ["--column-statistics=0"])).steps[0].arguments
        for flag in ["--no-data", "--skip-add-drop-table", "--routines", "--skip-triggers", "--events", "--skip-extended-insert", "--hex-blob",
                     "--column-statistics=0", "--verbose", "--default-character-set=utf8mb4", "--protocol=tcp"] {
            #expect(args.contains(flag), "missing \(flag)")
        }
        #expect(!args.contains("--single-transaction"))
        #expect(args.contains("--port=54321") && args.contains("--host=127.0.0.1"))
        #expect(args.last == "wp_db")
        let dataOnly = try plan(target(), ExportOptions(scope: .dataOnly, location: .localThroughTunnel), tool: localTool("mysqldump", .mysql)).steps[0].arguments
        #expect(dataOnly.contains("--no-create-info"))
        #expect(dataOnly.contains("--single-transaction"))
    }

    @Test func localMySQLPutsPasswordInASecretFileNotArguments() throws {
        let p = try plan(target(password: "p@ss'w\"rd"), ExportOptions(location: .localThroughTunnel), tool: localTool("mysqldump", .mysql))
        let step = p.steps[0]
        #expect(step.executable == "/opt/homebrew/bin/mysqldump")
        #expect(step.arguments[0] == "--defaults-extra-file=\(DumpPlaceholders.secretDirectory)/client.cnf")
        #expect(!step.arguments.joined().contains("p@ss"))
        #expect(step.environment.isEmpty)
        let cnf = String(decoding: step.secretFiles[0].contents, as: UTF8.self)
        #expect(cnf == "[client]\nuser=\"wpuser\"\npassword=\"p@ss'w\\\"rd\"\n")
        #expect(!p.displayCommand.contains("p@ss"))
        #expect(p.displayCommand.contains("mktemp -d"))
        #expect(p.displayCommand.contains("--defaults-extra-file=\"$QW_DIR/client.cnf\""))
        #expect(p.displayCommand.contains("| gzip -c > wp_db-20261026-1530.sql.gz"))
    }

    @Test func localPostgresUsesPGPASSWORDEnvironment() throws {
        let t = target(engine: .postgresql, password: "pg'secret")
        let p = try plan(t, ExportOptions(scope: .dataOnly, tables: ["public.posts"], extendedInserts: false, location: .localThroughTunnel),
                         tool: localTool("pg_dump", .postgres))
        let step = p.steps[0]
        #expect(step.environment == ["PGPASSWORD": "pg'secret"])
        #expect(!step.arguments.joined().contains("pg'secret"))
        for a in ["--data-only", "--inserts", "-t", "public.posts", "--username=wpuser", "--port=54321", "--verbose"] { #expect(step.arguments.contains(a), "\(a)") }
        #expect(p.displayCommand.contains("PGPASSWORD=**** /opt/homebrew/bin/pg_dump"))
        #expect(!p.displayCommand.contains("pg'secret"))
        let clean = try plan(t, ExportOptions(location: .localThroughTunnel), tool: localTool("pg_dump", .postgres)).steps[0].arguments
        #expect(clean.contains("--clean") && clean.contains("--if-exists"))
    }

    @Test func toolMismatchAndMissingToolFail() {
        #expect(throws: ExportPlanError.self) { _ = try plan(target(), ExportOptions(location: .localThroughTunnel)) }
        #expect(throws: ExportPlanError.self) {
            _ = try plan(target(engine: .postgresql), ExportOptions(location: .localThroughTunnel), tool: localTool("mysqldump", .mysql))
        }
    }

    @Test func transientsAreDumpedInASeparateInvocation() throws {
        let o = ExportOptions(skipWordPressTransients: true, optionsTables: ["wp_options"], location: .localThroughTunnel)
        let p = try plan(target(), o, tool: localTool("mysqldump", .mysql))
        #expect(p.steps.count == 2)
        let main = p.steps[0].arguments, opts = p.steps[1].arguments
        #expect(main.contains("--ignore-table=wp_db.wp_options"))
        #expect(!main.contains { $0.hasPrefix("--where") })
        #expect(opts.contains("--where=\(ExportPlanner.transientWhere)"))
        #expect(opts.suffix(2) == ["wp_db", "wp_options"])
        #expect(ExportPlanner.transientWhere == #"option_name NOT LIKE '\_transient\_%' AND option_name NOT LIKE '\_site\_transient\_%'"#)
        #expect(p.displayCommand.contains("{ "))

        // routines belong to the main invocation only
        let withRoutines = try plan(target(), ExportOptions(skipWordPressTransients: true, optionsTables: ["wp_options"], includeRoutines: true, location: .localThroughTunnel),
                                    tool: localTool("mysqldump", .mysql))
        #expect(withRoutines.steps[0].arguments.contains("--routines"))
        #expect(!withRoutines.steps[1].arguments.contains("--routines"))

        // explicit table list: options table moves to its own invocation
        let explicit = try plan(target(), ExportOptions(tables: ["wp_posts", "wp_options"], skipWordPressTransients: true,
                                                        optionsTables: ["wp_options"], location: .localThroughTunnel), tool: localTool("mysqldump", .mysql))
        #expect(explicit.steps[0].arguments.suffix(2) == ["wp_db", "wp_posts"])
        #expect(explicit.steps[1].arguments.suffix(2) == ["wp_db", "wp_options"])
        // only the options table selected -> a single filtered invocation
        let onlyOptions = try plan(target(), ExportOptions(tables: ["wp_options"], skipWordPressTransients: true, optionsTables: ["wp_options"],
                                                           location: .localThroughTunnel), tool: localTool("mysqldump", .mysql))
        #expect(onlyOptions.steps.count == 1)
        #expect(onlyOptions.steps[0].arguments.contains("--where=\(ExportPlanner.transientWhere)"))
        // structure only: nothing to filter
        let structure = try plan(target(), ExportOptions(scope: .structureOnly, skipWordPressTransients: true, optionsTables: ["wp_options"],
                                                         location: .localThroughTunnel), tool: localTool("mysqldump", .mysql))
        #expect(structure.steps.count == 1)
        #expect(throws: ExportPlanError.transientsNeedOptionsTables) {
            _ = try plan(target(), ExportOptions(skipWordPressTransients: true))
        }
    }

    @Test func postgresWarnsAboutUnsupportedOptions() throws {
        let p = try plan(target(engine: .postgresql), ExportOptions(skipWordPressTransients: true, collation: .legacyUnicodeCI))
        #expect(p.warnings.count == 2)
        #expect(p.collation == nil)
        #expect(p.localStages.isEmpty)
    }

    @Test func postgresRemoteRejectsPasswordsWithLineBreaks() {
        #expect(throws: ExportPlanError.self) { _ = try plan(target(engine: .postgresql, password: "a\nb"), ExportOptions()) }
        #expect(throws: Never.self) { _ = try plan(target(engine: .postgresql, password: "a:b\\c'd"), ExportOptions()) }
    }
}

// MARK: - The remote script, executed for real with stub tools

@Suite("Remote export script")
struct RemoteScriptTests {
    /// A temp area with a PATH containing stub `mysqldump`/`pg_dump` scripts.
    struct Sandbox {
        let root: URL
        let bin: URL
        let tmp: URL

        init(mysqldump: String? = nil, pgDump: String? = nil) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("qw-script-\(UUID().uuidString)")
            bin = root.appendingPathComponent("bin")
            tmp = root.appendingPathComponent("tmp")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            if let mysqldump { try write("mysqldump", mysqldump) }
            if let pgDump { try write("pg_dump", pgDump) }
        }

        func write(_ name: String, _ body: String) throws {
            let url = bin.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func run(script: String) throws -> (stdout: Data, status: Int32, stderr: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-s"]
            p.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "TMPDIR": tmp.path]
            let inp = Pipe(), out = Pipe(), err = Pipe()
            p.standardInput = inp
            p.standardOutput = out
            p.standardError = err
            try p.run()
            try? inp.fileHandleForWriting.write(contentsOf: Data(script.utf8))
            try? inp.fileHandleForWriting.close()
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return (data, p.terminationStatus, e)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    static let echoingMysqldump = """
    case "$1" in --help) echo "--no-tablespaces --column-statistics --set-gtid-purged"; exit 0;; esac
    f="${1#--defaults-extra-file=}"
    echo "-- ARGS: $*"
    cat "$f"
    echo "-- Retrieving table structure for table t1..." >&2
    exit ${QW_STUB_EXIT:-0}
    """

    @Test(arguments: nastyPasswords)
    func scriptWritesPasswordToAPrivateTempFileThenCleansUp(_ pw: String) throws {
        let box = try Sandbox(mysqldump: Self.echoingMysqldump)
        defer { box.cleanup() }
        let script = try ExportPlanner.remoteScript(target: target(password: pw), options: ExportOptions(gzip: false), redactPassword: false)
        let r = try box.run(script: script)
        #expect(r.status == 0, "stderr: \(r.stderr)")
        let out = String(decoding: r.stdout, as: UTF8.self)
        #expect(out.contains("password=\(ShellQuoting.mysqlOptionValue(pw))\n"), "output: \(out)")
        #expect(out.contains("user=\"wpuser\""))
        #expect(out.contains("--no-tablespaces") && out.contains("--column-statistics=0") && out.contains("--set-gtid-purged=OFF"))
        #expect(out.contains("--host=db.internal") && out.contains("--port=3306"))
        // the password is never an argument of the dump tool
        let argsLine = out.split(separator: "\n").first { $0.hasPrefix("-- ARGS:") } ?? ""
        #expect(!argsLine.contains(pw) || pw.count < 3)
        // temp directory removed by the trap
        #expect((try FileManager.default.contentsOfDirectory(atPath: box.tmp.path)).isEmpty)
    }

    @Test func gzipPipelineAndExitStatusPropagation() throws {
        let box = try Sandbox(mysqldump: Self.echoingMysqldump)
        defer { box.cleanup() }
        let script = try ExportPlanner.remoteScript(target: target(), options: ExportOptions(), redactPassword: false)
        let ok = try box.run(script: script)
        #expect(ok.status == 0)
        let text = String(decoding: try Gzip.decompress(ok.stdout), as: UTF8.self)
        #expect(text.contains("-- ARGS:"))

        // a failing dump tool must fail the script even though gzip succeeds
        let failing = try Sandbox(mysqldump: Self.echoingMysqldump)
        defer { failing.cleanup() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-s"]
        p.environment = ["PATH": "\(failing.bin.path):/usr/bin:/bin", "TMPDIR": failing.tmp.path, "QW_STUB_EXIT": "3"]
        let inp = Pipe()
        p.standardInput = inp
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        try? inp.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try? inp.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(p.terminationStatus == 3)
        #expect((try FileManager.default.contentsOfDirectory(atPath: failing.tmp.path)).isEmpty)
    }

    @Test func missingToolIsAClearError() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let script = try ExportPlanner.remoteScript(target: target(), options: ExportOptions(gzip: false), redactPassword: false)
        let r = try box.run(script: script)
        #expect(r.status == 127)
        #expect(r.stderr.contains("mysqldump was not found"))
    }

    @Test func transientInvocationsRunBackToBack() throws {
        let box = try Sandbox(mysqldump: """
            case "$1" in --help) echo "--no-tablespaces"; exit 0;; esac
            echo "-- CALL: $*"
            """)
        defer { box.cleanup() }
        let script = try ExportPlanner.remoteScript(
            target: target(), options: ExportOptions(gzip: false, skipWordPressTransients: true, optionsTables: ["wp_options"]), redactPassword: false)
        let r = try box.run(script: script)
        let calls = String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("-- CALL:") }
        #expect(calls.count == 2)
        #expect(calls[0].contains("--ignore-table=wp_db.wp_options"))
        #expect(calls[1].contains("--where=option_name NOT LIKE"))
        #expect(calls[1].hasSuffix("wp_db wp_options"))
    }

    @Test func postgresScriptUsesPgpassFile() throws {
        let box = try Sandbox(pgDump: """
            echo "-- ARGS: $*"
            echo "-- PGPASSFILE=$PGPASSFILE"
            cat "$PGPASSFILE"
            echo "-- PGPASSWORD=${PGPASSWORD:-unset}"
            """)
        defer { box.cleanup() }
        let t = target(engine: .postgresql, password: "pa:ss\\w'rd")
        let script = try ExportPlanner.remoteScript(target: t, options: ExportOptions(gzip: false), redactPassword: false)
        let r = try box.run(script: script)
        let out = String(decoding: r.stdout, as: UTF8.self)
        #expect(r.status == 0, "stderr: \(r.stderr)")
        #expect(out.contains("*:*:*:wpuser:pa\\:ss\\\\w'rd\n"), "\(out)")
        #expect(out.contains("-- PGPASSWORD=unset"))
        let args = out.split(separator: "\n").first { $0.hasPrefix("-- ARGS:") } ?? ""
        #expect(!args.contains("pa:ss"))
        #expect((try FileManager.default.contentsOfDirectory(atPath: box.tmp.path)).isEmpty)
    }
}
