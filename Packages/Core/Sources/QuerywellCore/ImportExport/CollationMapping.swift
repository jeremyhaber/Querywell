import Foundation

public enum CollationNameKind: String, Hashable, Sendable {
    case charset
    case collation
}

/// Data-driven charset / collation mapping used by ``CollationRewriter``.
///
/// Lookups are case-insensitive; mapped names are returned lower-case. Resolution order for a name:
/// forced override (``custom(charset:collation:)``) → exact table → ordered pattern rules. A `nil`
/// result means "leave as is" (unknown name, or already the target).
public struct CollationMapping: Equatable, Sendable {
    public struct Rule: Equatable, Sendable {
        public enum Action: Equatable, Sendable {
            /// Replace the whole name.
            case replace(String)
            /// Replace the matched `prefix` with this text, keeping the rest (`utf8mb3_general_ci` → `utf8_general_ci`).
            case swapPrefix(String)
        }

        public var prefix: String?
        public var contains: String?
        public var suffix: String?
        public var action: Action

        public init(prefix: String? = nil, contains: String? = nil, suffix: String? = nil, action: Action) {
            self.prefix = prefix
            self.contains = contains
            self.suffix = suffix
            self.action = action
        }

        func apply(to name: String) -> String? {
            if let p = prefix, !name.hasPrefix(p) { return nil }
            if let c = contains, !name.contains(c) { return nil }
            if let s = suffix, !name.hasSuffix(s) { return nil }
            switch action {
            case .replace(let r): return r
            case .swapPrefix(let r): return r + name.dropFirst(prefix?.count ?? 0)
            }
        }
    }

    public var charsets: [String: String]
    public var collations: [String: String]
    public var charsetRules: [Rule]
    public var collationRules: [Rule]
    /// When set, every charset (except `binary`) becomes this one.
    public var forcedCharset: String?
    /// When set, every collation becomes this one (see `preserveBinary`).
    public var forcedCollation: String?
    /// With a forced charset, `*_bin` collations become `<forcedCharset>_bin` instead of being
    /// flattened to the forced (case-insensitive) collation, which would change comparison semantics.
    public var preserveBinary: Bool

    public init(charsets: [String: String] = [:], collations: [String: String] = [:],
                charsetRules: [Rule] = [], collationRules: [Rule] = [],
                forcedCharset: String? = nil, forcedCollation: String? = nil, preserveBinary: Bool = true) {
        self.charsets = charsets
        self.collations = collations
        self.charsetRules = charsetRules
        self.collationRules = collationRules
        self.forcedCharset = forcedCharset?.lowercased()
        self.forcedCollation = forcedCollation?.lowercased()
        self.preserveBinary = preserveBinary
    }

    static let neverRewritten: Set<String> = ["binary", "default", "null"]

    public func mapCharset(_ name: String) -> String? {
        let l = name.lowercased()
        if Self.neverRewritten.contains(l) { return nil }
        var result: String?
        if let f = forcedCharset {
            result = f
        } else if let e = charsets[l] {
            result = e
        } else {
            for r in charsetRules { if let m = r.apply(to: l) { result = m; break } }
        }
        guard let r = result, r != l else { return nil }
        return r
    }

    public func mapCollation(_ name: String) -> String? {
        let l = name.lowercased()
        if Self.neverRewritten.contains(l) { return nil }
        var result: String?
        if let f = forcedCollation {
            if preserveBinary, l.hasSuffix("_bin"), let cs = forcedCharset {
                result = cs + "_bin"
            } else {
                result = f
            }
        } else if let e = collations[l] {
            result = e
        } else {
            for r in collationRules { if let m = r.apply(to: l) { result = m; break } }
        }
        guard let r = result, r != l else { return nil }
        return r
    }

    // MARK: Presets

    /// Leaves everything alone.
    public static let identity = CollationMapping()

    /// For importing MySQL 8 / MariaDB 11 dumps into MySQL 5.7, older MariaDB and most shared hosts.
    ///
    /// - `utf8mb4_0900_ai_ci` / `_as_ci` → `utf8mb4_unicode_520_ci` (closest UCA 5.2 collation; `_as_ci`
    ///   loses accent sensitivity — there is no exact equivalent).
    /// - `utf8mb4_0900_as_cs` (incl. language variants) and `utf8mb4_0900_bin` → `utf8mb4_bin`.
    /// - MariaDB 11.3+ `uca1400` collations → the same targets.
    /// - `utf8mb3` / `utf8mb3_*` → `utf8` / `utf8_*` (decided: `utf8` is the alias understood by
    ///   MySQL 5.x and every MariaDB, and means the same 3-byte charset).
    public static let mysql57MariaDBCompatible = CollationMapping(
        charsets: ["utf8mb3": "utf8"],
        collations: [
            "utf8mb4_0900_ai_ci": "utf8mb4_unicode_520_ci",
            "utf8mb4_0900_as_ci": "utf8mb4_unicode_520_ci",
            "utf8mb4_0900_as_cs": "utf8mb4_bin",
            "utf8mb4_0900_bin": "utf8mb4_bin",
            "utf8mb4_nopad_bin": "utf8mb4_bin",
            "utf8mb3_nopad_bin": "utf8_bin",
        ],
        collationRules: [
            Rule(prefix: "utf8mb4_", contains: "_0900_", suffix: "_bin", action: .replace("utf8mb4_bin")),
            Rule(prefix: "utf8mb4_", contains: "_0900_as_cs", action: .replace("utf8mb4_bin")),
            Rule(prefix: "utf8mb4_", contains: "_0900_", action: .replace("utf8mb4_unicode_520_ci")),
            Rule(prefix: "utf8mb4_", contains: "_uca1400_", suffix: "_cs", action: .replace("utf8mb4_bin")),
            Rule(prefix: "utf8mb4_", contains: "_uca1400_", action: .replace("utf8mb4_unicode_520_ci")),
            Rule(prefix: "utf8mb3_", contains: "_uca1400_", suffix: "_cs", action: .replace("utf8_bin")),
            Rule(prefix: "utf8mb3_", contains: "_uca1400_", action: .replace("utf8_unicode_520_ci")),
            Rule(prefix: "utf8mb3_", action: .swapPrefix("utf8_")),
        ]
    )

    /// Lowest common denominator: everything Unicode-ish and case-insensitive becomes
    /// `utf8mb4_unicode_ci` (also `utf8mb4_unicode_520_ci`, for servers older than 5.6); binary and
    /// case-sensitive collations become `utf8mb4_bin`; `utf8mb3` becomes `utf8`.
    public static let legacyUnicodeCI = CollationMapping(
        charsets: ["utf8mb3": "utf8"],
        collations: [
            "utf8mb4_0900_ai_ci": "utf8mb4_unicode_ci",
            "utf8mb4_0900_as_ci": "utf8mb4_unicode_ci",
            "utf8mb4_0900_as_cs": "utf8mb4_bin",
            "utf8mb4_0900_bin": "utf8mb4_bin",
            "utf8mb4_unicode_520_ci": "utf8mb4_unicode_ci",
            "utf8mb3_unicode_520_ci": "utf8_unicode_ci",
            "utf8_unicode_520_ci": "utf8_unicode_ci",
            "utf8mb4_nopad_bin": "utf8mb4_bin",
            "utf8mb3_nopad_bin": "utf8_bin",
        ],
        collationRules: [
            Rule(prefix: "utf8mb4_", contains: "_0900_", suffix: "_bin", action: .replace("utf8mb4_bin")),
            Rule(prefix: "utf8mb4_", contains: "_0900_as_cs", action: .replace("utf8mb4_bin")),
            Rule(prefix: "utf8mb4_", contains: "_0900_", action: .replace("utf8mb4_unicode_ci")),
            Rule(prefix: "utf8mb4_", contains: "_uca1400_", suffix: "_cs", action: .replace("utf8mb4_bin")),
            Rule(prefix: "utf8mb4_", contains: "_uca1400_", action: .replace("utf8mb4_unicode_ci")),
            Rule(prefix: "utf8mb3_", contains: "_uca1400_", suffix: "_cs", action: .replace("utf8_bin")),
            Rule(prefix: "utf8mb3_", contains: "_uca1400_", action: .replace("utf8_unicode_ci")),
            Rule(prefix: "utf8mb3_", action: .swapPrefix("utf8_")),
        ]
    )

    /// Forces every charset and collation to the given pair (`binary` charset and `*_bin` collations
    /// are handled as described on `preserveBinary`).
    ///
    /// **Warning:** this only rewrites DDL. Row data in the dump is never transcoded, so forcing a
    /// different charset is safe only when the data is compatible (for example pure ASCII or already UTF-8).
    public static func custom(charset: String, collation: String) -> CollationMapping {
        CollationMapping(forcedCharset: charset, forcedCollation: collation)
    }
}
