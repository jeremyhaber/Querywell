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
