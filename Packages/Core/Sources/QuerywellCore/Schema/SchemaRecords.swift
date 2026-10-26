import Foundation

/// Name-based access to query results, so inspectors don't depend on column positions and
/// don't care about the case information_schema reports column names in.
struct Record: Sendable {
    let names: [String: Int]
    let cells: [DatabaseValue]

    func value(_ name: String) -> DatabaseValue {
        guard let index = names[name.lowercased()], index < cells.count else { return .null }
        return cells[index]
    }

    func string(_ name: String) -> String? { Record.string(from: value(name)) }

    func int(_ name: String) -> Int64? { Record.int(from: value(name)) }

    func bool(_ name: String) -> Bool? {
        switch value(name) {
        case .bool(let b): return b
        case .integer(let i): return i != 0
        case .unsignedInteger(let u): return u != 0
        case .text(let s): return ["t", "true", "1", "yes", "y"].contains(s.lowercased())
        default: return nil
        }
    }

    static func string(from value: DatabaseValue) -> String? {
        switch value {
        case .null: return nil
        case .text(let s): return s
        case .bytes(let d): return String(data: d, encoding: .utf8)
        case .integer(let i): return String(i)
        case .unsignedInteger(let u): return String(u)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        }
    }

    static func int(from value: DatabaseValue) -> Int64? {
        switch value {
        case .integer(let i): return i
        case .unsignedInteger(let u): return Int64(exactly: u)
        case .double(let d): return Int64(exactly: d.rounded())
        case .text(let s): return Int64(s)
        case .bytes(let d): return String(data: d, encoding: .utf8).flatMap { Int64($0) }
        default: return nil
        }
    }
}

extension QueryResult {
    var records: [Record] {
        var names: [String: Int] = [:]
        for (index, column) in columns.enumerated() where names[column.name.lowercased()] == nil {
            names[column.name.lowercased()] = index
        }
        return rows.map { Record(names: names, cells: $0) }
    }
}

extension String {
    /// `nil` for an empty string (comments, defaults that the server reports as '').
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
