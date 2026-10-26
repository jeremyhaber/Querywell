import Foundation
import NIOCore
import NIOSSL

/// Engine-independent translation of a ``TLSConfig`` into a concrete TLS plan and a
/// NIOSSL configuration. The plan is separate from the configuration so the mode mapping
/// is unit-testable without touching the filesystem.
enum TLSSupport {
    /// What the driver should do about TLS for one connection.
    struct Plan: Sendable, Equatable {
        enum Verification: Sendable, Equatable {
            /// Encrypt only; accept any certificate (libpq `sslmode=require/prefer`).
            case none
            /// Validate the chain against the CA, skip the hostname check (`verify-ca`).
            case chainOnly
            /// Validate the chain and the hostname (`verify-full`).
            case full
        }

        /// Attempt TLS at all.
        var enabled: Bool
        /// Fail the connection if TLS can't be established (otherwise fall back to plaintext).
        var enforced: Bool
        var verification: Verification
    }

    static func plan(for mode: TLSMode) -> Plan {
        switch mode {
        case .disabled: Plan(enabled: false, enforced: false, verification: .none)
        case .preferred: Plan(enabled: true, enforced: false, verification: .none)
        case .required: Plan(enabled: true, enforced: true, verification: .none)
        case .verifyCA: Plan(enabled: true, enforced: true, verification: .chainOnly)
        case .verifyIdentity: Plan(enabled: true, enforced: true, verification: .full)
        }
    }

    /// Builds the NIOSSL client configuration, or `nil` when TLS is disabled.
    static func clientConfiguration(for config: TLSConfig) throws -> TLSConfiguration? {
        let plan = plan(for: config.mode)
        guard plan.enabled else { return nil }

        var tls = TLSConfiguration.makeClientConfiguration()
        switch plan.verification {
        case .none: tls.certificateVerification = .none
        case .chainOnly: tls.certificateVerification = .noHostnameVerification
        case .full: tls.certificateVerification = .fullVerification
        }

        if let ca = nonEmpty(config.caCertificatePath) {
            do {
                tls.trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(ca))
            } catch {
                throw DatabaseError.tlsFailed("Could not read the CA certificate at \(ca): \(error)")
            }
        }
        if let cert = nonEmpty(config.clientCertificatePath) {
            do {
                tls.certificateChain = try NIOSSLCertificate.fromPEMFile(cert).map { .certificate($0) }
            } catch {
                throw DatabaseError.tlsFailed("Could not read the client certificate at \(cert): \(error)")
            }
        }
        if let key = nonEmpty(config.clientKeyPath) {
            do {
                tls.privateKey = .privateKey(try NIOSSLPrivateKey(file: key, format: .pem))
            } catch {
                throw DatabaseError.tlsFailed("Could not read the client key at \(key): \(error)")
            }
        }
        return tls
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
