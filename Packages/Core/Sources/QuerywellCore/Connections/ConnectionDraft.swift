import Foundation

/// How the draft authenticates to the SSH host.
public enum SSHAuthChoice: String, Sendable, Hashable, CaseIterable {
    case keyFile
    case agent
    case password
}

/// Thrown by ``ConnectionDraft/makeProfile()`` when the draft is not valid.
public struct ConnectionDraftError: Error, Equatable, Sendable {
    public var issues: [ValidationIssue]
}

/// Editable form state of the connection editor: profile fields as typed text, plus the
/// secrets the user entered. Validate, then build a ``ConnectionProfile`` and persist the
/// secrets from ``secretsToSave()``.
public struct ConnectionDraft: Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var folderID: UUID?
    public var colorTag: ColorTag?
    /// Changing the engine moves ``portText`` to the new engine's default port, but only if
    /// the port still equals the previous engine's default.
    public var engine: DatabaseEngine {
        didSet {
            guard engine != oldValue else { return }
            if portText.trimmingCharacters(in: .whitespaces) == String(oldValue.defaultPort) {
                portText = String(engine.defaultPort)
            }
        }
    }
    public var host: String
    public var portText: String
    public var user: String
    /// Empty means no default database.
    public var defaultDatabase: String
    public var tls: TLSConfig
    public var readOnly: Bool
    public var favourite: Bool
    /// Empty means no notes.
    public var notes: String
    /// Preserved from the original profile so saving does not reset history.
    public var createdAt: Date
    public var lastUsedAt: Date?

    public var useSSH: Bool
    public var sshHost: String
    public var sshPortText: String
    public var sshUser: String
    public var sshAuth: SSHAuthChoice
    /// Used when ``sshAuth`` is `.keyFile`.
    public var sshKeyPath: String
    /// Used when ``sshAuth`` is `.agent`; empty means `SSH_AUTH_SOCK`.
    public var sshAgentSocketPath: String

    /// The database password as typed. Empty means "no password" (the stored one is deleted).
    public var databasePassword: String
    /// SSH password (`.password`) or key passphrase (`.keyFile`). Empty means none.
    public var sshSecret: String

    /// A blank draft for a new connection to `engine`.
    public init(newFor engine: DatabaseEngine) {
        id = UUID()
        name = ""
        folderID = nil
        colorTag = nil
        self.engine = engine
        host = "127.0.0.1"
        portText = String(engine.defaultPort)
        user = ""
        defaultDatabase = ""
        tls = TLSConfig()
        readOnly = false
        favourite = false
        notes = ""
        createdAt = Date()
        lastUsedAt = nil
        useSSH = false
        sshHost = ""
        sshPortText = "22"
        sshUser = ""
        sshAuth = .agent
        sshKeyPath = ""
        sshAgentSocketPath = ""
        databasePassword = ""
        sshSecret = ""
    }

    /// A draft that edits `profile`, pre-filled with its stored `secrets`.
    public init(profile: ConnectionProfile, secrets: ConnectionSecrets = ConnectionSecrets()) {
        id = profile.id
        name = profile.name
        folderID = profile.folderID
        colorTag = profile.colorTag
        engine = profile.engine
        host = profile.host
        portText = String(profile.port)
        user = profile.user
        defaultDatabase = profile.defaultDatabase ?? ""
        tls = profile.tls
        readOnly = profile.readOnly
        favourite = profile.favourite
        notes = profile.notes ?? ""
        createdAt = profile.createdAt
        lastUsedAt = profile.lastUsedAt
        databasePassword = secrets.databasePassword ?? ""
        sshSecret = secrets.sshSecret ?? ""

        useSSH = profile.ssh != nil
        sshHost = profile.ssh?.host ?? ""
        sshPortText = String(profile.ssh?.port ?? 22)
        sshUser = profile.ssh?.user ?? ""
        sshAuth = .agent
        sshKeyPath = ""
        sshAgentSocketPath = ""
        switch profile.ssh?.auth {
        case .keyFile(let path)?: sshAuth = .keyFile; sshKeyPath = path
        case .agent(let socket)?: sshAuth = .agent; sshAgentSocketPath = socket ?? ""
        case .password?: sshAuth = .password
        case nil: break
        }
    }

    // MARK: Validation & building

    /// All problems with the draft, in stable order. Unparseable port text is reported as
    /// ``ValidationIssue/invalidPort`` / ``ValidationIssue/sshInvalidPort``.
    public func validate() -> [ValidationIssue] {
        ConnectionValidator.validate(profileForValidation)
    }

    /// Builds the profile.
    /// - Throws: ``ConnectionDraftError`` carrying the issues when ``validate()`` is non-empty.
    public func makeProfile() throws -> ConnectionProfile {
        let issues = validate()
        guard issues.isEmpty else { throw ConnectionDraftError(issues: issues) }
        return profileForValidation
    }

    /// Port 0 stands in for unparseable text so the validator flags it.
    private var profileForValidation: ConnectionProfile {
        ConnectionProfile(
            id: id,
            name: trimmed(name),
            folderID: folderID,
            colorTag: colorTag,
            engine: engine,
            host: trimmed(host),
            port: Self.parsePort(portText) ?? 0,
            user: trimmed(user),
            defaultDatabase: nilIfBlank(defaultDatabase),
            ssh: useSSH ? sshConfig : nil,
            tls: tls,
            readOnly: readOnly,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            notes: nilIfBlank(notes),
            favourite: favourite)
    }

    private var sshConfig: SSHTunnelConfig {
        let auth: SSHAuthMethod
        switch sshAuth {
        case .keyFile: auth = .keyFile(path: trimmed(sshKeyPath))
        case .agent: auth = .agent(socketPath: nilIfBlank(sshAgentSocketPath))
        case .password: auth = .password
        }
        return SSHTunnelConfig(
            host: trimmed(sshHost), port: Self.parsePort(sshPortText) ?? 0, user: trimmed(sshUser), auth: auth)
    }

    private static func parsePort(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 6, t.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(t)
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func nilIfBlank(_ s: String) -> String? { trimmed(s).isEmpty ? nil : trimmed(s) }

    // MARK: Secrets

    /// The secret changes to apply when saving: always exactly three entries, in order
    /// database password, SSH password, SSH key passphrase. `nil` means delete.
    ///
    /// - An empty field is deleted.
    /// - The SSH password is kept only for password auth, the passphrase only for key-file
    ///   auth; switching method (or turning SSH off) deletes the stale one.
    public func secretsToSave() -> [(SecretKey, String?)] {
        let owner = id.uuidString
        func value(_ s: String, keep: Bool) -> String? { keep && !s.isEmpty ? s : nil }
        let ssh = useSSH
        return [
            (SecretKey(ownerID: owner, kind: .databasePassword), value(databasePassword, keep: true)),
            (SecretKey(ownerID: owner, kind: .sshPassword), value(sshSecret, keep: ssh && sshAuth == .password)),
            (SecretKey(ownerID: owner, kind: .sshKeyPassphrase), value(sshSecret, keep: ssh && sshAuth == .keyFile)),
        ]
    }

    /// Secrets to overlay for ``ConnectionTester/test(_:secrets:progress:)``. Empty fields
    /// are `nil` (fall back to the store; a never-saved draft has nothing stored). The SSH
    /// secret is `nil` unless SSH is on with password or key-file auth.
    public var testSecrets: ConnectionSecrets {
        ConnectionSecrets(
            databasePassword: databasePassword.isEmpty ? nil : databasePassword,
            sshSecret: (useSSH && sshAuth != .agent && !sshSecret.isEmpty) ? sshSecret : nil)
    }
}
