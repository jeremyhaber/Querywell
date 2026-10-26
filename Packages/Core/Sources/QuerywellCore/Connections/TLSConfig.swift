import Foundation

/// TLS negotiation policy for a database connection.
public enum TLSMode: String, Codable, Sendable, CaseIterable {
    case disabled
    case preferred
    case required
    case verifyCA
    case verifyIdentity
}

/// TLS settings. Paths only; no key material is stored here.
public struct TLSConfig: Codable, Sendable, Hashable {
    public var mode: TLSMode
    public var caCertificatePath: String?
    public var clientCertificatePath: String?
    public var clientKeyPath: String?

    public init(
        mode: TLSMode = .preferred,
        caCertificatePath: String? = nil,
        clientCertificatePath: String? = nil,
        clientKeyPath: String? = nil
    ) {
        self.mode = mode
        self.caCertificatePath = caCertificatePath
        self.clientCertificatePath = clientCertificatePath
        self.clientKeyPath = clientKeyPath
    }

    private enum CodingKeys: String, CodingKey {
        case mode, caCertificatePath, clientCertificatePath, clientKeyPath
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(TLSMode.self, forKey: .mode) ?? .preferred
        caCertificatePath = try c.decodeIfPresent(String.self, forKey: .caCertificatePath)
        clientCertificatePath = try c.decodeIfPresent(String.self, forKey: .clientCertificatePath)
        clientKeyPath = try c.decodeIfPresent(String.self, forKey: .clientKeyPath)
    }
}
