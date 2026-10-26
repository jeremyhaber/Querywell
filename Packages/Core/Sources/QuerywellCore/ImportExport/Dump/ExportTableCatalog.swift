import Foundation

// Making a long table list manageable for the export dialog: automatic grouping by name prefix (no list of
// plugins needed), generic "usually not needed" suggestions, and presets that bulk-set modes.

/// One cluster of tables in the export list.
public struct TableGroup: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable { case core, cluster, other }

    public var kind: Kind
    /// A glob that matches exactly this cluster's naming (`wp_wf*`, `wp_actionscheduler_*`); nil for core / other.
    public var pattern: String?
    /// Friendly plugin name when the catalog knows the stem ("Wordfence"); otherwise nil.
    public var friendlyName: String?
    public var tables: [String]

    public var id: String {
        switch kind {
        case .core: "core"
        case .other: "other"
        case .cluster: pattern ?? tables.first ?? "cluster"
        }
    }

    /// "WordPress core", "Wordfence · wp_wf*", "wp_acmeplugin_*", "Other tables".
    public var title: String {
        switch kind {
        case .core: "WordPress core"
        case .other: "Other tables"
        case .cluster: [friendlyName, pattern].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

public struct TableSuggestion: Equatable, Sendable {
    public var mode: TableExportMode
    public var reason: String
}

public enum ExportTableCatalog {
    // MARK: Prefix

    /// The WordPress table prefix (`wp_`): the shortest `p` for which both `p`options and `p`posts exist.
    public static func detectPrefix(in names: [String]) -> String? {
        let set = Set(names)
        let candidates = names.filter { $0.hasSuffix("options") }.map { String($0.dropLast("options".count)) }
            .filter { set.contains($0 + "posts") }
        return candidates.min { $0.count < $1.count }
    }

    public static let coreSuffixes: Set<String> = [
        "posts", "postmeta", "options", "users", "usermeta", "terms", "termmeta", "term_taxonomy", "term_relationships",
        "comments", "commentmeta", "links",
        // multisite
        "blogs", "blogmeta", "site", "sitemeta", "blog_versions", "registration_log", "signups",
    ]

    /// Whether `name` is a WordPress core table under `prefix` (including `wp_2_posts`-style sub-site tables).
    public static func isCore(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        var rest = String(name.dropFirst(prefix.count))
        if coreSuffixes.contains(rest) { return true }
        // Multisite: <prefix><blog id>_<core table>
        if let underscore = rest.firstIndex(of: "_"), rest[..<underscore].allSatisfy(\.isNumber), !rest[..<underscore].isEmpty {
            rest = String(rest[rest.index(after: underscore)...])
            return coreSuffixes.contains(rest) && !["blogs", "site", "sitemeta", "blogmeta", "blog_versions", "registration_log", "signups"].contains(rest)
        }
        return false
    }

    // MARK: Clustering

    /// Groups a database's tables: WordPress core first (when the prefix is detected), then clusters that share a
    /// name prefix, then the leftovers.
    ///
    /// Non-core tables are clustered by the leading token of their name (after the WordPress prefix, if any) up to the
    /// first `_` when at least two tables share it (`actionscheduler_*`, `gf_*`); the rest are clustered by the longest
    /// common leading stem of two or more characters shared by two or more tables (`wfconfig`, `wfhits`, … → `wf*`).
    /// Anything still alone is "Other tables".
    public static func cluster(_ names: [String]) -> (prefix: String?, groups: [TableGroup]) {
        let prefix = detectPrefix(in: names)
        let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var groups: [TableGroup] = []
        var remaining = sorted
        if let prefix {
            let core = sorted.filter { isCore($0, prefix: prefix) }
            if !core.isEmpty {
                groups.append(TableGroup(kind: .core, pattern: nil, friendlyName: nil, tables: core))
                remaining = sorted.filter { !core.contains($0) }
            }
        }
        let skip = prefix ?? ""
        func rest(_ name: String) -> String { name.hasPrefix(skip) ? String(name.dropFirst(skip.count)) : name }

        // 1. Shared leading token.
        var byToken: [String: [String]] = [:]
        for name in remaining {
            let r = rest(name)
            if let underscore = r.firstIndex(of: "_"), underscore != r.startIndex { byToken[String(r[..<underscore])] = (byToken[String(r[..<underscore])] ?? []) + [name] }
        }
        var clusters: [TableGroup] = []
        var used = Set<String>()
        for (token, members) in byToken where members.count >= 2 {
            clusters.append(TableGroup(kind: .cluster, pattern: "\(skip)\(token)_*", friendlyName: WordPressTableCatalog.friendlyName(forStem: token), tables: members))
            used.formUnion(members)
        }

        // 2. Shared stem among the rest (tables without an underscore, and tokens that stayed alone).
        var byStem: [String: [String]] = [:]
        for name in remaining where !used.contains(name) {
            let r = rest(name)
            guard r.count >= 2 else { continue }
            byStem[String(r.prefix(2)).lowercased(), default: []].append(name)
        }
        for (_, members) in byStem where members.count >= 2 {
            let stem = longestCommonPrefix(members.map { rest($0).lowercased() })
            guard stem.count >= 2 else { continue }
            let matching = members.filter { rest($0).lowercased().hasPrefix(stem) }
            clusters.append(TableGroup(kind: .cluster, pattern: "\(skip)\(stem)*", friendlyName: WordPressTableCatalog.friendlyName(forStem: stem), tables: matching))
            used.formUnion(matching)
        }
        clusters.sort { ($0.pattern ?? "").localizedStandardCompare($1.pattern ?? "") == .orderedAscending }
        groups += clusters
        let others = remaining.filter { !used.contains($0) }
        if !others.isEmpty { groups.append(TableGroup(kind: .other, pattern: nil, friendlyName: nil, tables: others)) }
        return (prefix, groups)
    }

    private static func longestCommonPrefix(_ strings: [String]) -> String {
        guard var prefix = strings.first.map(Array.init) else { return "" }
        for s in strings.dropFirst() {
            let other = Array(s)
            var n = 0
            while n < prefix.count, n < other.count, prefix[n] == other[n] { n += 1 }
            prefix = Array(prefix[..<n])
        }
        return String(prefix)
    }

    // MARK: Suggestions

    /// "Usually not needed" tables: structure only is suggested (never applied automatically). The curated list of
    /// well-known log/cache tables comes first for precision, then generic name heuristics.
    public static func suggestion(for name: String, prefix: String?, isCore: Bool = false) -> TableSuggestion? {
        if isCore { return nil }
        let rest = (prefix.map { name.hasPrefix($0) ? String(name.dropFirst($0.count)) : name } ?? name).lowercased()
        if let reason = WordPressTableCatalog.knownReason(forTable: rest) {
            return TableSuggestion(mode: .structureOnly, reason: reason)
        }
        let noise = ["catalog", "blog", "dialog", "backlog", "analog"]
        if rest.hasSuffix("_log") || rest.hasSuffix("_logs") || rest == "log" || rest == "logs"
            || ((rest.hasSuffix("log") || rest.hasSuffix("logs")) && !noise.contains { rest.hasSuffix($0) || rest.hasSuffix($0 + "s") }) {
            return TableSuggestion(mode: .structureOnly, reason: "Looks like a log table — usually not needed")
        }
        if rest.contains("session") && (rest.hasSuffix("sessions") || rest.hasSuffix("session")) {
            return TableSuggestion(mode: .structureOnly, reason: "Session data — temporary")
        }
        if rest.hasSuffix("cache") { return TableSuggestion(mode: .structureOnly, reason: "Cache table — rebuilt automatically") }
        if rest.contains("transient") { return TableSuggestion(mode: .structureOnly, reason: "Transient data — temporary") }
        if rest.hasSuffix("queue") { return TableSuggestion(mode: .structureOnly, reason: "Job queue — usually temporary") }
        if rest.hasSuffix("_events") || rest.hasSuffix("events") && rest.contains("_") {
            return TableSuggestion(mode: .structureOnly, reason: "Event records — often a log")
        }
        if rest.hasSuffix("hits") || rest.hasSuffix("_hits") { return TableSuggestion(mode: .structureOnly, reason: "Hit / traffic records — usually not needed") }
        if rest.hasSuffix("_stats") || rest.hasSuffix("_statistics") { return TableSuggestion(mode: .structureOnly, reason: "Statistics — often rebuildable") }
        if rest.hasSuffix("_tmp") || rest.hasSuffix("_temp") || rest == "tmp" || rest == "temp" {
            return TableSuggestion(mode: .structureOnly, reason: "Temporary table")
        }
        return nil
    }
}

/// Optional polish: friendly names for well-known plugin stems and an extra-precise list of their log/cache tables.
/// Nothing depends on a table being in here.
public enum WordPressTableCatalog {
    static let friendly: [String: String] = [
        "wf": "Wordfence", "wfls": "Wordfence Login Security", "actionscheduler": "Action Scheduler", "wc": "WooCommerce",
        "woocommerce": "WooCommerce", "yoast": "Yoast SEO", "rank": "Rank Math", "redirection": "Redirection", "gf": "Gravity Forms",
        "rg": "Gravity Forms", "wpforms": "WPForms", "e": "Elementor", "jetpack": "Jetpack", "itsec": "Solid Security",
        "aioseo": "All in One SEO", "wpmailsmtp": "WP Mail SMTP", "simple": "Simple History", "litespeed": "LiteSpeed Cache",
        "wpr": "WP Rocket", "matomo": "Matomo", "tablepress": "TablePress", "icl": "WPML", "revslider": "Slider Revolution",
        "um": "Ultimate Member", "learndash": "LearnDash", "bp": "BuddyPress", "bbp": "bbPress", "mailchimp": "Mailchimp",
    ]

    public static func friendlyName(forStem stem: String) -> String? { friendly[stem.lowercased()] }

    private static let wordfenceReasons: [String: String] = [
        "wfhits": "Wordfence traffic log — usually not needed",
        "wflivetraffichuman": "Wordfence live traffic log — usually not needed",
        "wflogins": "Wordfence login log — usually not needed",
        "wfstatus": "Wordfence scan status log — usually not needed",
        "wfsecurityevents": "Wordfence security event log — usually not needed",
        "wffilemods": "Wordfence scan cache — rebuilt by the next scan",
        "wfknownfilelist": "Wordfence scan cache — rebuilt by the next scan",
        "wfissues": "Wordfence scan results — regenerated by scanning",
        "wfpendingissues": "Wordfence scan results — regenerated by scanning",
        "wfcrawlers": "Wordfence crawler cache — usually not needed",
        "wflocs": "Wordfence IP location cache — usually not needed",
        "wfreversecache": "Wordfence DNS cache — usually not needed",
        "wftrafficrates": "Wordfence rate counters — usually not needed",
        "wfsnipcache": "Wordfence cache — usually not needed",
        "wfhoover": "Wordfence scan cache — usually not needed",
        "wfblockediplog": "Wordfence blocked-IP log — usually not needed",
    ]

    private static let others: [String: String] = [
        "actionscheduler_logs": "Action Scheduler log — usually not needed",
        "actionscheduler_claims": "Action Scheduler job claims — temporary",
        "redirection_404": "Redirection 404 log — usually not needed",
        "redirection_logs": "Redirection log — usually not needed",
        "woocommerce_sessions": "WooCommerce customer sessions — temporary",
        "wc_download_log": "WooCommerce download log — usually not needed",
        "itsec_logs": "Solid Security log — usually not needed",
        "itsec_temp": "Solid Security temporary data",
        "simple_history": "Simple History activity log — usually not needed",
        "simple_history_contexts": "Simple History activity log — usually not needed",
        "wpmailsmtp_debug_events": "WP Mail SMTP debug log — usually not needed",
        "wpr_rucss_used_css": "WP Rocket cache data — rebuilt automatically",
        "wpr_rocket_cache": "WP Rocket cache data — rebuilt automatically",
    ]

    /// `rest` is the table name without the WordPress prefix, lower-cased.
    static func knownReason(forTable rest: String) -> String? {
        if let r = wordfenceReasons[rest] { return r }
        if let r = others[rest] { return r }
        if rest.hasPrefix("litespeed_"), ["url", "url_file", "avatar", "img_optm", "img_optming", "crawler", "crawler_blacklist"].contains(String(rest.dropFirst("litespeed_".count))) {
            return "LiteSpeed cache data — rebuilt automatically"
        }
        return nil
    }
}

/// Bulk mode setters shown above the table list.
public enum ExportTablePreset: String, CaseIterable, Sendable, Identifiable {
    case allTables, coreOnly, corePlusPluginStructure

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .allTables: "All tables"
        case .coreOnly: "WordPress core only"
        case .corePlusPluginStructure: "Core + plugin structure only"
        }
    }

    /// The modes this preset sets (tables not listed are exported fully). Needs a core group; without one every
    /// preset but "All tables" does nothing.
    public func modes(for groups: [TableGroup]) -> [String: TableExportMode] {
        guard groups.contains(where: { $0.kind == .core }) else { return [:] }
        var out: [String: TableExportMode] = [:]
        for group in groups where group.kind != .core {
            switch self {
            case .allTables: break
            case .coreOnly: for t in group.tables { out[t] = .skip }
            case .corePlusPluginStructure: for t in group.tables { out[t] = .structureOnly }
            }
        }
        return out
    }
}
