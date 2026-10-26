import Foundation

// Pure construction of export commands: options → ExportPlan (steps to run + an exact, copyable preview).

public enum ExportScope: String, Sendable, Hashable, CaseIterable {
    case structureAndData, structureOnly, dataOnly
}

/// What to export of one table. A missing entry in ``ExportOptions/tableModes`` means ``both``.
public enum TableExportMode: String, Sendable, Hashable, Codable, CaseIterable {
    case both, structureOnly, dataOnly, skip
}

public enum ExportLocation: String, Sendable, Hashable {
    /// `ssh user@host sh -s` with the dump tool running *on the server*; one compressed file comes back.
    case remoteOverSSH
    /// The local Mac's dump tool talks to the database through the SSH tunnel (or directly).
    case localThroughTunnel
}

public struct ExportOptions: Sendable, Equatable {
    public var scope: ExportScope
    /// MySQL `--single-transaction` (consistent InnoDB snapshot, no table locks). pg_dump always uses one snapshot.
    public var singleTransaction: Bool
    /// `DROP TABLE IF EXISTS` before each `CREATE TABLE` (pg_dump: `--clean --if-exists`).
    public var addDropTable: Bool
    /// Compress the result (`.sql.gz`). Remote exports compress on the server, so only compressed bytes cross the wire.
    public var gzip: Bool
    /// `nil` = every table in the database.
    public var tables: [String]?
    /// Per-table overrides (missing = ``TableExportMode/both``). The planner groups tables by mode into up to
    /// three dump invocations whose output is concatenated into one stream: normal, `--no-data`
    /// (structure only), `--no-create-info` (data only); skipped tables are left out. The global ``scope``
    /// applies to the tables without an entry.
    public var tableModes: [String: TableExportMode]
    /// WordPress: leave out rows of `<prefix>options` whose `option_name` starts with `_transient_` or
    /// `_site_transient_`. MySQL/MariaDB only — see ``ExportPlanner`` for how this is built.
    public var skipWordPressTransients: Bool
    /// The options tables that `skipWordPressTransients` applies to (the caller detects them, e.g. tables
    /// ending in `options` with `option_name` + `option_value` columns). Required when the option is on.
    public var optionsTables: [String]
    public var includeRoutines: Bool
    public var includeTriggers: Bool
    public var includeEvents: Bool
    /// Rewrite charsets/collations in the DDL while exporting (see ``CollationRewriter``); `nil` keeps the original.
    public var collation: CollationMapping?
    /// MySQL `--extended-insert` (multi-row INSERTs, default). Postgres: off means `--inserts` instead of `COPY`.
    public var extendedInserts: Bool
    /// MySQL `--hex-blob`: binary columns as `0x…` literals.
    public var hexBlob: Bool
    public var location: ExportLocation
    /// PostgreSQL: the schema to dump. `pg_dump` otherwise dumps every schema of the database, so table names
    /// (`tables`, `tableModes`) are qualified with it and `--schema` limits the run. Ignored by MySQL/MariaDB,
    /// whose "schema" is the target database itself.
    public var schema: String?

    public init(
        scope: ExportScope = .structureAndData, singleTransaction: Bool = true, addDropTable: Bool = true,
        gzip: Bool = true, tables: [String]? = nil, skipWordPressTransients: Bool = false, optionsTables: [String] = [],
        includeRoutines: Bool = false, includeTriggers: Bool = true, includeEvents: Bool = false,
        collation: CollationMapping? = nil, extendedInserts: Bool = true, hexBlob: Bool = false,
        location: ExportLocation = .remoteOverSSH, tableModes: [String: TableExportMode] = [:], schema: String? = nil
    ) {
        self.schema = schema
        self.scope = scope
        self.singleTransaction = singleTransaction
        self.addDropTable = addDropTable
        self.gzip = gzip
        self.tables = tables
        self.tableModes = tableModes
        self.skipWordPressTransients = skipWordPressTransients
        self.optionsTables = optionsTables
        self.includeRoutines = includeRoutines
        self.includeTriggers = includeTriggers
        self.includeEvents = includeEvents
        self.collation = collation
        self.extendedInserts = extendedInserts
        self.hexBlob = hexBlob
        self.location = location
    }
}

/// Where and as whom to dump.
public struct ExportTarget: Sendable {
    public struct Endpoint: Sendable, Hashable {
        public var host: String
        public var port: Int
        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }
    }

    public var engine: DatabaseEngine
    public var database: String
    public var user: String
    public var password: String?
    /// Database address as seen from the SSH server (the profile's host/port). Used by `.remoteOverSSH`.
    public var remoteEndpoint: Endpoint
    /// Address the Mac reaches the database at: the tunnel's `127.0.0.1:port`, or the real host without SSH.
    /// Used by `.localThroughTunnel`.
    public var localEndpoint: Endpoint
    public var ssh: SSHTunnelConfig?
    /// Keychain address of the SSH password / key passphrase (read at run time, never stored in the plan).
    public var sshSecretKey: SecretKey?

    public init(engine: DatabaseEngine, database: String, user: String, password: String?, remoteEndpoint: Endpoint,
                localEndpoint: Endpoint? = nil, ssh: SSHTunnelConfig? = nil, sshSecretKey: SecretKey? = nil) {
        self.engine = engine
        self.database = database
        self.user = user
        self.password = password
        self.remoteEndpoint = remoteEndpoint
        self.localEndpoint = localEndpoint ?? remoteEndpoint
        self.ssh = ssh
        self.sshSecretKey = sshSecretKey
    }

    /// Builds a target from a saved profile. Pass the tunnel's local port when the connection is tunnelled.
    public init(profile: ConnectionProfile, database: String, password: String?, tunnelLocalPort: Int? = nil,
                sshSecretOwnerID: String? = nil) {
        let secretKind: SecretKind? = {
            switch profile.ssh?.auth {
            case .password: .sshPassword
            case .keyFile: .sshKeyPassphrase
            default: nil
            }
        }()
        self.init(
            engine: profile.engine, database: database, user: profile.user, password: password,
            remoteEndpoint: Endpoint(host: profile.host, port: profile.port),
            localEndpoint: tunnelLocalPort.map { Endpoint(host: "127.0.0.1", port: $0) },
            ssh: profile.ssh,
            sshSecretKey: secretKind.map { SecretKey(ownerID: sshSecretOwnerID ?? profile.id.uuidString, kind: $0) })
    }
}

public enum DumpPlaceholders {
    /// Replaced by the runner with the path of a private (0700) temp directory holding the step's secret files.
    public static let secretDirectory = "@@QW_SECRET_DIR@@"
}

public struct PlannedSecretFile: Sendable, Hashable {
    public var name: String
    public var contents: Data
}

/// One process to run. Steps are executed in order; each step's stdout is appended to the dump stream.
public struct CommandStep: Sendable, Hashable {
    public var label: String
    public var executable: String
    public var arguments: [String]
    /// Extra environment (may hold a secret, e.g. `PGPASSWORD`); never shown in ``ExportPlan/displayCommand``.
    public var environment: [String: String]
    /// Bytes written to the process's stdin, then closed (the remote shell script).
    public var standardInput: Data?
    /// Files created (0600) in a private temp directory before the step runs and removed afterwards.
    public var secretFiles: [PlannedSecretFile]
    /// Whether the step authenticates to SSH (the runner then provides askpass for the stored secret).
    public var usesSSH: Bool
}

public struct ExportPlan: Sendable {
    public var steps: [CommandStep]
    /// The exact command to run by hand, secrets replaced by `****`. Multi-line when a script is involved.
    public var displayCommand: String
    /// Suggested file name: `<db>-YYYYMMDD-HHMM.sql.gz` (`.sql` without gzip).
    public var outputFilename: String
    public var location: ExportLocation
    public var engine: DatabaseEngine
    /// The bytes the steps print are gzip data (compressed on the server).
    public var remoteCompressed: Bool
    /// The file written is gzip data.
    public var outputCompressed: Bool
    public var collation: CollationMapping?
    /// Names of the local stream stages between the steps and the file, for display ("gunzip", "collation rewrite", "gzip").
    public var localStages: [String]
    public var tables: [String]?
    public var ssh: SSHTunnelConfig?
    public var sshSecretKey: SecretKey?
    public var warnings: [String]
}

public enum ExportPlanError: Error, Equatable, Sendable, LocalizedError {
    case sshRequiredForRemoteExport
    case toolRequired(String)
    case transientsNeedOptionsTables
    case passwordNotRepresentable(String)
    case emptyDatabaseName

    public var errorDescription: String? {
        switch self {
        case .sshRequiredForRemoteExport: "Exporting on the server needs an SSH connection; choose to run the export locally instead."
        case .toolRequired(let m): m
        case .transientsNeedOptionsTables: "Skipping WordPress transients needs the name of the options table (for example wp_options)."
        case .passwordNotRepresentable(let m): m
        case .emptyDatabaseName: "Choose a database to export."
        }
    }
}

// MARK: - Shell quoting

public enum ShellQuoting {
    /// POSIX sh single-quote quoting. Safe for any string, including newlines, `$`, backticks and quotes.
    public static func posix(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-")
        if s.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func posix(_ args: [String]) -> String { args.map(posix).joined(separator: " ") }

    /// A MySQL option-file value: always double-quoted, with `\`, `"` and control characters escaped.
    public static func mysqlOptionValue(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{8}": out += "\\b"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out + "\""
    }

    /// A `.pgpass` field: `\` and `:` escaped. Newlines can't be represented (see ``ExportPlanError/passwordNotRepresentable(_:)``).
    public static func pgpassField(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ":", with: "\\:")
    }
}

// MARK: - Planner

public enum ExportPlanner {
    /// The `--where` that drops WordPress transients. `\_` keeps LIKE's `_` literal; no further escaping is
    /// needed because MySQL leaves `\_` and `\%` untouched in string literals.
    public static let transientWhere = "option_name NOT LIKE '\\_transient\\_%' AND option_name NOT LIKE '\\_site\\_transient\\_%'"

    /// Builds the plan.
    ///
    /// **Transients (MySQL/MariaDB).** `mysqldump --where` applies to *every* dumped table, so the options
    /// table is dumped in its own invocation with the `--where`, and everything else in another invocation
    /// that `--ignore-table`s it (or, with an explicit table list, simply omits it). The invocations run back
    /// to back inside one shell and their output is concatenated into a single stream/file. Each invocation
    /// is self-contained SQL (header + footer restoring session settings), so the concatenation imports
    /// cleanly. With `--single-transaction` each invocation has its own snapshot; use a quiet database if
    /// the options table must be consistent with the rest.
    ///
    /// **Remote password handling.** The script is sent on the SSH *stdin* (`sh -s`), never as a command-line
    /// argument, so the password never appears in the server's process list. Inside, it is written to a
    /// `umask 077` temp file (here-doc, removed by a trap) that the dump tool reads via
    /// `--defaults-extra-file` (MySQL) or `PGPASSFILE` (Postgres).
    ///
    /// - Parameters:
    ///   - tool: required for `.localThroughTunnel`; its ``ToolSelection/extraArguments`` are added.
    public static func plan(
        target: ExportTarget, options: ExportOptions, tool: ToolSelection? = nil,
        sshOptions: SSHClientOptions = SSHClientOptions(), sshHasSecret: Bool = false,
        now: Date = Date(), timeZone: TimeZone = .current
    ) throws -> ExportPlan {
        guard !target.database.isEmpty else { throw ExportPlanError.emptyDatabaseName }
        if options.skipWordPressTransients, options.optionsTables.isEmpty, target.engine != .postgresql {
            throw ExportPlanError.transientsNeedOptionsTables
        }
        var warnings: [String] = []
        if target.engine == .postgresql {
            if options.skipWordPressTransients { warnings.append("pg_dump can't filter rows, so WordPress transients are included.") }
            if options.collation != nil { warnings.append("Collation rewriting only applies to MySQL/MariaDB dumps; ignored for PostgreSQL.") }
        }
        let rewrite: CollationMapping? = target.engine == .postgresql ? nil : options.collation
        let filename = outputFilename(database: target.database, gzip: options.gzip, now: now, timeZone: timeZone)

        var plan: ExportPlan
        switch options.location {
        case .remoteOverSSH:
            guard let ssh = target.ssh else { throw ExportPlanError.sshRequiredForRemoteExport }
            plan = try remotePlan(target: target, ssh: ssh, options: options, sshOptions: sshOptions, sshHasSecret: sshHasSecret)
        case .localThroughTunnel:
            guard let tool, let info = tool.tool else {
                throw ExportPlanError.toolRequired(tool?.issues.first?.message
                    ?? "No local dump tool selected. Install the database client tools or export on the server over SSH.")
            }
            plan = try localPlan(target: target, options: options, tool: info, extraArguments: tool.extraArguments)
        }
        plan.outputFilename = filename
        plan.collation = rewrite
        plan.outputCompressed = options.gzip
        plan.remoteCompressed = options.gzip && options.location == .remoteOverSSH
        plan.tables = options.tables
        plan.warnings = warnings
        plan.localStages = []
        if plan.remoteCompressed && (rewrite != nil || !options.gzip) { plan.localStages.append("gunzip") }
        if rewrite != nil { plan.localStages.append("collation rewrite") }
        if options.gzip && (!plan.remoteCompressed || rewrite != nil) { plan.localStages.append("gzip") }
        plan.displayCommand = try display(plan: plan, target: target, options: options)
        return plan
    }

    public static func outputFilename(database: String, gzip: Bool, now: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let stamp = String(format: "%04d%02d%02d-%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        let safe = String(database.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
        return "\(safe)-\(stamp).sql" + (gzip ? ".gz" : "")
    }

    // MARK: MySQL argument sets

    /// Dump-tool flags shared by local and remote runs (no connection flags, no database/tables).
    static func mysqlFlags(_ o: ExportOptions) -> [String] {
        var a = ["--default-character-set=utf8mb4", "--verbose"]
        if o.singleTransaction { a.append("--single-transaction") }
        switch o.scope {
        case .structureOnly: a.append("--no-data")
        case .dataOnly: a.append("--no-create-info")
        case .structureAndData: break
        }
        if !o.addDropTable { a.append("--skip-add-drop-table") }
        if o.includeRoutines { a.append("--routines") }
        if !o.includeTriggers { a.append("--skip-triggers") }
        if o.includeEvents { a.append("--events") }
        if !o.extendedInserts { a.append("--skip-extended-insert") }
        if o.hexBlob { a.append("--hex-blob") }
        return a
    }

    /// The mysqldump invocations (arguments after the connection flags): `(label, arguments)`.
    ///
    /// Tables are grouped by ``TableExportMode``: the "both" group (everything not named otherwise, using the
    /// global scope), a `--no-data` group, a `--no-create-info` group. Skipped tables are `--ignore-table`d
    /// (or simply left out of an explicit table list). Routines and events are dumped by the first invocation only.
    static func mysqlInvocations(database: String, options o: ExportOptions) -> [(label: String, args: [String])] {
        let modes = o.tableModes
        func members(_ m: TableExportMode) -> [String] {
            let names = modes.filter { $0.value == m }.map(\.key).sorted()
            guard let universe = o.tables else { return names }
            return names.filter(universe.contains)
        }
        let structure = members(.structureOnly), dataOnly = members(.dataOnly), skipped = members(.skip)
        let others = Set(structure + dataOnly + skipped)
        var out: [(label: String, args: [String])] = []

        func add(label: String, scope: ExportScope, tables: [String]?, ignores: [String]) {
            var opts = o
            opts.scope = scope
            var flags = mysqlFlags(opts)
            if !out.isEmpty { flags.removeAll { $0 == "--routines" || $0 == "--events" } }
            out += transientAwareInvocations(database: database, options: opts, flags: flags, label: label, tables: tables, ignores: ignores)
        }

        // Everything without an override.
        let bothTables = o.tables.map { $0.filter { !others.contains($0) } }
        if bothTables?.isEmpty != true {
            add(label: "Dump \(database)", scope: o.scope, tables: bothTables, ignores: bothTables == nil ? Array(others).sorted() : [])
        }
        if !structure.isEmpty { add(label: "Dump \(database) structure only", scope: .structureOnly, tables: structure, ignores: []) }
        if !dataOnly.isEmpty { add(label: "Dump \(database) data only", scope: .dataOnly, tables: dataOnly, ignores: []) }
        return out
    }

    /// One group's invocation(s). With WordPress transient skipping, the options table is dumped on its own with
    /// the `--where`, and the rest of the group in another invocation that leaves it out.
    private static func transientAwareInvocations(
        database: String, options o: ExportOptions, flags: [String], label: String, tables: [String]?, ignores: [String]
    ) -> [(label: String, args: [String])] {
        let ignoreArgs = { (names: [String]) in names.map { "--ignore-table=\(database).\($0)" } }
        let filterRows = o.skipWordPressTransients && o.scope != .structureOnly && !o.optionsTables.isEmpty
        guard filterRows else {
            return [(label, flags + ignoreArgs(ignores) + [database] + (tables ?? []))]
        }
        let optionsTables = o.optionsTables
        var out: [(label: String, args: [String])] = []
        if let tables {
            let rest = tables.filter { !optionsTables.contains($0) }
            if !rest.isEmpty { out.append((label, flags + [database] + rest)) }
        } else {
            out.append((label, flags + ignoreArgs(ignores + optionsTables.filter { !ignores.contains($0) }) + [database]))
        }
        let included = tables.map { t in optionsTables.filter(t.contains) } ?? optionsTables.filter { !ignores.contains($0) }
        for table in included {
            // Routines/events belong to the main invocation only.
            var f = flags.filter { $0 != "--routines" && $0 != "--events" }
            f.append("--where=\(transientWhere)")
            out.append(("Dump \(table) without transients", f + [database, table]))
        }
        return out
    }

    /// pg_dump invocations. One run covers "both", structure-only (`--exclude-table-data`) and skipped (`-T`)
    /// tables; data-only tables need a second `--data-only` run (the first run leaves them out with `-T`).
    static func postgresInvocations(database: String, options o: ExportOptions, connection: [String]) -> [[String]] {
        let modes = o.tableModes
        func members(_ m: TableExportMode) -> [String] {
            let names = modes.filter { $0.value == m }.map(\.key).sorted()
            guard let universe = o.tables else { return names }
            return names.filter(universe.contains)
        }
        let structure = members(.structureOnly), dataOnly = members(.dataOnly), skipped = members(.skip)
        // `-t`/`-T`/`--exclude-table-data` match patterns: quote both parts so case and punctuation are literal.
        func pattern(_ table: String) -> String {
            func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            return o.schema.map { quoted($0) + "." + quoted(table) } ?? table
        }
        var main = connection + ["--verbose", "--no-password"]
        if let schema = o.schema { main.append("--schema=" + "\"" + schema.replacingOccurrences(of: "\"", with: "\"\"") + "\"") }
        switch o.scope {
        case .structureOnly: main.append("--schema-only")
        case .dataOnly: main.append("--data-only")
        case .structureAndData: break
        }
        if o.addDropTable && o.scope != .dataOnly { main += ["--clean", "--if-exists"] }
        if !o.extendedInserts { main.append("--inserts") }
        let excluded = Set(skipped + dataOnly)
        if let tables = o.tables {
            for t in tables where !excluded.contains(t) { main += ["-t", pattern(t)] }
        }
        for t in excluded.sorted() { main += ["-T", pattern(t)] }
        if o.scope != .dataOnly, o.scope != .structureOnly { for t in structure { main.append("--exclude-table-data=\(pattern(t))") } }
        var runs: [[String]] = []
        let mainHasTables = o.tables.map { !$0.filter { !excluded.contains($0) }.isEmpty } ?? true
        if mainHasTables { runs.append(main + [database]) }
        if !dataOnly.isEmpty {
            var data = connection + ["--verbose", "--no-password", "--data-only"]
            if let schema = o.schema { data.append("--schema=" + "\"" + schema.replacingOccurrences(of: "\"", with: "\"\"") + "\"") }
            if !o.extendedInserts { data.append("--inserts") }
            for t in dataOnly { data += ["-t", pattern(t)] }
            runs.append(data + [database])
        }
        return runs
    }

    // MARK: Local

    private static func localPlan(target: ExportTarget, options o: ExportOptions, tool: ToolInfo, extraArguments: [String]) throws -> ExportPlan {
        let host = target.localEndpoint.host, port = String(target.localEndpoint.port)
        var steps: [CommandStep] = []
        switch target.engine {
        case .mysql, .mariadb:
            guard tool.flavour != .postgres else { throw ExportPlanError.toolRequired("\(tool.name) can't dump a \(target.engine.displayName) database.") }
            let cnf = "[client]\nuser=\(ShellQuoting.mysqlOptionValue(target.user))\npassword=\(ShellQuoting.mysqlOptionValue(target.password ?? ""))\n"
            let file = PlannedSecretFile(name: "client.cnf", contents: Data(cnf.utf8))
            let connection = ["--defaults-extra-file=\(DumpPlaceholders.secretDirectory)/client.cnf",
                              "--host=\(host)", "--port=\(port)", "--protocol=tcp"]
            for inv in mysqlInvocations(database: target.database, options: o) {
                steps.append(CommandStep(
                    label: inv.label, executable: tool.path,
                    arguments: [connection[0]] + connection.dropFirst() + extraArguments + inv.args,
                    environment: [:], standardInput: nil, secretFiles: [file], usesSSH: false))
            }
        case .postgresql:
            guard tool.flavour == .postgres else { throw ExportPlanError.toolRequired("\(tool.name) can't dump a PostgreSQL database.") }
            let runs = postgresInvocations(database: target.database, options: o,
                                           connection: ["--host=\(host)", "--port=\(port)", "--username=\(target.user)"])
            for (i, args) in runs.enumerated() {
                steps.append(CommandStep(
                    label: i == 0 ? "Dump \(target.database)" : "Dump \(target.database) data only", executable: tool.path,
                    arguments: args + extraArguments,
                    environment: target.password.map { ["PGPASSWORD": $0] } ?? [:], standardInput: nil, secretFiles: [], usesSSH: false))
            }
        }
        return ExportPlan(steps: steps, displayCommand: "", outputFilename: "", location: .localThroughTunnel, engine: target.engine,
                          remoteCompressed: false, outputCompressed: false, collation: nil, localStages: [], tables: nil,
                          ssh: nil, sshSecretKey: nil, warnings: [])
    }

    // MARK: Remote

    private static func remotePlan(target: ExportTarget, ssh: SSHTunnelConfig, options o: ExportOptions,
                                   sshOptions: SSHClientOptions, sshHasSecret: Bool) throws -> ExportPlan {
        let script = try remoteScript(target: target, options: o, redactPassword: false)
        var args = SSHCommandBuilder.baseArguments(for: ssh, options: sshOptions, hasSecret: sshHasSecret)
        args += ["-T", SSHCommandBuilder.destination(for: ssh), "sh -s"]
        let step = CommandStep(label: "Dump \(target.database) on \(ssh.host)", executable: sshOptions.sshExecutable,
                               arguments: args, environment: [:], standardInput: Data(script.utf8), secretFiles: [], usesSSH: true)
        return ExportPlan(steps: [step], displayCommand: "", outputFilename: "", location: .remoteOverSSH, engine: target.engine,
                          remoteCompressed: false, outputCompressed: false, collation: nil, localStages: [], tables: nil,
                          ssh: ssh, sshSecretKey: target.sshSecretKey, warnings: [])
    }

    /// The POSIX-sh script executed on the server (sent on stdin). Public so the UI can show it and tests can run it.
    public static func remoteScript(target: ExportTarget, options o: ExportOptions, redactPassword: Bool) throws -> String {
        let delim = "QW_EOF_" + stableToken(target)
        let password = target.password ?? ""
        let shownPassword = redactPassword ? "****" : password
        var s = ""
        s += "umask 077\n"
        s += "QW_T=$(mktemp -d \"${TMPDIR:-/tmp}/qw-export.XXXXXXXX\") || { echo 'qw: cannot create a temporary directory' >&2; exit 70; }\n"
        s += "trap 'rm -rf \"$QW_T\"' EXIT\n"
        s += "trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM\n"
        let gz = o.gzip ? " | gzip -c" : ""

        switch target.engine {
        case .mysql, .mariadb:
            let cnf = "[client]\nuser=\(ShellQuoting.mysqlOptionValue(target.user))\npassword=\(ShellQuoting.mysqlOptionValue(shownPassword))\n"
            s += "cat > \"$QW_T/client.cnf\" <<'\(delim)'\n\(cnf)\(delim)\n"
            s += "if command -v mysqldump >/dev/null 2>&1; then QW_D=mysqldump\n"
            s += "elif command -v mariadb-dump >/dev/null 2>&1; then QW_D=mariadb-dump\n"
            s += "else echo 'qw: mysqldump was not found on the server' >&2; exit 127; fi\n"
            s += "QW_H=$(\"$QW_D\" --help 2>&1 </dev/null); QW_X=\n"
            s += "case \"$QW_H\" in *--no-tablespaces*) QW_X=\"$QW_X --no-tablespaces\";; esac\n"
            s += "case \"$QW_H\" in *--column-statistics*) QW_X=\"$QW_X --column-statistics=0\";; esac\n"
            s += "case \"$QW_H\" in *--set-gtid-purged*) QW_X=\"$QW_X --set-gtid-purged=OFF\";; esac\n"
            let conn = ShellQuoting.posix(["--host=\(target.remoteEndpoint.host)", "--port=\(target.remoteEndpoint.port)", "--protocol=tcp"])
            s += "qw_dump() { \"$QW_D\" --defaults-extra-file=\"$QW_T/client.cnf\" \(conn) $QW_X \"$@\" </dev/null; }\n"
            let calls = mysqlInvocations(database: target.database, options: o)
                .map { "qw_dump " + ShellQuoting.posix($0.args) }
            s += "( ( \(calls.joined(separator: " && ")) ); echo $? > \"$QW_T/rc\" )\(gz)\n"
        case .postgresql:
            if password.contains("\n") || password.contains("\r") {
                throw ExportPlanError.passwordNotRepresentable("PostgreSQL password files can't hold a password containing a line break. Export locally or change the password.")
            }
            let user = ShellQuoting.pgpassField(target.user)
            let line = "*:*:*:\(user):\(ShellQuoting.pgpassField(shownPassword))\n"
            s += "cat > \"$QW_T/pgpass\" <<'\(delim)'\n\(line)\(delim)\n"
            s += "PGPASSFILE=\"$QW_T/pgpass\"; export PGPASSFILE\n"
            s += "command -v pg_dump >/dev/null 2>&1 || { echo 'qw: pg_dump was not found on the server' >&2; exit 127; }\n"
            let runs = postgresInvocations(
                database: target.database, options: o,
                connection: ["--host=\(target.remoteEndpoint.host)", "--port=\(target.remoteEndpoint.port)", "--username=\(target.user)"])
            let calls = runs.map { "pg_dump \(ShellQuoting.posix($0)) </dev/null" }
            s += "( ( \(calls.joined(separator: " && ")) ); echo $? > \"$QW_T/rc\" )\(gz)\n"
        }
        // The pipeline status is gzip's; the dump tool's status is in rc.
        s += o.gzip ? "QW_G=$?\n" : "QW_G=0\n"
        s += "QW_S=$(cat \"$QW_T/rc\" 2>/dev/null || echo 1)\n"
        s += "[ \"$QW_S\" = 0 ] || exit \"$QW_S\"\n"
        s += "exit \"$QW_G\"\n"
        return s
    }

    /// Unguessable-enough here-doc delimiter suffix derived from the password so it can't occur in the body.
    private static func stableToken(_ t: ExportTarget) -> String {
        var h: UInt64 = 1469598103934665603
        for b in (t.user + "\u{0}" + (t.password ?? "") + "\u{0}" + t.database).utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16, uppercase: true)
    }

    // MARK: Display

    private static func display(plan: ExportPlan, target: ExportTarget, options o: ExportOptions) throws -> String {
        let stageText = plan.localStages.map { stage -> String in
            switch stage {
            case "gunzip": "gunzip -c"
            case "gzip": "gzip -c"
            default: "<Querywell collation rewrite>"
            }
        }
        let tail = stageText.map { " | " + $0 }.joined() + " > " + ShellQuoting.posix(plan.outputFilename)
        var lines: [String] = []
        switch plan.location {
        case .remoteOverSSH:
            guard let step = plan.steps.first else { return "" }
            let script = try remoteScript(target: target, options: o, redactPassword: true)
            lines.append("# The script is sent on ssh's stdin, so the database password never appears in the server's process list.")
            if !stageText.isEmpty {
                lines.append("# Local stages after the download: " + plan.localStages.joined(separator: " → ") + ".")
            }
            lines.append("ssh \(ShellQuoting.posix(Array(step.arguments.dropLast()))) sh -s <<'QW_SCRIPT'" + tail)
            lines.append(script.trimmingCharacters(in: .newlines))
            lines.append("QW_SCRIPT")
        case .localThroughTunnel:
            var commands: [String] = []
            for step in plan.steps {
                var parts: [String] = []
                for arg in [step.executable] + step.arguments {
                    if arg.hasPrefix("--defaults-extra-file=") {
                        parts.append("--defaults-extra-file=\"$QW_DIR/client.cnf\"")
                    } else {
                        parts.append(ShellQuoting.posix(arg))
                    }
                }
                var cmd = parts.joined(separator: " ")
                if step.environment["PGPASSWORD"] != nil { cmd = "PGPASSWORD=**** " + cmd }
                commands.append(cmd)
            }
            if plan.steps.contains(where: { !$0.secretFiles.isEmpty }) {
                lines.append("QW_DIR=$(mktemp -d) && umask 077")
                lines.append("printf '%s\\n' '[client]' \(ShellQuoting.posix("user=" + ShellQuoting.mysqlOptionValue(target.user))) 'password=\"****\"' > \"$QW_DIR/client.cnf\"")
            }
            let body = commands.count == 1 ? commands[0] : "{ " + commands.joined(separator: "; ") + "; }"
            lines.append(body + tail)
            if plan.steps.contains(where: { !$0.secretFiles.isEmpty }) { lines.append("rm -rf \"$QW_DIR\"") }
        }
        return lines.joined(separator: "\n")
    }
}
