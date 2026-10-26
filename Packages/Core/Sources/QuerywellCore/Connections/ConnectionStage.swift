import Foundation

/// Progress milestones while opening a connection, in the order they occur.
public enum ConnectionStage: Sendable, Hashable {
    case validating
    case readingSecrets
    /// Only reported when the profile uses SSH. `host` is the SSH host.
    case openingTunnel(host: String)
    case connecting(host: String, port: Int)
    case connected

    /// Short phrase for a progress UI.
    public var title: String {
        switch self {
        case .validating: "Validating settings"
        case .readingSecrets: "Reading saved passwords"
        case .openingTunnel(let host): "Opening SSH tunnel to \(host)"
        case .connecting(let host, let port): "Connecting to \(host):\(port)"
        case .connected: "Connected"
        }
    }
}
