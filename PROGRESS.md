# Progress

## Phase 1 — Foundation ✅ (2026-10-26)

**Built**
- XcodeGen `project.yml` → macOS 14 app target `Querywell` (SwiftUI placeholder launcher + Settings), `QuerywellTests`, scheme runs app + Core tests. Hardened runtime on, sandbox off, ad-hoc local signing, warnings as errors, Swift 6 strict concurrency.
- `Packages/Core` (`QuerywellCore`): `ConnectionProfile` (engine, host/port/user, default DB, folder, color tag, SSH tunnel config with key/agent/password, TLS modes, read-only, timestamps — no secret fields), tolerant versioned decoding, `ConnectionValidator`, `ConnectionFolder`, `ConnectionRepository` actor (atomic, transactional JSON persistence in Application Support), `SecretStore` protocol with `KeychainSecretStore` (Security framework) and `InMemorySecretStore`.
- `scripts/ci.sh` — the phase gate: xcodegen, `swift build/test` with warnings-as-errors, `xcodebuild build test`, fails on any warning in the log.

**Status:** CI PASS — 0 warnings; 46 Core tests (incl. real login-keychain round trip) + 2 app tests.

**Decided:** see DECISIONS.md #1–12.

**Next — Phase 2 (Connectivity):** `DatabaseDriver` protocol; MySQLNIO / PostgresNIO drivers; SSH tunnels via Citadel (fallback `ssh -L`); TLS; connection test; docker-compose integration tests (MySQL 8, MariaDB 11, Postgres 16) that skip without Docker.

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
