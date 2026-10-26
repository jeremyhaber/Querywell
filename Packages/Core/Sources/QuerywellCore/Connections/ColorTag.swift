import Foundation

/// A color label on a connection, used to make dangerous targets (production) obvious.
public enum ColorTag: Codable, Sendable, Hashable {
    case production
    case staging
    case local
    case custom(name: String, hex: String)

    /// `true` only for ``production``.
    public var isProduction: Bool {
        if case .production = self { return true }
        return false
    }

    /// The built-in tags offered as presets, in display order.
    public static let presets: [ColorTag] = [.production, .staging, .local]

    /// The kind of tag, ignoring any custom name/color.
    public var kind: ColorTagKind {
        switch self {
        case .production: .production
        case .staging: .staging
        case .local: .local
        case .custom: .custom
        }
    }

    /// Short uppercase badge text: "PROD", "STAGING", "LOCAL", or the custom name
    /// uppercased and truncated to 8 characters.
    public var shortLabel: String {
        switch self {
        case .production: "PROD"
        case .staging: "STAGING"
        case .local: "LOCAL"
        case .custom(let name, _):
            String(name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().prefix(8))
        }
    }

    /// Human-readable name, e.g. "Production" or the custom tag's name.
    public var displayName: String {
        switch self {
        case .production: "Production"
        case .staging: "Staging"
        case .local: "Local"
        case .custom(let name, _): name
        }
    }

    /// Hex color (`#RRGGBB`) to render for this tag (design palette).
    public var defaultHex: String {
        switch self {
        case .production: "#C4314B"
        case .staging: "#E0A030"
        case .local: "#2E9E5B"
        case .custom(_, let hex): hex
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, name, hex }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "production": self = .production
        case "staging": self = .staging
        case "local": self = .local
        case "custom":
            self = .custom(name: try c.decode(String.self, forKey: .name),
                           hex: try c.decode(String.self, forKey: .hex))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "Unknown ColorTag kind '\(other)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .production: try c.encode("production", forKey: .kind)
        case .staging: try c.encode("staging", forKey: .kind)
        case .local: try c.encode("local", forKey: .kind)
        case .custom(let name, let hex):
            try c.encode("custom", forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(hex, forKey: .hex)
        }
    }
}

/// The category of a ``ColorTag`` without its custom payload; used for filtering.
public enum ColorTagKind: String, Codable, Sendable, Hashable, CaseIterable {
    case production
    case staging
    case local
    case custom
}
