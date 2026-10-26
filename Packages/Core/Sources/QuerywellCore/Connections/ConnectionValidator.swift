import Foundation

/// A problem found while validating a ``ConnectionProfile``.
public enum ValidationIssue: Sendable, Hashable {
    case emptyName
    case emptyHost
    case invalidPort
    case emptyUser
    case sshEmptyHost
    case sshInvalidPort
    case sshEmptyUser
    case sshKeyFileEmpty
    case tlsMissingCA

    /// A user-presentable explanation.
    public var message: String {
        switch self {
        case .emptyName: "Enter a name for this connection."
        case .emptyHost: "Enter a host."
        case .invalidPort: "The port must be between 1 and 65535."
        case .emptyUser: "Enter a user name."
        case .sshEmptyHost: "Enter the SSH host."
        case .sshInvalidPort: "The SSH port must be between 1 and 65535."
        case .sshEmptyUser: "Enter the SSH user name."
        case .sshKeyFileEmpty: "Choose an SSH private key file."
        case .tlsMissingCA: "Verifying the server certificate requires a CA certificate file."
        }
    }
}

/// Validates connection profiles before they are saved or used.
public enum ConnectionValidator {
    private static let validPorts = 1...65535

    /// Returns all issues found, in a stable order; empty means the profile is valid.
    public static func validate(_ profile: ConnectionProfile) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if isBlank(profile.name) { issues.append(.emptyName) }
        if isBlank(profile.host) { issues.append(.emptyHost) }
        if !validPorts.contains(profile.port) { issues.append(.invalidPort) }
        if isBlank(profile.user) { issues.append(.emptyUser) }

        if let ssh = profile.ssh {
            if isBlank(ssh.host) { issues.append(.sshEmptyHost) }
            if !validPorts.contains(ssh.port) { issues.append(.sshInvalidPort) }
            if isBlank(ssh.user) { issues.append(.sshEmptyUser) }
            if case .keyFile(let path) = ssh.auth, isBlank(path) { issues.append(.sshKeyFileEmpty) }
        }

        switch profile.tls.mode {
        case .verifyCA, .verifyIdentity:
            if isBlank(profile.tls.caCertificatePath ?? "") { issues.append(.tlsMissingCA) }
        case .disabled, .preferred, .required:
            break
        }
        return issues
    }

    private static func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
