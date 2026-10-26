import Foundation

/// One distinct rewrite performed (or one name found, for the scanner).
public struct CollationRewrite: Hashable, Sendable {
    public var kind: CollationNameKind
    public var from: String
    public var to: String
}

/// Streaming, DDL-only charset/collation rewriter for SQL dump text (decisions #17, PROGRESS "Scope A").
///
/// Feed raw (already decompressed) dump bytes in chunks of any size and write whatever `feed` returns;
/// call `finish()` at the end. Memory is bounded: only DDL statements (CREATE / ALTER / SET and
/// versioned `/*! … */` statements) are buffered, one at a time; INSERT statements, `COPY` data,
/// comments and anything unrecognised stream through byte-for-byte. String literals, quoted
/// identifiers and ordinary comments inside DDL are never altered either, so a column default of
/// `'utf8mb4_0900_ai_ci'` or a `COMMENT 'COLLATE x'` survives.
///
/// Rewritten constructs: `COLLATE [=] x`, `[DEFAULT] CHARSET [=] x`, `CHARACTER SET [=] x` (including
/// inside `/*!40100 … */`), `SET NAMES x [COLLATE y]`, `SET [@@]character_set_* = x`,
/// `SET [@@]collation_* = x`, and character-set introducers (`_utf8mb3'…'`). Variable references
/// (`= @saved_cs_client`) are left alone.
///
/// Not handled: gzip (decompress first), Postgres dumps, `NO_BACKSLASH_ESCAPES`-style literals, DDL
/// statements larger than `maxBufferedStatementBytes` (passed through unmodified and counted in
/// `oversizedStatementCount`). Row data is never transcoded.
///
/// Not thread-safe; use one instance per stream.
public final class CollationRewriter {
    public let mapping: CollationMapping
    private let engine: DumpStreamEngine
    private let stats: Stats

    private final class Stats {
        var counts: [CollationRewrite: Int] = [:]
    }

    public init(mapping: CollationMapping, maxBufferedStatementBytes: Int = 8 * 1024 * 1024) {
        self.mapping = mapping
        let stats = Stats()
        self.stats = stats
        self.engine = DumpStreamEngine(emitOutput: true, maxBufferedStatementBytes: maxBufferedStatementBytes) { stmt in
            DDLNameRewriter.rewrite(stmt) { kind, name in
                let mapped = kind == .charset ? mapping.mapCharset(name) : mapping.mapCollation(name)
                if let mapped {
                    stats.counts[CollationRewrite(kind: kind, from: name.lowercased(), to: mapped), default: 0] += 1
                }
                return mapped
            }
        }
    }

    /// Consumes a chunk and returns the rewritten bytes that are ready. Output may lag input by a few
    /// bytes (look-ahead at statement starts); `finish()` flushes the remainder.
    public func feed(_ chunk: Data) -> Data {
        engine.feed(chunk)
        return engine.takeOutput()
    }

    /// Flushes any buffered statement / look-ahead bytes. Call once, after the last chunk.
    public func finish() -> Data {
        engine.finish()
        return engine.takeOutput()
    }

    /// Convenience for small inputs and tests.
    public func rewrite(_ data: Data) -> Data {
        var out = feed(data)
        out.append(finish())
        return out
    }

    /// Distinct rewrites performed so far with their occurrence counts.
    public var rewriteCounts: [CollationRewrite: Int] { stats.counts }
    public var totalRewrites: Int { stats.counts.values.reduce(0, +) }
    public var oversizedStatementCount: Int { engine.oversizedStatements }
}

/// Charsets and collations a dump uses (as seen in DDL), with occurrence counts. Lower-case names.
public struct CollationUsage: Equatable, Sendable {
    public var charsets: [String: Int] = [:]
    public var collations: [String: Int] = [:]

    public init(charsets: [String: Int] = [:], collations: [String: Int] = [:]) {
        self.charsets = charsets
        self.collations = collations
    }

    /// Collations used by the dump that the target server does not list (e.g. from `SHOW COLLATION`).
    public func unsupportedCollations(supportedBy server: Set<String>) -> [String] {
        collations.keys.filter { !server.contains($0) }.sorted()
    }

    public func unsupportedCharsets(supportedBy server: Set<String>) -> [String] {
        charsets.keys.filter { !server.contains($0) }.sorted()
    }
}

/// Streams a dump (same rules as ``CollationRewriter``, no output) and reports which charsets and
/// collations its DDL uses — for the import pre-scan ("this file uses X which the server doesn't support").
public final class CollationScanner {
    private let engine: DumpStreamEngine
    private let box: Box

    private final class Box {
        var usage = CollationUsage()
    }

    public init(maxBufferedStatementBytes: Int = 8 * 1024 * 1024) {
        let box = Box()
        self.box = box
        self.engine = DumpStreamEngine(emitOutput: false, maxBufferedStatementBytes: maxBufferedStatementBytes) { stmt in
            _ = DDLNameRewriter.rewrite(stmt) { kind, name in
                let key = name.lowercased()
                switch kind {
                case .charset: box.usage.charsets[key, default: 0] += 1
                case .collation: box.usage.collations[key, default: 0] += 1
                }
                return nil
            }
            return nil
        }
    }

    public func feed(_ chunk: Data) { engine.feed(chunk) }
    public func finish() { engine.finish() }

    /// Names seen so far (complete after `finish()`).
    public var usage: CollationUsage { box.usage }
    public var oversizedStatementCount: Int { engine.oversizedStatements }

    /// One-shot scan.
    public static func scan(_ data: Data) -> CollationUsage {
        let s = CollationScanner()
        s.feed(data)
        s.finish()
        return s.usage
    }
}
