# Progress

## Phase 1 — Foundation ✅ (2026-10-26)

**Built**
- XcodeGen `project.yml` → macOS 14 app target `Querywell` (SwiftUI placeholder launcher + Settings), `QuerywellTests`, scheme runs app + Core tests. Hardened runtime on, sandbox off, ad-hoc local signing, warnings as errors, Swift 6 strict concurrency.
- `Packages/Core` (`QuerywellCore`): `ConnectionProfile` (engine, host/port/user, default DB, folder, color tag, SSH tunnel config with key/agent/password, TLS modes, read-only, timestamps — no secret fields), tolerant versioned decoding, `ConnectionValidator`, `ConnectionFolder`, `ConnectionRepository` actor (atomic, transactional JSON persistence in Application Support), `SecretStore` protocol with `KeychainSecretStore` (Security framework) and `InMemorySecretStore`.
- `scripts/ci.sh` — the phase gate: xcodegen, `swift build/test` with warnings-as-errors, `xcodebuild build test`, fails on any warning in the log.

**Status:** CI PASS — 0 warnings; 46 Core tests (incl. real login-keychain round trip) + 2 app tests.

**Decided:** see DECISIONS.md #1–12.

**Next — Phase 2 (Connectivity):** `DatabaseDriver` protocol; MySQLNIO / PostgresNIO drivers; SSH tunnels via Citadel (fallback `ssh -L`); TLS; connection test; docker-compose integration tests (MySQL 8, MariaDB 11, Postgres 16) that skip without Docker.

## Phase 2 — Connectivity ✅ (2026-10-26)

**Built**
- `DatabaseDriver` / `DatabaseSession` contracts with `DatabaseValue`, `QueryResult`, `ServerInfo`, typed `DatabaseError`; `DriverRegistry`.
- MySQL/MariaDB driver (MySQLNIO 1.9 + custom text-protocol command for column metadata on empty sets, affected rows, insert IDs; MariaDB auto-detection; connect timeout; TLS verification enforcement incl. preferred→plaintext fallback).
- PostgreSQL driver (PostgresNIO 1.33; canonical text rendering of binary results for numeric/date/time/interval/json/uuid/inet/arrays/ranges/enums; command-tag row counts; pg_stat_ssl TLS detection).
- SSH tunnels via system OpenSSH (`SystemSSHTunnelProvider`): key file, encrypted key, agent (incl. 1Password socket path), password via secure one-shot askpass; host-key TOFU with hard fail on change; reusable `SSHCommandBuilder` for Phase 7.
- `ConnectionOpener` → `LiveConnection` (session + tunnel), `ConnectionTester` with stage timings, latency, warnings (engine mismatch, unencrypted, PROD without TLS/SSH), user-facing errors with recovery suggestions; fail-fast when a bastion can't reach the DB.
- `docker-compose.yml` (MySQL 8.4, MariaDB 11.4, Postgres 16 + TLS, Alpine sshd bastion), `scripts/integration.sh`, wired into `scripts/ci.sh`.

**Status:** CI PASS from a clean build — 0 warnings; 154 Core tests (unit + Docker integration against all three servers and the bastion) + app tests. Three consecutive green runs.

**Decided:** DECISIONS #13–23 (system ssh over Citadel, host-key policy, integration setup, warning gate scope, driver caveats, fail-fast tunnels).

**Known caveats → revisit Phase 5:** Postgres zero-row SELECT column fetch via `LIMIT 0` wrapper; composite/geometric PG types as bytes; MySQLNIO Debug assertion on late pipeline errors; `verifyCA` only unit-tested.

**Next — Phase 3 (App shell):** launcher window per design (`design/project/Connections.dc.html`), connection editor with Test button, one window per connection holding a `LiveConnection`, native tabs, ⌘K switcher, PROD badge, Settings.

## Phase 3 — App shell ✅ (2026-10-26)

**Built**
- Core: launcher query (search/folders/favourites/tags/sort), card summaries, fuzzy matcher + ⌘K quick switcher model, workspace tab model, `AppSettings` + store, `ConnectionDraft` (editor form state, secret save/delete rules), `LatencyFormatter`, `DatabaseSelection`.
- App: launcher per design (folders/tags sidebar, search, cards, context menus, drag-to-folder, empty states); connection editor sheet with live Test Connection; one window per connection (`ConnectionWorkspace` holding a `LiveConnection`, keepalive, reconnect); toolbar identity pill with PROD badge, status + latency, ⌘K and New query; in-window tab strip; ⌘K palette; Settings (AI keys in Keychain); Debug ▸ Add Docker test connections; quit closes all connections/tunnels.
- `scripts/snapshots.sh`: renders launcher/editor/connection window (light+dark) from real window-server captures, drives a real Docker connection end to end, asserts the toolbar never overflows at 1200/1000/820pt.

**Fixed after review:** toolbar identity was split/ghosted and a stray glass circle (AppKit overflow button) appeared behind it (#27); default DB skipped system schemas; window-accessor use-after-free on fast close; editor Test used stored secret after the field was cleared.

**Status:** CI PASS, 0 warnings. Core 230+ tests, app 22+ tests, snapshot suite green.

**Next — Phase 4 (Table browser):** schema introspection, data grid, structure/indexes/relations, filters + chips, inline edit with review/commit, row inspector, PROD write guard, batch engine/collation changes.

## Phase 4 — Table browser ✅ (2026-10-26)

**Built**
- Core: MySQL/MariaDB + Postgres schema inspectors (tables/views/routines, columns, indexes, FKs in/out, CREATE, collations, engines), `SQLDialect` quoting choke point (MySQL sessions strip NO_BACKSLASH_ESCAPES), `TableQuery` paging/sort/filters, filter model + saved filters, distinct-value counts, WHERE autocomplete, SQL lexer/splitter/classifier, `WriteGuard` (+ dry-run counts, `WriteOrigin.gridEdit`), `EditSession` (transactional commit with optimistic concurrency), `TableMaintenancePlanner`/`MaintenanceRunner`, cell value parser, edit review model.
- App: schema sidebar (DB picker, fuzzy table filter, row estimates, views/routines, multi-select), virtualized NSTableView grid (type headers, PK/FK markers, FK navigation, copy as TSV/CSV/JSON/INSERT, paging with exact/estimated counts), Structure/Indexes/Relations views, funnel popover + chips + saved filters + Show as SQL, row inspector, inline editing (edited/deleted/inserted styling, amber Review pill, Review sheet with exact SQL, conflict handling + rebase), shared `WriteGate` + `WriteConfirmationSheet` (dry-run impact, typed DB name on PROD), Truncate/Drop, batch storage-engine / charset+collation sheet with per-table progress.

**Status:** CI PASS, 0 warnings; Core 944+ tests; snapshot suite incl. Docker end-to-end edit/commit/conflict.

**Decided:** #29–33.

## Phase 6 — Data editors ✅ (2026-10-26)
- Core: PHP serialized parser/serializer (byte-exact round trip, verified against PHP 8.3-generated fixtures; repair proposals), JSON document (order/number-preserving, original-formatting save), `SafeReplacer` (serialized/JSON/nested, `\/`-escaped URLs), `DatabaseSearchReplace` (dry run, per-table transactions, optimistic writes, invalid-serialized report).
- App: value editor (JSON tree/raw with line:col errors; PHP tree with read-only custom objects/references; explicit repair with diff); Search & Replace sheet (⇧⌘H) with preview samples, WordPress defaults (guid skipped), PROD typed-name confirmation. Saving editors creates pending edits (normal Review flow).

## Phase 7 — Console, terminal, import/export ✅ (2026-10-26)
- Core: console formatting/input (mysql-style ASCII tables, `\G`, continuation), SSH terminal command, dump tool discovery + version checks, export planner (remote over SSH with password only in a trap-removed temp file; per-table structure/data modes split across up to 3 mysqldump runs; transients excluded via separate `--where` run; collation rewrite stage), streaming gzip, import runner (streaming splitter, collation pre-scan + mapping, stop/continue on error), result exporter (CSV/JSON/SQL INSERT), automatic table clustering + generic "structure only" suggestions + per-connection export rules.
- App: SQL console tab, SSH terminal tab (SwiftTerm 1.11.2), export dialog per design with table selection (groups by prefix, presets, rule chips, suggestions, live size), progress/cancel, import (menu + drag & drop) with scan/mapping/confirmation, result & table export.
- End-to-end: export over SSH bastion → import into fresh schema → row counts match.

**Status after 1–7:** CI PASS (0 warnings), Core ~1,100 tests incl. Docker integration on MySQL 8.4 / MariaDB 11.4 / Postgres 16, App unit + snapshot suites.

**Known follow-ups for Phase 8:** UI snapshots only exercise MySQL (Postgres/MariaDB UI paths need end-to-end coverage); databases with two WordPress prefixes pick one for transient skipping; Xcode rewrites `Packages/Core/Package.resolved` with SwiftTerm pins; 1M-row performance unmeasured; SwiftTerm pinned to 1.11.2 (newer needs Metal toolchain / plugin validation).

## Scope additions (requested by Jeremy, 2026-10-26)

### A. Collation / charset compatibility on export (and import) — Phase 7
Problem: dumps from MySQL 8 (`utf8mb4_0900_ai_ci`) fail on MariaDB / MySQL 5.7 / some hosts with "Unknown collation".
- Export dialog: **Target collation** option — "Keep original" (default), presets ("MySQL 5.7 / MariaDB compatible": `utf8mb4_0900_*` → `utf8mb4_unicode_520_ci`; "Legacy utf8mb4_unicode_ci"), or explicit charset + collation picker populated from the target server's `SHOW COLLATION` when known.
- Same rewrite available on **import** ("Fix collations for this server"), auto-suggested when the file uses collations the connected server doesn't support (pre-scan, show which ones).
- Core: streaming `CollationRewriter` over SQL dump text (plain and gzip). Rewrites only DDL contexts — `CREATE DATABASE`, `CREATE TABLE` table options and column `CHARACTER SET`/`COLLATE`, `ALTER … CONVERT TO`, `SET NAMES`, and `/*!40101 … */` versioned comments — and **never** touches INSERT/data payloads. Mapping table is data-driven. Heavy unit tests (real mysqldump output from MySQL 8.4 and MariaDB 11; strings containing collation names inside INSERT values must survive byte-for-byte). Command preview shows that a rewrite stage is in the pipeline.
- Postgres: out of scope for v1 (locale/ICU mismatches noted for later).

### B. Batch table operations — Phase 4 (table browser)
- Multi-select tables in the sidebar (⌘/⇧-click, "Select all matching filter") → **Change storage engine…** (e.g. MyISAM → InnoDB) and **Convert charset/collation…** (`ALTER TABLE … CONVERT TO CHARACTER SET … COLLATE …`, plus optional database default).
- Sheet shows each table's current engine/collation/rows/size, skips tables already matching, and previews the exact `ALTER TABLE` statements (Copy). PROD guard applies (type DB name). Runs sequentially with per-table progress, cancel between tables, stop-or-continue on error, final report. Warns that DDL is not transactional and may lock large tables.
- Core: `TableMaintenancePlanner` (pure: current table metadata + requested change → ordered statements + warnings, e.g. FULLTEXT on MyISAM→InnoDB pre-5.6, FK constraints when leaving InnoDB, index key-length limits when moving to utf8mb4) and a runner with progress events. Unit tests + integration tests on MySQL 8.4 / MariaDB 11.

## Phase 5 UI — query editor + AI builder ✅ (2026-10-26)

**Built:** in-house TextKit 2 SQL editor (`App/Sources/Query/SQLTextView.swift`: highlighting via `SQLHighlighter.rehighlightRange`, line numbers, current line, bracket match, auto-indent, ⌘/, ⇥/⇧⇥, autocomplete popup, snippet tab stops, error squiggles); query tab (run/selection/statement, Explain plan tab, Format, result tabs, Messages, editable results, Copy as CSV, footer guard hint); History | Saved | Snippets sidebar; Save as…; AI assistant panel (⌘⇧A) with streaming markdown-lite, Insert/Replace (never runs), SQL review warnings, per-connection sample-rows opt-in; Settings → History and AI (model list, Test key); ⌘K saved queries; connection delete purges history/saved/snippets.

**Status:** see `scripts/ci.sh` and `scripts/snapshots.sh` (query-* PNGs, light + dark).

### C. Export table selection (requested by Jeremy, 2026-10-26) — Phase 7
Per-table Structure / Data (default both) without checkbox fatigue: rows grouped by WordPress plugin (Wordfence, WooCommerce, Action Scheduler, Yoast…), click-to-cycle Both → Structure only → Skip, group-level toggles, a filter whose results can be bulk-skipped / made structure-only and **remembered as per-connection rules** (e.g. "Skip wp_wf*", shown as chips, auto-applied next time), one-click "Apply suggestions" for known log/cache tables (never automatic), live size estimate. Planner splits into up to three mysqldump invocations (full / --no-data / --no-create-info) concatenated into one file; pg_dump uses --exclude-table-data.

## Phase 8 — Polish and release ✅ (2026-10-26)
8A performance/engines, 8B distribution, 8C accessibility (sections below). Final gate: all Querywell build caches wiped, `scripts/ci.sh` from scratch → PASS, 0 warnings (Core unit + Docker integration on MySQL 8.4 / MariaDB 11.4 / Postgres 16, app tests incl. contrast + accessibility). Ad-hoc-signed universal Release test build 1.0.0 (1) in `build/test-builds/`.

**v1 complete.** Needs from Jeremy for a public release: Apple Team ID + Developer ID Application certificate + notarytool profile (see README "Release"), final icon art, license. Known limits: DECISIONS #21, #40, and Phase 8A "Left undone" (drivers buffer whole result sets; Postgres import can't retarget schema).

## Phase 8B - Distribution (2026-10-26)
- App icon placeholder (`scripts/make-icon.swift` -> `AppIcon.appiconset`, all sizes); a Release build compiles the catalog with zero warnings and the bundle contains `AppIcon.icns` + `Assets.car`.
- `scripts/release.sh`: preflight (Xcode, xcodegen, identity for the team in the keychain, notary profile), clean xcodegen, CI gate, archive, export (developer-id), signature/entitlement/nested-binary verification, notarize + staple app, signed DMG (with /Applications link), notarize + staple DMG, zip, spctl checks, SHA256SUMS. Flags: `--dry-run`, `--no-notarize`, `--skip-tests`, `--verify-only APP`. Dry run, preflight failure paths and the verifier (against an ad-hoc build) were tested; the real signing/notarization path has not been run (no Developer ID identity on the dev machine).
- `scripts/bump-version.sh`; version set to 1.0.0 (build 1).
- README rewritten (features, screenshots in `docs/screenshots/`, build/test/release, safety, privacy, shortcuts, limitations); ARCHITECTURE.md layout updated to the real tree.
- Decided: #52-56.
- Jeremy must provide: Apple Developer Team ID, a Developer ID Application certificate in the keychain, a notarytool keychain profile, final icon art, and the license text.
## Phase 8A — performance at 1M rows, Postgres/MariaDB end-to-end, follow-ups ✅ (2026-10-26)

**Data:** `scripts/perf-data.sh` creates (once, idempotently) `qw_perf.big_posts` (1,000,000 rows, ~600 B each: bigint PK, varchar, text, datetime, status, indexed `post_author` and a composite index, unindexed `post_name`/`post_content`) on MySQL 8.4 and Postgres 16 server-side. Measurements: `QUERYWELL_PERF=1 swift test --filter PerfTests` (Core, drivers + exporter) and `TEST_RUNNER_QUERYWELL_PERF=1 … -only-testing:QuerywellTests/GridPerfTests` (real `TableDataModel` + `DataGridView`). **All numbers are Debug builds on a laptop against local Docker.** The `qw_perf` schemas were dropped after measuring (disk); rerun the script to recreate them.

| Measurement | Before (MySQL / PG) | After (MySQL / PG) |
|---|---|---|
| Open table, first page visible (structure + 500 rows) | 36 / 64 ms | 47 / 54 ms (model, incl. structure) |
| Exact COUNT(*) 1M rows | 325 / 32 ms | same, but off the page session: arrives 440 / 102 ms after open |
| Next page while COUNT(*) in flight | 273 / 24 ms (queued behind it) | 15 / 26 ms |
| Page at OFFSET 990,000 | 689 / 1,106 ms | keyset 17 / 48 ms |
| Last page | OFFSET ≈ 700 / 1,100 ms | 14-18 / 25-29 ms (model: 18 / 29) |
| Previous page from the end | OFFSET | 17 / 31 ms |
| Sorted by indexed `post_author`: first / last page | 75 / 30 ms first, last = deep OFFSET | 52-98 / 181-305 ms first; last 81-93 / 29-34 ms |
| Sort by unindexed column, first page | 6,374 / 153 ms, holds the session | same cost, but Stop frees the UI at once; the statement aborts in 87 / 22 ms; next request after Stop 60 / 66 ms |
| Funnel distinct, unindexed high-cardinality | 4,568 / 568 ms unbounded | capped at ~1.5 s + sample fallback ("Based on a sample of 100k rows") |
| 10,000-row page: fetch+decode+display | 265 / 499 ms fetch only | 569 / 789 ms end to end; longest main-thread stall 1 ms |
| Scrolling the 10k-row page | not measured | slowest frame 3.6 / 5.3 ms |
| Query editor `SELECT * LIMIT 200000` | 5.5 s, RSS +350 MB / 10.7 s | unchanged: driver buffers, runner caps display at 50,000 (decision #61) |
| Table export 1M rows → CSV (679 MB) | 115 s / 97 s, RSS 34→38 MB / 22→27 MB, progress per 1,000-row page | unchanged: already streaming (keyset on PK) and bounded |

**Built:** `DatabaseSession.cancelCurrentQuery()` and `execute(_:interruptible:)` (MySQL `KILL QUERY`, Postgres `pg_cancel_backend`, via a fresh connection from the session's own config); `LiveConnection.openAuxiliarySession()`; Core `KeysetPage`/`TableStructure.keysetOrder`; `DistinctValuesQuery.run(on:policy:)` with timeout + sample; grid: keyset navigation, "Count exactly", Stop button, slow-deep-page notice, sampled-values note; query tab Stop now aborts the running statement; multi-prefix WordPress handling (export grouping, S&R picker, AI context); `Package.resolved` made stable (decision #64); timing tests loosened (#65).

**Engine end-to-end (`App/Tests/EngineEndToEndTests.swift`, run by `scripts/snapshots.sh`):** MariaDB 11.4 and Postgres 16 with WordPress-like fixtures in `qw_e2e_*` schemas — sidebar, table data (sort, enum chip, funnel, raw WHERE, JSON column), Structure/Indexes/Relations, inline edit + conflict + insert, query tab (multi-statement, editable result, error), console, export (MariaDB over the ssh bastion, Postgres local pg_dump), import, search & replace on serialized/JSON values; light/dark PNGs `e2e-{mariadb,postgres}-{table-data,query-results}`.

**Bugs found and fixed:** Postgres export dumped every schema in the database (now `--schema` + qualified patterns); Postgres import failed on `SET transaction_timeout` from a PG18 pg_dump into PG16 (unknown settings are skipped); MariaDB `JSON` columns were typed longtext (detected via `json_valid` CHECK); export grouping/prefix choice with two WordPress installs; query-tab Stop only worked between statements. Postgres import cannot rename the schema inside a pg_dump stream, so the end-to-end test renames the original away first (the sheet's "target schema" applies to MySQL/MariaDB dumps).

**Left:** drivers still buffer whole result sets (200k rows ≈ 350 MB); Postgres import into a differently named schema; numbers are Debug builds.

## Phase 8C — dark mode and accessibility audit ✅ (2026-10-26)

- **Contrast:** `ContrastTests` (about 700 pairings x 4 appearances) found and fixed: textTertiary/syntaxComment on chrome and sidebar (4.25 to 4.70), editor line numbers (3.09 to 4.6+ on the current line), console muted on segment track (4.30 to 4.70), separatorStrong (1.77 to 3.1+), selected card border (2.03 to 3.73), pending edit bar (2.62 to 3.1+), pending pill border (1.83 to 3.35), Staging tag (2.18 to 3.25), dark accent as a boundary on elevated (2.98 to 3.01), white on the destructive button in dark (2.28 to 5.4, new `dangerFill`), dark textTertiary on elevated (4.43 to 4.7). Increase Contrast variants added.
- **Dark audit:** all 54 screens reviewed light vs dark; one defect, the SQL autocomplete list rendering light in dark windows (child panel appearance), fixed. No hard-coded white backgrounds found; literal colours exist only for white-on-fill text and the always-dark export command box.
- **VoiceOver:** existing labels were already complete (source lint finds no unlabeled icon-only control); added the WHERE suggestion list role/rows/selection, spoken announcements for long operations, saved-query SQL label.
- **Keyboard:** tabs are focus stops; README shortcut tables rewritten per area.
- **Reduce Motion:** `Motion` helpers applied to every `withAnimation` / `.animation`.
- **Left:** the grid's funnel button is still pointer-only (⌥⌘F opens it from the keyboard); Increase Contrast was verified by test switch, not on a Mac with the setting on; no VoiceOver listening pass.
- Decided: #66-72.

## Post-v1 feedback round 1 (2026-10-26)

- **Tabs:** horizontal overflow (scroll, page chevrons, position bar, "All tabs" menu); preview tab for single clicks (⌘-click / "Open in New Tab" for a new one; duplicates of one table allowed; Settings ▸ General ▸ "Clicking a table"); tab context menu (Color, Duplicate, Keep, Close, Close Others, Close to the Right); connection tag band + tab-strip tint on every tagged window; equal-size footer +/- buttons. (#73, #74)
- **Databases:** fuzzy-filtered database popover; one window per database with its own connection, or switch in place (setting); New Database… (charset/collation, Postgres owner/encoding/template) and Drop Database…, guarded. (#75, #76)
- **Table tab:** Operations mode (rename/move, comment, engine, collation, AUTO_INCREMENT, row format, copy, analyze/check/checksum/optimize/flush/repair, Postgres ANALYZE/VACUUM/REINDEX, empty/drop) and Triggers mode (list, definition, create, edit, drop). (#77)
- **Health & Doctor tab:** health metrics, baseline recommendations with apply (SET PERSIST / SET GLOBAL / ALTER SYSTEM), ignore, server-RAM input, revision history with revert and drift. (#78)
- **Query tab:** opaque toolbar and solid disabled buttons; Quick queries menu; Schema segment (tables → columns) in the query sidebar. (#79)
- **Inputs:** `PlaceholderTextEditor` fixes the assistant composer caret offset. (#80)
- **Verified:** `scripts/ci.sh --skip-integration` PASS (Core 1171+ tests, app 191). Integration tests for table operations, triggers and health collectors were run against MySQL 8.4, MariaDB 11.4 and Postgres 16 by the agents that wrote them.
- **Left:** Docker snapshot suites not re-run; bulk tab close prompts only for the first dirty tab; Postgres in-place database switch closes table tabs without asking; a window still connecting can be duplicated by choosing its database; Postgres table copy shares the serial sequence; MySQL data copy fails with generated columns; no real-server test creates/drops a database.

## Post-v1 feedback round 2 (2026-10-26)

- **Assistant:** composer no longer fights for focus (plain `@State` instead of an unattached `@FocusState`; `PlaceholderTextEditor` applies focus only when the binding changes). Schema reads are cached per query tab (`AssistantSchemaCache`, dropped with the catalog on ⌘R / reconnect) and detail is limited to the 40 most relevant tables (was 150 — most never fit the 12k summary).
- **Settings ▸ AI:** model "Choose…" is a searchable popover — filter by words in the id/name, and by vendor for `vendor/model` ids (OpenRouter).
- **Query tab layout:** when narrow, Run selection / Explain / Format fold into a "…" menu and Quick queries becomes an icon; toolbar buttons never compress; editor column min 380pt; connection window min width 920pt (was 820).
- **Verified:** `scripts/ci.sh --skip-integration` PASS. Not checked by eye at small sizes; snapshot suites not re-run.
