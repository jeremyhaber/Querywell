# Progress

## Phase 1 — Foundation ✅ (2026-10-26)

**Built**
- XcodeGen `project.yml` → macOS 14 app target `Querywell` (SwiftUI placeholder launcher + Settings), `QuerywellTests`, scheme runs app + Core tests. Hardened runtime on, sandbox off, ad-hoc local signing, warnings as errors, Swift 6 strict concurrency.
- `Packages/Core` (`QuerywellCore`): `ConnectionProfile` (engine, host/port/user, default DB, folder, color tag, SSH tunnel config with key/agent/password, TLS modes, read-only, timestamps — no secret fields), tolerant versioned decoding, `ConnectionValidator`, `ConnectionFolder`, `ConnectionRepository` actor (atomic, transactional JSON persistence in Application Support), `SecretStore` protocol with `KeychainSecretStore` (Security framework) and `InMemorySecretStore`.
- `scripts/ci.sh` — the phase gate: xcodegen, `swift build/test` with warnings-as-errors, `xcodebuild build test`, fails on any warning in the log.

**Status:** CI PASS — 0 warnings; 46 Core tests (incl. real login-keychain round trip) + 2 app tests.

**Decided:** see DECISIONS.md #1–12.

**Next — Phase 2 (Connectivity):** `DatabaseDriver` protocol; MySQLNIO / PostgresNIO drivers; SSH tunnels via Citadel (fallback `ssh -L`); TLS; connection test; docker-compose integration tests (MySQL 8, MariaDB 11, Postgres 16) that skip without Docker.
