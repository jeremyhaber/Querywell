import Foundation
import NIOCore

/// What we know about a Postgres type beyond the built-in table. Filled from `pg_type`
/// for OIDs we have never seen (enums, extension types, arrays of those).
struct PostgresTypeInfo: Sendable, Equatable {
    var name: String
    /// For arrays: the element type's OID (`typelem`), otherwise 0.
    var elementOID: UInt32
    /// `typcategory` ("A" = array, "R" = range, ...).
    var category: String
}

/// Decodes Postgres *binary* result cells into canonical Postgres *text* form.
///
/// PostgresNIO's extended-query path always asks for binary results, so there's no way to
/// get the server's own text rendering. This type reproduces it for the types a database
/// client meets in practice; anything unrecognised is shown as UTF-8 text when valid (which
/// is exactly right for enums, citext, ltree, domains over text, ...) and as bytes otherwise.
///
/// Rendering assumes `DateStyle = ISO` and `IntervalStyle = postgres`; the driver pins both
/// at connection start so this holds regardless of role/database defaults.
struct PostgresValueDecoder: Sendable {
    /// Session time zone, for `timestamptz`/`timetz` rendering.
    var timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!
    /// Learned types, keyed by OID.
    var extraTypes: [UInt32: PostgresTypeInfo] = [:]

    // MARK: OIDs

    enum OID {
        static let bool: UInt32 = 16, bytea: UInt32 = 17, char: UInt32 = 18, name: UInt32 = 19
        static let int8: UInt32 = 20, int2: UInt32 = 21, int4: UInt32 = 23, text: UInt32 = 25
        static let oid: UInt32 = 26, xid: UInt32 = 28, cid: UInt32 = 29
        static let json: UInt32 = 114, xml: UInt32 = 142
        static let cidr: UInt32 = 650, float4: UInt32 = 700, float8: UInt32 = 701
        static let unknown: UInt32 = 705, macaddr8: UInt32 = 774, money: UInt32 = 790
        static let macaddr: UInt32 = 829, inet: UInt32 = 869
        static let bpchar: UInt32 = 1042, varchar: UInt32 = 1043, date: UInt32 = 1082
        static let time: UInt32 = 1083, timestamp: UInt32 = 1114, timestamptz: UInt32 = 1184
        static let interval: UInt32 = 1186, timetz: UInt32 = 1266, bit: UInt32 = 1560, varbit: UInt32 = 1562
        static let numeric: UInt32 = 1700, refcursor: UInt32 = 1790, uuid: UInt32 = 2950
        static let jsonb: UInt32 = 3802, jsonpath: UInt32 = 4072
        static let int4range: UInt32 = 3904, numrange: UInt32 = 3906, tsrange: UInt32 = 3908
        static let tstzrange: UInt32 = 3910, daterange: UInt32 = 3912, int8range: UInt32 = 3926
    }

    /// Built-in `typname`s, as Postgres reports them.
    static let knownTypeNames: [UInt32: String] = [
        16: "bool", 17: "bytea", 18: "char", 19: "name", 20: "int8", 21: "int2", 23: "int4", 25: "text",
        26: "oid", 28: "xid", 29: "cid", 114: "json", 142: "xml", 650: "cidr", 700: "float4", 701: "float8",
        705: "unknown", 774: "macaddr8", 790: "money", 829: "macaddr", 869: "inet", 1042: "bpchar",
        1043: "varchar", 1082: "date", 1083: "time", 1114: "timestamp", 1184: "timestamptz",
        1186: "interval", 1266: "timetz", 1560: "bit", 1562: "varbit", 1700: "numeric", 1790: "refcursor",
        2950: "uuid", 3802: "jsonb", 4072: "jsonpath", 3904: "int4range", 3906: "numrange",
        3908: "tsrange", 3910: "tstzrange", 3912: "daterange", 3926: "int8range",
        // arrays
        1000: "_bool", 1001: "_bytea", 1002: "_char", 1003: "_name", 1016: "_int8", 1005: "_int2",
        1007: "_int4", 1009: "_text", 1028: "_oid", 199: "_json", 143: "_xml", 651: "_cidr",
        1021: "_float4", 1022: "_float8", 1041: "_inet", 1014: "_bpchar", 1015: "_varchar",
        1182: "_date", 1183: "_time", 1115: "_timestamp", 1185: "_timestamptz", 1187: "_interval",
        1270: "_timetz", 1561: "_bit", 1563: "_varbit", 1231: "_numeric", 2951: "_uuid", 3807: "_jsonb",
        1040: "_macaddr", 791: "_money",
    ]

    /// Array OID -> element OID for the built-in array types.
    static let builtinArrayElements: [UInt32: UInt32] = [
        1000: 16, 1001: 17, 1002: 18, 1003: 19, 1016: 20, 1005: 21, 1007: 23, 1009: 25, 1028: 26,
        199: 114, 143: 142, 651: 650, 1021: 700, 1022: 701, 1041: 869, 1014: 1042, 1015: 1043,
        1182: 1082, 1183: 1083, 1115: 1114, 1185: 1184, 1187: 1186, 1270: 1266, 1561: 1560,
        1563: 1562, 1231: 1700, 2951: 2950, 3807: 3802, 1040: 829, 791: 790,
    ]

    static let rangeSubtypes: [UInt32: UInt32] = [
        OID.int4range: OID.int4, OID.int8range: OID.int8, OID.numrange: OID.numeric,
        OID.tsrange: OID.timestamp, OID.tstzrange: OID.timestamptz, OID.daterange: OID.date,
    ]

    func typeName(for oid: UInt32) -> String {
        Self.knownTypeNames[oid] ?? extraTypes[oid]?.name ?? "oid:\(oid)"
    }

    func isKnown(_ oid: UInt32) -> Bool {
        Self.knownTypeNames[oid] != nil || extraTypes[oid] != nil
    }

    func elementOID(ofArray oid: UInt32) -> UInt32? {
        if let e = Self.builtinArrayElements[oid] { return e }
        if let info = extraTypes[oid], info.category == "A", info.elementOID != 0 { return info.elementOID }
        return nil
    }

    // MARK: DatabaseValue

    func value(_ cell: ByteBuffer?, oid: UInt32) -> DatabaseValue {
        guard var buf = cell else { return .null }
        switch oid {
        case OID.bool:
            return .bool((buf.readInteger(as: UInt8.self) ?? 0) != 0)
        case OID.int2:
            return buf.readInteger(as: Int16.self).map { .integer(Int64($0)) } ?? raw(cell)
        case OID.int4:
            return buf.readInteger(as: Int32.self).map { .integer(Int64($0)) } ?? raw(cell)
        case OID.int8:
            return buf.readInteger(as: Int64.self).map { .integer($0) } ?? raw(cell)
        case OID.oid, OID.xid, OID.cid:
            return buf.readInteger(as: UInt32.self).map { .integer(Int64($0)) } ?? raw(cell)
        case OID.float4:
            return buf.readInteger(as: UInt32.self).map { .double(Double(Float(bitPattern: $0))) } ?? raw(cell)
        case OID.float8:
            return buf.readInteger(as: UInt64.self).map { .double(Double(bitPattern: $0)) } ?? raw(cell)
        case OID.bytea:
            return .bytes(Data(buf.readableBytesView))
        default:
            if let s = text(cell, oid: oid) { return .text(s) }
            return raw(cell)
        }
    }

    private func raw(_ cell: ByteBuffer?) -> DatabaseValue {
        guard let cell else { return .null }
        return .bytes(Data(cell.readableBytesView))
    }

    // MARK: Text form

    /// Canonical Postgres text for a binary cell; `nil` if the bytes aren't decodable as that type.
    func text(_ cell: ByteBuffer?, oid: UInt32) -> String? {
        guard var b = cell else { return nil }
        switch oid {
        case OID.bool:
            return (b.readInteger(as: UInt8.self) ?? 0) != 0 ? "t" : "f"
        case OID.int2: return b.readInteger(as: Int16.self).map(String.init)
        case OID.int4: return b.readInteger(as: Int32.self).map(String.init)
        case OID.int8: return b.readInteger(as: Int64.self).map(String.init)
        case OID.oid, OID.xid, OID.cid: return b.readInteger(as: UInt32.self).map(String.init)
        case OID.float4:
            return b.readInteger(as: UInt32.self).map { Self.floatText(Double(Float(bitPattern: $0)), isFloat4: true, float: Float(bitPattern: $0)) }
        case OID.float8:
            return b.readInteger(as: UInt64.self).map { Self.floatText(Double(bitPattern: $0), isFloat4: false, float: 0) }
        case OID.bytea:
            return "\\x" + b.readableBytesView.map { String(format: "%02x", $0) }.joined()
        case OID.char:
            // "char" is a single raw byte.
            return b.readString(length: b.readableBytes)
        case OID.name, OID.text, OID.bpchar, OID.varchar, OID.xml, OID.json, OID.unknown, OID.refcursor:
            return b.readString(length: b.readableBytes)
        case OID.jsonb, OID.jsonpath:
            _ = b.readInteger(as: UInt8.self) // format version (1)
            return b.readString(length: b.readableBytes)
        case OID.uuid:
            guard let bytes = b.readBytes(length: 16) else { return nil }
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            let h = Array(hex)
            return String(h[0..<8]) + "-" + String(h[8..<12]) + "-" + String(h[12..<16])
                + "-" + String(h[16..<20]) + "-" + String(h[20..<32])
        case OID.numeric: return Self.numericText(&b)
        case OID.date:
            guard let days = b.readInteger(as: Int32.self) else { return nil }
            if days == Int32.max { return "infinity" }
            if days == Int32.min { return "-infinity" }
            return Self.dateText(daysSince2000: Int64(days))
        case OID.time:
            return b.readInteger(as: Int64.self).map { Self.timeText(micros: $0) }
        case OID.timetz:
            guard let t = b.readInteger(as: Int64.self), let z = b.readInteger(as: Int32.self) else { return nil }
            return Self.timeText(micros: t) + Self.offsetText(secondsEast: -Int(z))
        case OID.timestamp:
            guard let us = b.readInteger(as: Int64.self) else { return nil }
            if us == Int64.max { return "infinity" }
            if us == Int64.min { return "-infinity" }
            return Self.timestampText(micros: us)
        case OID.timestamptz:
            guard let us = b.readInteger(as: Int64.self) else { return nil }
            if us == Int64.max { return "infinity" }
            if us == Int64.min { return "-infinity" }
            let unix = Double(us) / 1_000_000 + 946_684_800
            let offset = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: unix.rounded(.down)))
            return Self.timestampText(micros: us + Int64(offset) * 1_000_000) + Self.offsetText(secondsEast: offset)
        case OID.interval:
            guard let t = b.readInteger(as: Int64.self), let d = b.readInteger(as: Int32.self),
                  let m = b.readInteger(as: Int32.self) else { return nil }
            return Self.intervalText(micros: t, days: Int(d), months: Int(m))
        case OID.macaddr, OID.macaddr8:
            return b.readableBytesView.map { String(format: "%02x", $0) }.joined(separator: ":")
        case OID.inet, OID.cidr:
            return Self.inetText(&b, isCIDR: oid == OID.cidr)
        case OID.bit, OID.varbit:
            guard let nbits = b.readInteger(as: Int32.self), let bytes = b.readBytes(length: b.readableBytes) else { return nil }
            var out = ""
            for i in 0..<Int(nbits) {
                let byte = bytes[i / 8]
                out.append((byte >> (7 - UInt8(i % 8))) & 1 == 1 ? "1" : "0")
            }
            return out
        case OID.money:
            guard let cents = b.readInteger(as: Int64.self) else { return nil }
            let abs = cents.magnitude
            let whole = String(abs / 100)
            var grouped = ""
            for (i, ch) in whole.reversed().enumerated() {
                if i > 0 && i % 3 == 0 { grouped.append(",") }
                grouped.append(ch)
            }
            return (cents < 0 ? "-" : "") + "$" + String(grouped.reversed()) + "." + String(format: "%02d", abs % 100)
        default:
            if let sub = Self.rangeSubtypes[oid] { return rangeText(&b, subtype: sub) }
            if let elem = elementOID(ofArray: oid) { return arrayText(&b, elementOID: elem) }
            // Unknown type (enum, citext, domain, extension...): binary == text for most of these.
            guard let s = b.getString(at: b.readerIndex, length: b.readableBytes),
                  s.utf8.count == b.readableBytes, !s.utf8.contains(0) else { return nil }
            return s
        }
    }

    // MARK: Arrays and ranges

    private func arrayText(_ b: inout ByteBuffer, elementOID: UInt32) -> String? {
        guard let ndim = b.readInteger(as: Int32.self),
              b.readInteger(as: Int32.self) != nil, // has-nulls flag
              b.readInteger(as: UInt32.self) != nil // element OID as sent by the server
        else { return nil }
        if ndim == 0 { return "{}" }
        var dims: [(size: Int, lower: Int)] = []
        for _ in 0..<Int(ndim) {
            guard let size = b.readInteger(as: Int32.self), let lower = b.readInteger(as: Int32.self) else { return nil }
            dims.append((Int(size), Int(lower)))
        }
        func level(_ d: Int) -> String? {
            var parts: [String] = []
            for _ in 0..<dims[d].size {
                if d + 1 < dims.count {
                    guard let inner = level(d + 1) else { return nil }
                    parts.append(inner)
                } else {
                    guard let len = b.readInteger(as: Int32.self) else { return nil }
                    if len < 0 { parts.append("NULL"); continue }
                    guard let slice = b.readSlice(length: Int(len)),
                          let t = text(slice, oid: elementOID) else { return nil }
                    parts.append(Self.quoteArrayElement(t))
                }
            }
            return "{" + parts.joined(separator: ",") + "}"
        }
        guard let body = level(0) else { return nil }
        let hasCustomBounds = dims.contains { $0.lower != 1 }
        if hasCustomBounds {
            let prefix = dims.map { "[\($0.lower):\($0.lower + $0.size - 1)]" }.joined()
            return prefix + "=" + body
        }
        return body
    }

    static func quoteArrayElement(_ s: String) -> String {
        let needs = s.isEmpty || s.caseInsensitiveCompare("NULL") == .orderedSame
            || s.contains(where: { "{},\"\\".contains($0) || $0.isWhitespace })
        guard needs else { return s }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    private func rangeText(_ b: inout ByteBuffer, subtype: UInt32) -> String? {
        guard let flags = b.readInteger(as: UInt8.self) else { return nil }
        if flags & 0x01 != 0 { return "empty" }
        let lowerInc = flags & 0x02 != 0, upperInc = flags & 0x04 != 0
        let lowerInf = flags & 0x08 != 0, upperInf = flags & 0x10 != 0
        func bound() -> String? {
            guard let len = b.readInteger(as: Int32.self), let slice = b.readSlice(length: Int(len)),
                  let t = text(slice, oid: subtype) else { return nil }
            return Self.quoteRangeBound(t)
        }
        var lower = "", upper = ""
        if !lowerInf { guard let l = bound() else { return nil }; lower = l }
        if !upperInf { guard let u = bound() else { return nil }; upper = u }
        return (lowerInc ? "[" : "(") + lower + "," + upper + (upperInc ? "]" : ")")
    }

    private static func quoteRangeBound(_ s: String) -> String {
        let needs = s.isEmpty || s.contains(where: { "(),[]\"\\".contains($0) || $0.isWhitespace })
        guard needs else { return s }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Scalars

    static func floatText(_ d: Double, isFloat4: Bool, float: Float) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        let s = isFloat4 ? "\(float)" : "\(d)"
        // Swift prints 5.0 as "5.0" and 1e20 as "1e+20"; Postgres prints "5" and "1e+20".
        if s.hasSuffix(".0") { return String(s.dropLast(2)) }
        return s
    }

    static func numericText(_ b: inout ByteBuffer) -> String? {
        guard let ndigits = b.readInteger(as: Int16.self), let weight = b.readInteger(as: Int16.self),
              let sign = b.readInteger(as: UInt16.self), let dscale = b.readInteger(as: Int16.self) else { return nil }
        if sign == 0xC000 { return "NaN" }
        if sign == 0xD000 { return "Infinity" }
        if sign == 0xF000 { return "-Infinity" }
        var digits: [Int] = []
        for _ in 0..<Int(ndigits) {
            guard let d = b.readInteger(as: Int16.self) else { return nil }
            digits.append(Int(d))
        }
        // Each base-10000 digit group; weight is the exponent of the first group.
        var intPart = ""
        if weight >= 0 {
            for i in 0...Int(weight) {
                let d = i < digits.count ? digits[i] : 0
                intPart += i == 0 ? String(d) : String(format: "%04d", d)
            }
        } else {
            intPart = "0"
        }
        var frac = ""
        if dscale > 0 {
            let startGroup = Int(weight) + 1 // index of first fractional group
            var i = startGroup
            while frac.count < Int(dscale) {
                let d = (i >= 0 && i < digits.count) ? digits[i] : 0
                frac += String(format: "%04d", d)
                i += 1
            }
            frac = String(frac.prefix(Int(dscale)))
        }
        let body = dscale > 0 ? intPart + "." + frac : intPart
        return sign == 0x4000 ? "-" + body : body
    }

    /// Howard Hinnant's civil-from-days, anchored at 2000-01-01.
    static func civil(daysSince2000 days: Int64) -> (year: Int64, month: Int, day: Int) {
        let z = days + 10957 + 719468 // days since 0000-03-01
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = Int(doy - (153 * mp + 2) / 5 + 1)
        let m = Int(mp < 10 ? mp + 3 : mp - 9)
        return (m <= 2 ? y + 1 : y, m, d)
    }

    static func dateText(daysSince2000 days: Int64) -> String {
        let c = civil(daysSince2000: days)
        let bc = c.year <= 0
        let year = bc ? 1 - c.year : c.year
        return String(format: "%04lld-%02d-%02d", year, c.month, c.day) + (bc ? " BC" : "")
    }

    static func timeText(micros: Int64) -> String {
        let total = micros
        let h = total / 3_600_000_000
        let m = (total / 60_000_000) % 60
        let s = (total / 1_000_000) % 60
        let us = total % 1_000_000
        return String(format: "%02lld:%02lld:%02lld", h, m, s) + fractionText(us)
    }

    static func timestampText(micros: Int64) -> String {
        let usPerDay: Int64 = 86_400_000_000
        var days = micros / usPerDay
        var rem = micros % usPerDay
        if rem < 0 { rem += usPerDay; days -= 1 }
        let c = civil(daysSince2000: days)
        let bc = c.year <= 0
        let year = bc ? 1 - c.year : c.year
        return String(format: "%04lld-%02d-%02d ", year, c.month, c.day) + timeText(micros: rem) + (bc ? " BC" : "")
    }

    private static func fractionText(_ us: Int64) -> String {
        guard us != 0 else { return "" }
        var f = String(format: "%06lld", us)
        while f.hasSuffix("0") { f.removeLast() }
        return "." + f
    }

    /// "+00", "-08", "+05:30", "+05:45:30" (Postgres drops zero minutes/seconds).
    static func offsetText(secondsEast: Int) -> String {
        let sign = secondsEast < 0 ? "-" : "+"
        let a = abs(secondsEast)
        let h = a / 3600, m = (a / 60) % 60, s = a % 60
        var out = sign + String(format: "%02d", h)
        if m != 0 || s != 0 { out += String(format: ":%02d", m) }
        if s != 0 { out += String(format: ":%02d", s) }
        return out
    }

    /// `IntervalStyle = postgres`, e.g. "1 year 2 mons 3 days 04:05:06.789".
    static func intervalText(micros: Int64, days: Int, months: Int) -> String {
        var parts: [String] = []
        var isBefore = false
        func field(_ value: Int, unit: String) {
            guard value != 0 else { return }
            let sign = value < 0 ? "-" : (isBefore ? "+" : "")
            let n = abs(value)
            parts.append("\(sign)\(n) \(unit)\(n == 1 ? "" : "s")")
            if value < 0 { isBefore = true }
        }
        field(months / 12, unit: "year")
        field(months % 12, unit: "mon")
        field(days, unit: "day")
        if micros != 0 || parts.isEmpty {
            let sign = micros < 0 ? "-" : (isBefore ? "+" : "")
            parts.append(sign + timeText(micros: Int64(micros.magnitude)))
        }
        return parts.joined(separator: " ")
    }

    static func inetText(_ b: inout ByteBuffer, isCIDR: Bool) -> String? {
        guard let family = b.readInteger(as: UInt8.self), let bits = b.readInteger(as: UInt8.self),
              b.readInteger(as: UInt8.self) != nil, let n = b.readInteger(as: UInt8.self),
              let bytes = b.readBytes(length: Int(n)) else { return nil }
        let isV4 = family == 2 // PGSQL_AF_INET
        var buffer = [CChar](repeating: 0, count: 64)
        let ok = bytes.withUnsafeBytes { raw -> Bool in
            inet_ntop(isV4 ? AF_INET : AF_INET6, raw.baseAddress, &buffer, 64) != nil
        }
        guard ok else { return nil }
        let addr = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let full = isV4 ? 32 : 128
        return (isCIDR || Int(bits) != full) ? "\(addr)/\(bits)" : addr
    }
}
