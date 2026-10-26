import Foundation

/// Removes secrets from SQL before it is stored (history, snippets, logs).
public enum SecretRedactor {
    private static let string = #"'(?:[^'\\]|\\.|'')*'|"(?:[^"\\]|\\.|"")*""#

    private static let rules: [(NSRegularExpression, String)] = {
        func rx(_ pattern: String) -> NSRegularExpression {
            // The patterns are constants; failure to compile is a programming error caught by tests.
            try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])  // swiftlint:disable:this force_try
        }
        return [
            // CREATE USER x IDENTIFIED BY 'pw' / IDENTIFIED WITH plugin BY 'pw' / ... BY PASSWORD 'hash'
            (rx(#"(\bIDENTIFIED\s+(?:WITH\s+\w+\s+)?BY\s+(?:PASSWORD\s+)?)(?:"# + string + ")"), "$1'***'"),
            // PASSWORD('pw'), OLD_PASSWORD('pw')
            (rx(#"(\b(?:OLD_)?PASSWORD\s*\(\s*)(?:"# + string + #")(\s*\))"#), "$1'***'$2"),
            // password = 'pw', user_pass = "pw", passwd := 'pw'
            (rx(#"(\b(?:password|passwd|pwd|user_pass|secret)\s*:?=\s*)(?:"# + string + ")"), "$1'***'"),
            // Postgres: CREATE ROLE x PASSWORD 'pw' / ENCRYPTED PASSWORD 'pw'
            (rx(#"(\bPASSWORD\s+)(?:"# + string + ")"), "$1'***'"),
        ]
    }()

    public static func redact(_ sql: String) -> String {
        var out = sql
        for (regex, template) in rules {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: template)
        }
        return out
    }
}
