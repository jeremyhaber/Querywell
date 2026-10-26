import Foundation

/// Compact row-count and number formatting for the sidebar and the grid footer. Locale-independent
/// so the same table always reads the same (`2.1k`, `38k`, `1.2M`).
public enum CompactCount {
    /// `212`, `1.4k`, `38k`, `1.2M`, `3B`. Negative values clamp to 0.
    public static func string(_ value: Int64) -> String {
        let n = max(value, 0)
        if n < 1_000 { return String(n) }
        return scaled(Double(n), units: [(1_000, "k"), (1_000_000, "M"), (1_000_000_000, "B")])
    }

    private static func scaled(_ n: Double, units: [(Double, String)]) -> String {
        var index = 0
        for (i, unit) in units.enumerated() where n >= unit.0 { index = i }
        var (divisor, suffix) = units[index]
        var scaled = n / divisor
        // 999_950 rounds to "1000k": promote to the next unit instead.
        if scaled.rounded() >= 1000, index + 1 < units.count {
            (divisor, suffix) = units[index + 1]
            scaled = n / divisor
        }
        if scaled < 10 {
            let tenths = (scaled * 10).rounded() / 10
            if tenths >= 10 { return "10" + suffix }
            let whole = Int(tenths)
            let frac = Int((tenths * 10).rounded()) % 10
            return frac == 0 ? "\(whole)\(suffix)" : "\(whole).\(frac)\(suffix)"
        }
        return "\(Int(scaled.rounded()))\(suffix)"
    }

    /// `2,148` — grouping with commas regardless of locale.
    public static func grouped(_ value: Int64) -> String {
        let digits = String(value.magnitude)
        var out = ""
        for (offset, ch) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (value < 0 ? "-" : "") + String(out.reversed())
    }
}

/// The grid footer's "Rows 1–500 of 2,148" arithmetic.
public struct PageInfo: Hashable, Sendable {
    public var offset: Int
    public var rowCount: Int
    public var pageSize: Int
    /// Total matching rows when known; an estimate unless ``totalIsExact``.
    public var total: Int64?
    public var totalIsExact: Bool

    public init(offset: Int, rowCount: Int, pageSize: Int, total: Int64? = nil, totalIsExact: Bool = false) {
        self.offset = max(offset, 0)
        self.rowCount = max(rowCount, 0)
        self.pageSize = max(pageSize, 1)
        self.total = total
        self.totalIsExact = totalIsExact
    }

    public var firstRow: Int { rowCount == 0 ? 0 : offset + 1 }
    public var lastRow: Int { offset + rowCount }
    public var hasPrevious: Bool { offset > 0 }

    public var hasNext: Bool {
        if let total, totalIsExact { return Int64(offset + rowCount) < total }
        return rowCount >= pageSize
    }

    /// Offset of the last page; nil while the total is unknown.
    public var lastPageOffset: Int? {
        guard let total, total > 0 else { return total == nil ? nil : 0 }
        return Int((total - 1) / Int64(pageSize)) * pageSize
    }

    /// `Rows 1–500 of 2,148 (exact)` / `… of ~2,148 (est.)` / `… of …` while the count is pending.
    public var label: String {
        if rowCount == 0 { return total == 0 && totalIsExact ? "No rows" : "Rows 0" }
        var out = "Rows \(CompactCount.grouped(Int64(firstRow)))–\(CompactCount.grouped(Int64(lastRow))) of "
        if let total {
            out += totalIsExact ? "\(CompactCount.grouped(total)) (exact)" : "~\(CompactCount.grouped(total)) (est.)"
        } else {
            out += "…"
        }
        return out
    }
}
