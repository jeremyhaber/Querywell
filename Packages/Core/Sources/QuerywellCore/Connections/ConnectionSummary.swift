import Foundation

/// Display strings for a connection, used by launcher cards and window headers.
public struct ConnectionSummary: Sendable, Hashable {
    /// The profile's name.
    public var title: String
    /// "MySQL", or "MySQL 8.4" / "MariaDB 11.4" when the server's version is known.
    public var engineLabel: String
    /// "host:port", or "sshHost · dbHost:port" when tunnelled. IPv6 hosts are bracketed.
    public var endpointLabel: String
    /// How the connection authenticates: "SSH key", "SSH agent", "1Password agent",
    /// "SSH password", "Password + TLS", "Password" or "Direct".
    public var accessLabel: String
    /// When the profile was last opened, if ever.
    public var lastUsedAt: Date?

    /// Builds the summary; pass `serverInfo` once a connection has been made to show the version.
    public init(profile: ConnectionProfile, serverInfo: ServerInfo? = nil) {
        title = profile.name
        engineLabel = serverInfo?.shortDescription ?? profile.engine.displayName
        endpointLabel = Self.endpoint(profile)
        accessLabel = Self.access(profile)
        lastUsedAt = profile.lastUsedAt
    }

    /// "Just now", "2 min ago", "3 hr ago", "Yesterday", "3 days ago", "Last week",
    /// "Oct 23" (with the year when it is not `now`'s year), or "Never".
    ///
    /// Day boundaries use `calendar` (and its time zone); text uses `locale`.
    public func lastUsedLabel(
        relativeTo now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        guard let date = lastUsedAt else { return "Never" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }  // includes dates slightly in the future
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "\(Int(seconds / 3600)) hr ago"
        case 1: return "Yesterday"
        case 2...6: return "\(days) days ago"
        case 7...13: return "Last week"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "MMMdy")
            return formatter.string(from: date)
        }
    }

    // MARK: Helpers

    private static func hostPort(_ host: String, _ port: Int) -> String {
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(h):\(port)"
    }

    private static func endpoint(_ p: ConnectionProfile) -> String {
        let direct = hostPort(p.host, p.port)
        guard let ssh = p.ssh else { return direct }
        let jump = ssh.port == 22 ? ssh.host : "\(ssh.host):\(ssh.port)"
        return "\(jump) · \(direct)"
    }

    private static func isOnePassword(_ socket: String?) -> Bool {
        guard let socket else { return false }
        return socket == SSHAuthMethod.onePasswordAgentSocketPath
            || socket.contains("2BUA8C4S2C.com.1password")
    }

    private static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "localhost" || h == "::1" || h == "[::1]" || h.hasPrefix("127.")
    }

    private static func access(_ p: ConnectionProfile) -> String {
        if let ssh = p.ssh {
            switch ssh.auth {
            case .keyFile: return "SSH key"
            case .agent(let socket): return isOnePassword(socket) ? "1Password agent" : "SSH agent"
            case .password: return "SSH password"
            }
        }
        switch p.tls.mode {
        case .required, .verifyCA, .verifyIdentity: return "Password + TLS"
        case .disabled, .preferred: return isLoopback(p.host) ? "Direct" : "Password"
        }
    }
}
