import Foundation

/// Formats a round-trip latency for display ("<1 ms", "38 ms", "1.2 s").
public enum LatencyFormatter {
    public static func string(for duration: Duration) -> String {
        let c = duration.components
        let ms = Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
        if ms < 1 { return "<1 ms" }
        if ms >= 999.5 {
            let seconds = (ms / 100).rounded() / 10
            return String(format: "%.1f s", seconds)
        }
        return "\(Int(ms.rounded())) ms"
    }
}
