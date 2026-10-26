import Foundation

/// A successful fuzzy match.
public struct FuzzyMatch: Sendable, Hashable {
    /// Higher is better. 0 for an empty query.
    public var score: Int
    /// Indices into the candidate string of the matched characters, ascending (for highlighting).
    public var matchedIndices: [String.Index]

    public init(score: Int, matchedIndices: [String.Index]) {
        self.score = score
        self.matchedIndices = matchedIndices
    }
}

/// Subsequence ("fzf-style") matching for the quick switcher and filters.
///
/// The query's characters (whitespace ignored) must appear in the candidate in order,
/// case-insensitively. Among all possible alignments the best-scoring one is chosen:
/// - bonus for matching at the start of the candidate, after a separator
///   (`_ . space - / : \`) or at a camelCase hump;
/// - bonus for consecutive matched characters;
/// - penalty for gaps between matches (and a small one for skipping leading characters).
public enum FuzzyMatcher {
    private static let matchBase = 16
    private static let startBonus = 20
    private static let separatorBonus = 16
    private static let camelBonus = 14
    private static let consecutiveBonus = 12
    private static let gapStart = 5
    private static let gapExtend = 1
    private static let leadingPenaltyCap = 8
    private static let none = Int.min / 2

    /// Scores `candidate` against `query`; `nil` if the query is not a subsequence.
    /// An empty (or all-whitespace) query matches everything with score 0 and no indices.
    public static func score(query: String, candidate: String) -> FuzzyMatch? {
        let q = query.filter { !$0.isWhitespace }.map(fold)
        if q.isEmpty { return FuzzyMatch(score: 0, matchedIndices: []) }

        let chars = Array(candidate)
        let n = chars.count, m = q.count
        if m > n { return nil }
        let folded = chars.map(fold)

        // Cheap reject: greedy subsequence test.
        var qi = 0
        for c in folded where qi < m && c == q[qi] { qi += 1 }
        if qi < m { return nil }

        var bonus = [Int](repeating: 0, count: n)
        for j in 0..<n { bonus[j] = positionBonus(chars, j) }

        // dp[i*n+j]: best score with q[i] matched at j. parent holds the column used for q[i-1].
        var dp = [Int](repeating: none, count: m * n)
        var parent = [Int](repeating: -1, count: m * n)
        for j in 0..<n where folded[j] == q[0] {
            dp[j] = matchBase + bonus[j] - min(j, leadingPenaltyCap)
        }
        if m > 1 {
            for i in 1..<m {
                var gapBest = none, gapFrom = -1
                let prev = (i - 1) * n, cur = i * n
                for j in i..<n {
                    // Age the running best-with-gap by one skipped char, then fold in k = j-2.
                    if gapBest > none { gapBest -= gapExtend }
                    if j >= 2, dp[prev + j - 2] > none, dp[prev + j - 2] - gapStart > gapBest {
                        gapBest = dp[prev + j - 2] - gapStart
                        gapFrom = j - 2
                    }
                    guard folded[j] == q[i] else { continue }
                    var best = none, from = -1
                    if dp[prev + j - 1] > none {
                        best = dp[prev + j - 1] + consecutiveBonus
                        from = j - 1
                    }
                    if gapBest > best { best = gapBest; from = gapFrom }
                    if best > none {
                        dp[cur + j] = best + matchBase + bonus[j]
                        parent[cur + j] = from
                    }
                }
            }
        }

        let last = (m - 1) * n
        var bestJ = -1, bestScore = none
        for j in 0..<n where dp[last + j] > bestScore {
            bestScore = dp[last + j]
            bestJ = j
        }
        guard bestJ >= 0 else { return nil }

        var columns = [Int](repeating: 0, count: m)
        var j = bestJ
        for i in stride(from: m - 1, through: 0, by: -1) {
            columns[i] = j
            j = parent[i * n + j]
        }
        let indices = Array(candidate.indices)
        return FuzzyMatch(score: bestScore, matchedIndices: columns.map { indices[$0] })
    }

    /// Filters and ranks `items` by their `key` string, best first. Ties keep the original
    /// order (stable). An empty query returns the first `limit` items in original order with
    /// score 0. A `limit` of 0 or less returns nothing.
    public static func rank<T>(
        _ items: [T],
        query: String,
        key: (T) -> String,
        limit: Int
    ) -> [(T, FuzzyMatch)] {
        guard limit > 0 else { return [] }
        var scored: [(offset: Int, match: FuzzyMatch)] = []
        scored.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            if let match = score(query: query, candidate: key(item)) { scored.append((offset, match)) }
        }
        scored.sort { a, b in
            a.match.score != b.match.score ? a.match.score > b.match.score : a.offset < b.offset
        }
        return scored.prefix(limit).map { (items[$0.offset], $0.match) }
    }

    // MARK: Helpers

    private static func fold(_ c: Character) -> Character {
        if let a = c.asciiValue {
            return (a >= 65 && a <= 90) ? Character(UnicodeScalar(a + 32)) : c
        }
        let lower = c.lowercased()
        return lower.count == 1 ? Character(lower) : c
    }

    private static func isSeparator(_ c: Character) -> Bool {
        c == "_" || c == "." || c == " " || c == "-" || c == "/" || c == ":" || c == "\\"
    }

    private static func positionBonus(_ chars: [Character], _ j: Int) -> Int {
        if j == 0 { return startBonus }
        let prev = chars[j - 1], cur = chars[j]
        if isSeparator(prev) { return separatorBonus }
        if prev.isLowercase && cur.isUppercase { return camelBonus }
        return 0
    }
}
