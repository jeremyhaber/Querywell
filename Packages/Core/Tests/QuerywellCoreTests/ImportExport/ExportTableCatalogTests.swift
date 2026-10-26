import Foundation
import Testing

@testable import QuerywellCore

private let wpCore = ["posts", "postmeta", "options", "users", "usermeta", "terms", "termmeta", "term_taxonomy", "term_relationships", "comments", "commentmeta", "links"]
private let wordfence = ["wfconfig", "wfhits", "wflogins", "wfblocks7", "wfknownfilelist", "wfstatus", "wfissues", "wffilemods", "wflivetraffichuman", "wfsecurityevents"]
private let realistic: [String] = (wpCore + wordfence + [
    "actionscheduler_actions", "actionscheduler_claims", "actionscheduler_groups", "actionscheduler_logs",
    "gf_entry", "gf_entry_meta", "gf_form", "yoast_indexable", "yoast_migrations", "yoast_seo_links",
    "acmeplugin_orders", "acmeplugin_settings", "lonely", "x",
]).map { "wp_" + $0 }

@Suite("Export table catalog")
struct ExportTableCatalogTests {
    private func group(_ groups: [TableGroup], _ pattern: String) -> TableGroup? { groups.first { $0.pattern == pattern } }

    @Test func detectsThePrefix() {
        #expect(ExportTableCatalog.detectPrefix(in: realistic) == "wp_")
        // The prefix needs options + posts + users.
        #expect(ExportTableCatalog.detectPrefix(in: ["shop_options", "shop_posts", "wp_options"]) == nil)
        #expect(ExportTableCatalog.detectPrefix(in: ["shop_options", "shop_posts", "shop_users", "wp_options"]) == "shop_")
        #expect(ExportTableCatalog.detectPrefix(in: ["orders", "customers"]) == nil)
        #expect(ExportTableCatalog.detectPrefix(in: ["wp_options", "wp_posts", "wp_users", "wp_2_options", "wp_2_posts"]) == "wp_")
    }

    @Test func detectsEveryPrefixOfAnLiveAndStagingDatabase() {
        let live = realistic
        let staging = (wpCore + ["wfconfig", "wfhits", "actionscheduler_actions", "actionscheduler_logs", "lonely"]).map { "wpstg0_" + $0 }
        let both = (live + staging).shuffled()
        #expect(ExportTableCatalog.detectPrefixes(in: both) == ["wp_", "wpstg0_"])
        let (prefixes, groups) = ExportTableCatalog.clusterAll(both)
        #expect(prefixes == ["wp_", "wpstg0_"])
        let cores = groups.filter { $0.kind == .core }
        #expect(cores.map(\.title) == ["WordPress core · wp_", "WordPress core · wpstg0_"])
        #expect(cores.allSatisfy { $0.tables.count == 12 })
        #expect(Set(cores.map(\.id)).count == 2)
        // Plugin clusters are per prefix, with globs that can't match the other install.
        #expect(group(groups, "wp_wf*")?.tables.count == 10)
        #expect(group(groups, "wpstg0_wf*")?.tables.sorted() == ["wpstg0_wfconfig", "wpstg0_wfhits"])
        #expect(group(groups, "wpstg0_actionscheduler_*")?.tables.count == 2)
        #expect(group(groups, "wp_actionscheduler_*")?.tables.count == 4)
        // Every table appears exactly once.
        let all = groups.flatMap(\.tables)
        #expect(all.count == both.count && Set(all).count == both.count)
        // The "core only" preset skips every plugin table of both installs.
        let modes = ExportTablePreset.coreOnly.modes(for: groups)
        #expect(modes["wpstg0_wfhits"] == .skip && modes["wp_wfhits"] == .skip && modes["wpstg0_posts"] == nil)
    }

    @Test func singleInstallKeepsPlainCoreTitle() {
        let (_, groups) = ExportTableCatalog.clusterAll(realistic)
        #expect(groups.first { $0.kind == .core }?.title == "WordPress core")
    }

    @Test func clustersARealisticWordPressDatabase() {
        let (prefix, groups) = ExportTableCatalog.cluster(realistic.shuffled())
        #expect(prefix == "wp_")
        let core = groups.first { $0.kind == .core }
        #expect(core?.tables.count == 12)
        #expect(core?.title == "WordPress core")

        let wf = group(groups, "wp_wf*")
        #expect(wf?.tables.count == 10)
        #expect(wf?.friendlyName == "Wordfence")
        #expect(wf?.title == "Wordfence · wp_wf*")
        #expect(group(groups, "wp_actionscheduler_*")?.tables.count == 4)
        #expect(group(groups, "wp_actionscheduler_*")?.friendlyName == "Action Scheduler")
        #expect(group(groups, "wp_gf_*")?.tables.count == 3)
        #expect(group(groups, "wp_yoast_*")?.friendlyName == "Yoast SEO")
        let acme = group(groups, "wp_acmeplugin_*")
        #expect(acme?.tables == ["wp_acmeplugin_orders", "wp_acmeplugin_settings"])
        #expect(acme?.friendlyName == nil, "unknown plugins just show the pattern")
        #expect(acme?.title == "wp_acmeplugin_*")
        let other = groups.last
        #expect(other?.kind == .other && Set(other?.tables ?? []) == ["wp_lonely", "wp_x"])
        // Core first, "Other tables" last, every table exactly once.
        #expect(groups.first?.kind == .core)
        #expect(groups.flatMap(\.tables).sorted() == realistic.sorted())
    }

    @Test func multisiteCoreTablesStayCore() {
        let names = ["wp_options", "wp_posts", "wp_users", "wp_blogs", "wp_site", "wp_sitemeta", "wp_2_options", "wp_2_posts", "wp_2_postmeta", "wp_3_comments", "wp_wfhits", "wp_wflogins"]
        let (_, groups) = ExportTableCatalog.cluster(names)
        #expect(groups[0].kind == .core && groups[0].tables.count == 10)
        #expect(groups[1].pattern == "wp_wf*")
    }

    @Test func nonWordPressSchemasClusterByPrefixWithoutACoreGroup() {
        let (prefix, groups) = ExportTableCatalog.cluster(["shop_orders", "shop_items", "shop_carts", "crm_contacts", "crm_deals", "settings"])
        #expect(prefix == nil)
        #expect(groups.contains { $0.kind == .core } == false)
        #expect(groups.map(\.pattern).prefix(2) == ["crm_*", "shop_*"])
        #expect(groups.last?.kind == .other && groups.last?.tables == ["settings"])
    }

    @Test func shortStemsNeedTwoCharactersAndTwoTables() {
        let (_, groups) = ExportTableCatalog.cluster(["a1", "b2", "ab"])
        #expect(groups.count == 1 && groups[0].kind == .other)
    }

    @Test func genericHeuristicsSuggestStructureOnlyWithAReason() {
        func s(_ name: String) -> TableSuggestion? { ExportTableCatalog.suggestion(for: "wp_" + name, prefix: "wp_") }
        for name in ["foo_log", "foo_logs", "shop_sessions", "foo_cache", "foo_transients", "mail_queue", "foo_events", "page_hits", "foo_stats", "foo_tmp", "foo_temp", "bar_temp"] {
            let r = s(name)
            #expect(r?.mode == .structureOnly && r?.reason.isEmpty == false, "\(name)")
        }
        #expect(s("catalog") == nil)
        #expect(s("blogs") == nil)
        #expect(s("orders") == nil)
        #expect(s("gf_form") == nil)
    }

    @Test func curatedListAddsPrecision() {
        #expect(ExportTableCatalog.suggestion(for: "wp_wfhits", prefix: "wp_")?.reason == "Wordfence traffic log — usually not needed")
        #expect(ExportTableCatalog.suggestion(for: "wp_wfknownfilelist", prefix: "wp_")?.reason.contains("scan cache") == true)
        #expect(ExportTableCatalog.suggestion(for: "wp_wfconfig", prefix: "wp_") == nil, "settings are kept")
        #expect(ExportTableCatalog.suggestion(for: "wp_actionscheduler_logs", prefix: "wp_") != nil)
        #expect(ExportTableCatalog.suggestion(for: "wp_actionscheduler_actions", prefix: "wp_") == nil)
        #expect(ExportTableCatalog.suggestion(for: "wp_woocommerce_sessions", prefix: "wp_") != nil)
        #expect(ExportTableCatalog.suggestion(for: "wp_registration_log", prefix: "wp_", isCore: true) == nil, "core tables are never suggested")
    }

    @Test func presetsAreBulkModeSetters() {
        let (_, groups) = ExportTableCatalog.cluster(realistic)
        #expect(ExportTablePreset.allTables.modes(for: groups).isEmpty)
        let coreOnly = ExportTablePreset.coreOnly.modes(for: groups)
        #expect(coreOnly["wp_wfhits"] == .skip && coreOnly["wp_posts"] == nil && coreOnly.count == realistic.count - 12)
        let structure = ExportTablePreset.corePlusPluginStructure.modes(for: groups)
        #expect(structure["wp_gf_form"] == .structureOnly && structure["wp_options"] == nil)
        let (_, plain) = ExportTableCatalog.cluster(["a_x", "a_y"])
        #expect(ExportTablePreset.coreOnly.modes(for: plain).isEmpty, "no core group: presets do nothing")
    }
}

@Suite("Export selection rules")
struct ExportSelectionRulesTests {
    @Test func globMatching() {
        #expect(GlobPattern.matches("wp_wf*", "wp_wfHits"))
        #expect(GlobPattern.matches("*_log*", "wp_foo_logs"))
        #expect(GlobPattern.matches("wp_?x", "wp_ax") && !GlobPattern.matches("wp_?x", "wp_abx"))
        #expect(GlobPattern.matches("wp_options", "WP_OPTIONS"))
        #expect(!GlobPattern.matches("wp_options", "wp_options2"))
        #expect(GlobPattern.matches("options", "wp_options2", substringIfPlain: true))
        #expect(GlobPattern.matches("*", ""))
    }

    @Test func lastMatchingRuleWinsThenOverrides() {
        let config = ExportSelectionConfig(
            rules: [ExportRule(pattern: "wp_wf*", mode: .skip), ExportRule(pattern: "wp_wfconfig", mode: .both), ExportRule(pattern: "*_log*", mode: .structureOnly)],
            overrides: ["wp_foo_logs": .both, "gone": .skip])
        let modes = config.resolve(tableNames: ["wp_posts", "wp_wfhits", "wp_wfconfig", "wp_x_log", "wp_foo_logs"])
        #expect(modes == ["wp_wfhits": .skip, "wp_x_log": .structureOnly])
        #expect(ExportRule(pattern: "wp_wf*", mode: .skip).label == "Skip wp_wf*")
    }

    @Test func storePersistsPerConnectionWithOwnerOnlyPermissions() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qw-rules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("export-rules.json")
        let a = UUID(), b = UUID()
        let store = ExportRulesStore(fileURL: url)
        #expect(try await store.config(for: a) == ExportSelectionConfig())
        let config = ExportSelectionConfig(rules: [ExportRule(pattern: "wp_wf*", mode: .skip)], overrides: ["t": .structureOnly])
        try await store.save(config, for: a)
        try await store.save(ExportSelectionConfig(rules: [ExportRule(pattern: "x*", mode: .skip)]), for: b)
        let reread = ExportRulesStore(fileURL: url)
        #expect(try await reread.config(for: a) == config)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        try await reread.purge(connectionID: a)
        #expect(try await ExportRulesStore(fileURL: url).config(for: a) == ExportSelectionConfig())
        #expect(try await ExportRulesStore(fileURL: url).config(for: b).rules.count == 1)
    }
}
