import Foundation

/// Parsing of server version banners.
enum ServerVersion {
    struct Parsed: Equatable, Sendable {
        var engine: DatabaseEngine
        var major: Int
        var minor: Int
        var patch: Int
    }

    /// `SELECT VERSION()` on MySQL / MariaDB.
    /// Handles "8.4.3", "11.4.2-MariaDB-ubu2404", and MariaDB's replication-compat
    /// prefix "5.5.5-10.11.6-MariaDB".
    static func parseMySQL(_ banner: String) -> Parsed {
        let isMaria = banner.range(of: "mariadb", options: .caseInsensitive) != nil
        var text = Substring(banner)
        if text.hasPrefix("5.5.5-") { text = text.dropFirst(6) }
        let nums = leadingNumbers(text)
        return Parsed(engine: isMaria ? .mariadb : .mysql, major: nums.0, minor: nums.1, patch: nums.2)
    }

    /// `SHOW server_version` on Postgres, e.g. "16.4 (Debian 16.4-1.pgdg120+2)", "17beta1", "9.6.24".
    static func parsePostgres(_ banner: String) -> Parsed {
        let first = banner.split(separator: " ").first ?? Substring(banner)
        let nums = leadingNumbers(first)
        return Parsed(engine: .postgresql, major: nums.0, minor: nums.1, patch: nums.2)
    }

    /// Reads up to three dot-separated integers from the start of `text`, ignoring any
    /// non-numeric suffix ("17beta1" -> 17, 0, 0).
    private static func leadingNumbers(_ text: Substring) -> (Int, Int, Int) {
        var out = [0, 0, 0]
        var index = 0
        var current = ""
        loop: for ch in text {
            if ch.isASCII, ch.isNumber {
                current.append(ch)
            } else if ch == ".", !current.isEmpty, index < 2 {
                out[index] = Int(current) ?? 0
                current = ""
                index += 1
            } else {
                break loop
            }
        }
        if !current.isEmpty { out[index] = Int(current) ?? 0 }
        return (out[0], out[1], out[2])
    }
}
