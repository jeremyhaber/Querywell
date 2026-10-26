import Foundation
import MySQLNIO
import NIOCore

/// Column metadata distilled from a `ColumnDefinition41` packet (whose initialiser isn't
/// public, which would make the mapping untestable).
struct MySQLColumnMeta: Sendable, Equatable {
    var name: String
    var table: String
    var typeCode: UInt8
    var flags: UInt16
    var charset: UInt8

    init(name: String, table: String = "", typeCode: UInt8, flags: UInt16 = 0, charset: UInt8 = 45) {
        self.name = name
        self.table = table
        self.typeCode = typeCode
        self.flags = flags
        self.charset = charset
    }

    init(_ def: MySQLProtocol.ColumnDefinition41) {
        self.init(
            name: def.name,
            table: def.orgTable.isEmpty ? def.table : def.orgTable,
            typeCode: def.columnType.rawValue,
            flags: def.flags.rawValue,
            charset: def.characterSet.rawValue
        )
    }

    // Column type codes (protocol constants).
    enum Code {
        static let decimal: UInt8 = 0x00, tiny: UInt8 = 0x01, short: UInt8 = 0x02, long: UInt8 = 0x03
        static let float: UInt8 = 0x04, double: UInt8 = 0x05, null: UInt8 = 0x06, timestamp: UInt8 = 0x07
        static let longlong: UInt8 = 0x08, int24: UInt8 = 0x09, date: UInt8 = 0x0a, time: UInt8 = 0x0b
        static let datetime: UInt8 = 0x0c, year: UInt8 = 0x0d, newdate: UInt8 = 0x0e, varchar: UInt8 = 0x0f
        static let bit: UInt8 = 0x10, timestamp2: UInt8 = 0x11, datetime2: UInt8 = 0x12, time2: UInt8 = 0x13
        static let json: UInt8 = 0xf5, newdecimal: UInt8 = 0xf6, `enum`: UInt8 = 0xf7, set: UInt8 = 0xf8
        static let tinyBlob: UInt8 = 0xf9, mediumBlob: UInt8 = 0xfa, longBlob: UInt8 = 0xfb, blob: UInt8 = 0xfc
        static let varString: UInt8 = 0xfd, string: UInt8 = 0xfe, geometry: UInt8 = 0xff
    }

    static let notNullFlag: UInt16 = 0x0001
    static let unsignedFlag: UInt16 = 0x0020
    static let enumFlag: UInt16 = 0x0100
    static let setFlag: UInt16 = 0x0800
    /// Character set id 63 = `binary`.
    static let binaryCharset: UInt8 = 63

    var isUnsigned: Bool { flags & Self.unsignedFlag != 0 }
    var isBinaryCharset: Bool { charset == Self.binaryCharset }

    /// Lowercased engine type name, e.g. "bigint", "varchar", "longtext".
    var typeName: String {
        let binary = isBinaryCharset
        switch typeCode {
        case Code.tiny: return "tinyint"
        case Code.short: return "smallint"
        case Code.int24: return "mediumint"
        case Code.long: return "int"
        case Code.longlong: return "bigint"
        case Code.decimal, Code.newdecimal: return "decimal"
        case Code.float: return "float"
        case Code.double: return "double"
        case Code.null: return "null"
        case Code.timestamp, Code.timestamp2: return "timestamp"
        case Code.date, Code.newdate: return "date"
        case Code.time, Code.time2: return "time"
        case Code.datetime, Code.datetime2: return "datetime"
        case Code.year: return "year"
        case Code.bit: return "bit"
        case Code.json: return "json"
        case Code.enum: return "enum"
        case Code.set: return "set"
        case Code.tinyBlob: return binary ? "tinyblob" : "tinytext"
        case Code.mediumBlob: return binary ? "mediumblob" : "mediumtext"
        case Code.longBlob: return binary ? "longblob" : "longtext"
        case Code.blob: return binary ? "blob" : "text"
        case Code.varchar, Code.varString: return binary ? "varbinary" : "varchar"
        case Code.string:
            if flags & Self.enumFlag != 0 { return "enum" }
            if flags & Self.setFlag != 0 { return "set" }
            return binary ? "binary" : "char"
        case Code.geometry: return "geometry"
        default: return "unknown"
        }
    }

    var info: ColumnInfo {
        ColumnInfo(
            name: name,
            typeName: typeName,
            table: table.isEmpty ? nil : table,
            isNullable: flags & Self.notNullFlag == 0
        )
    }
}

enum MySQLValueMapping {
    /// Converts one text-protocol cell to a ``DatabaseValue`` using the column's type.
    static func value(_ cell: ByteBuffer?, column: MySQLColumnMeta) -> DatabaseValue {
        guard var buffer = cell else { return .null }
        let readable = buffer.readableBytes

        func bytes() -> DatabaseValue {
            .bytes(Data(buffer.readBytes(length: readable) ?? []))
        }
        func text() -> String? { buffer.getString(at: buffer.readerIndex, length: readable) }
        /// Text, unless it isn't valid UTF-8 (then the raw bytes are the only faithful form).
        func textOrBytes() -> DatabaseValue {
            if let s = text(), s.utf8.count == readable { return .text(s) }
            return bytes()
        }

        switch column.typeCode {
        case MySQLColumnMeta.Code.null:
            return .null
        case MySQLColumnMeta.Code.tiny, MySQLColumnMeta.Code.short, MySQLColumnMeta.Code.int24,
             MySQLColumnMeta.Code.long, MySQLColumnMeta.Code.longlong:
            guard let s = text() else { return bytes() }
            if column.isUnsigned {
                if let u = UInt64(s) { return .unsignedInteger(u) }
            } else if let i = Int64(s) {
                return .integer(i)
            }
            return .text(s)
        case MySQLColumnMeta.Code.float, MySQLColumnMeta.Code.double:
            guard let s = text() else { return bytes() }
            if let d = Double(s) { return .double(d) }
            return .text(s)
        case MySQLColumnMeta.Code.bit, MySQLColumnMeta.Code.geometry:
            return bytes()
        case MySQLColumnMeta.Code.tinyBlob, MySQLColumnMeta.Code.mediumBlob, MySQLColumnMeta.Code.longBlob,
             MySQLColumnMeta.Code.blob, MySQLColumnMeta.Code.varchar, MySQLColumnMeta.Code.varString,
             MySQLColumnMeta.Code.string:
            if column.isBinaryCharset,
               column.flags & (MySQLColumnMeta.enumFlag | MySQLColumnMeta.setFlag) == 0 {
                return bytes()
            }
            return textOrBytes()
        default:
            // decimal, date/time family, year, json, enum, set: exact server text.
            return textOrBytes()
        }
    }
}
