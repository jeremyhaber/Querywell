import AppKit
import QuerywellCore
import SwiftUI

/// Header strip above Structure / Indexes / Relations: engine, collation, estimated rows, sizes.
struct TableInfoStrip: View {
    let info: TableInfo

    var body: some View {
        HStack(spacing: 20) {
            if let engine = info.engine { item("Engine", engine) }
            if let collation = info.collation { item("Collation", collation) }
            if let rows = info.estimatedRows { item("Rows", "~\(CompactCount.grouped(rows)) (est.)") }
            if let data = info.dataBytes { item("Data", Self.bytes(data)) }
            if let index = info.indexBytes { item("Indexes", Self.bytes(index)) }
            if let comment = info.comment, !comment.isEmpty { item("Comment", comment) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
        .accessibilityElement(children: .contain)
    }

    private func item(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}

private struct StructureLoadState: View {
    @Bindable var model: TableDataModel

    var body: some View {
        Group {
            if let message = model.structureFailure {
                ContentMessage(symbol: "exclamationmark.triangle", title: "Couldn't read the table structure", detail: message)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Reading structure…").foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ContentMessage: View {
    var symbol: String
    var title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
            Text(title).font(.system(size: 14, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).textSelection(.enabled).multilineTextAlignment(.center) }
        }
        .padding(24)
        .frame(maxWidth: 480)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Structure

struct StructureTableView: View {
    @Bindable var model: TableDataModel
    @State private var showCreate = false

    private struct Row: Identifiable {
        let column: ColumnDefinition
        let keys: String
        var id: String { column.name }
    }

    var body: some View {
        if let structure = model.structure {
            VStack(spacing: 0) {
                TableInfoStrip(info: structure.info)
                Table(rows(structure)) {
                    TableColumn("#") { Text("\($0.column.ordinal)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary) }
                        .width(min: 28, ideal: 34, max: 50)
                    TableColumn("Name") { Text($0.column.name).font(.system(size: 13, weight: .medium)) }
                        .width(min: 100, ideal: 160)
                    TableColumn("Type") { Text($0.column.fullType).font(.system(size: 12, design: .monospaced)) }
                        .width(min: 100, ideal: 170)
                    TableColumn("Nullable") { Text($0.column.isNullable ? "YES" : "NO").font(.system(size: 12, design: .monospaced)) }
                        .width(min: 56, ideal: 66, max: 80)
                    TableColumn("Default") { row in
                        if let d = row.column.defaultExpression {
                            Text(d).font(.system(size: 12, design: .monospaced))
                        } else {
                            Text("—").foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .width(min: 70, ideal: 120)
                    TableColumn("Key") { Text($0.keys).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.accentText) }
                        .width(min: 56, ideal: 90)
                    TableColumn("Extra") { Text($0.column.isAutoIncrement ? "auto_increment" : "").font(.system(size: 12, design: .monospaced)) }
                        .width(min: 60, ideal: 110)
                    TableColumn("Collation") { Text($0.column.collation ?? "").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary) }
                        .width(min: 80, ideal: 150)
                    TableColumn("Comment") { Text($0.column.comment ?? "").font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
                }
                .accessibilityLabel("Columns of \(model.table.name)")
                createStatement(structure)
            }
        } else {
            StructureLoadState(model: model)
        }
    }

    private func rows(_ structure: TableStructure) -> [Row] {
        structure.columns.map { Row(column: $0, keys: Self.keys(for: $0, in: structure)) }
    }

    /// PK / UNI / MUL / FK, MySQL `Key`-style.
    static func keys(for column: ColumnDefinition, in structure: TableStructure) -> String {
        var out: [String] = []
        let name = column.name.lowercased()
        if column.isPrimaryKey || structure.primaryKey.contains(where: { $0.lowercased() == name }) {
            out.append("PK")
        } else if let index = structure.indexes.first(where: { $0.columns.first?.lowercased() == name }) {
            out.append(index.isUnique ? "UNI" : "MUL")
        }
        if structure.foreignKeys.contains(where: { $0.columns.contains { $0.lowercased() == name } }) { out.append("FK") }
        return out.joined(separator: " ")
    }

    @ViewBuilder
    private func createStatement(_ structure: TableStructure) -> some View {
        if let create = structure.createStatement, !create.isEmpty {
            DisclosureGroup(isExpanded: $showCreate) {
                VStack(alignment: .trailing, spacing: 6) {
                    ScrollView {
                        Text(create)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 220)
                    .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(create, forType: .string)
                    }
                    .controlSize(.small)
                }
                .padding(.top, 6)
            } label: {
                Text("CREATE statement").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.background)
            .overlay(alignment: .top) { Theme.separator.frame(height: 1) }
        }
    }
}

// MARK: - Indexes

struct IndexesTableView: View {
    @Bindable var model: TableDataModel

    var body: some View {
        if let structure = model.structure {
            VStack(spacing: 0) {
                TableInfoStrip(info: structure.info)
                if structure.indexes.isEmpty {
                    ContentMessage(symbol: "list.bullet.indent", title: "No indexes", detail: "This table has no indexes.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(structure.indexes) {
                        TableColumn("Name") { Text($0.name).font(.system(size: 13, weight: .medium)) }
                            .width(min: 100, ideal: 180)
                        TableColumn("Columns") { Text($0.columns.joined(separator: ", ")).font(.system(size: 12, design: .monospaced)) }
                            .width(min: 120, ideal: 240)
                        TableColumn("Unique") { Text($0.isUnique ? "Yes" : "No").foregroundStyle($0.isUnique ? Theme.text : Theme.textTertiary) }
                            .width(min: 50, ideal: 70, max: 90)
                        TableColumn("Primary") { Text($0.isPrimary ? "Yes" : "No").foregroundStyle($0.isPrimary ? Theme.text : Theme.textTertiary) }
                            .width(min: 50, ideal: 70, max: 90)
                        TableColumn("Method") { Text($0.method ?? "").font(.system(size: 12, design: .monospaced)) }
                            .width(min: 60, ideal: 90)
                        TableColumn("Predicate") { Text($0.predicate ?? "").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary) }
                    }
                    .accessibilityLabel("Indexes of \(model.table.name)")
                }
            }
        } else {
            StructureLoadState(model: model)
        }
    }
}

// MARK: - Relations

struct RelationsView: View {
    @Bindable var model: TableDataModel
    var open: (TableRef) -> Void

    var body: some View {
        if let structure = model.structure {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("References", subtitle: "Foreign keys on \(model.table.name)", empty: "This table has no foreign keys.",
                            keys: structure.foreignKeys, outgoing: true)
                    section("Referenced by", subtitle: "Foreign keys in other tables that point here", empty: "No other table references this one.",
                            keys: structure.referencedBy, outgoing: false)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            StructureLoadState(model: model)
        }
    }

    @ViewBuilder
    private func section(_ title: String, subtitle: String, empty: String, keys: [ForeignKeyDefinition], outgoing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                CaptionLabel(title)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            if keys.isEmpty {
                Text(empty).font(.system(size: 13)).foregroundStyle(Theme.textTertiary).padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { index, fk in
                        row(fk, outgoing: outgoing)
                        if index < keys.count - 1 { Theme.gridRule.frame(height: 1) }
                    }
                }
                .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
            }
        }
    }

    private func row(_ fk: ForeignKeyDefinition, outgoing: Bool) -> some View {
        let target = outgoing ? fk.referenced : (fk.table ?? fk.referenced)
        let own = fk.columns.joined(separator: ", ")
        let theirs = fk.referencedColumns.joined(separator: ", ")
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if outgoing {
                        Text(own).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                        link(target, columns: theirs)
                    } else {
                        link(target, columns: own)
                        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                        Text(theirs).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    }
                }
                Text(fk.name).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("ON UPDATE \(fk.onUpdate ?? "NO ACTION")")
                Text("ON DELETE \(fk.onDelete ?? "NO ACTION")")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private func link(_ ref: TableRef, columns: String) -> some View {
        Button {
            open(ref)
        } label: {
            Text("\(ref.schema == model.table.schema ? ref.name : ref.description)(\(columns)) ↗")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.accentText)
        }
        .buttonStyle(.plain)
        .help("Open \(ref.name)")
        .accessibilityLabel("Open table \(ref.name)")
    }
}
