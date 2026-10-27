import QuerywellCore
import SwiftUI

/// Operations mode of a table tab: grouped sections, each with its own SQL preview and Apply button.
struct TableOperationsView: View {
    @Bindable var model: TableDataModel
    let workspace: ConnectionWorkspace
    @State private var ops = TableOperationsModel()

    var body: some View {
        Group {
            if !ops.isTable {
                ContentMessage(symbol: "tablecells", title: "Operations apply to tables", detail: "\(model.table.name) is a view.")
            } else if let error = ops.loadError, ops.current == nil {
                ContentMessage(symbol: "exclamationmark.triangle", title: "Couldn't read the table options", detail: error)
            } else if ops.current == nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Reading table options…").foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .task(id: model.table) {
            ops.attach(owner: model, workspace: workspace)
            await ops.load()
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if ops.isReadOnly {
                    WarningCallout(title: "Read-only connection", lines: ["Nothing here can run until “Read-only” is turned off in the connection's settings."],
                                   symbol: "lock.fill")
                }
                if ops.hasPendingEdits {
                    WarningCallout(title: "Unsaved edits", lines: ["Commit or discard the pending edits in Data before renaming, moving or emptying this table."])
                }
                moveCard
                optionsCard
                copyCard
                maintenanceCard
                deleteCard
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var locked: Bool { ops.isReadOnly || ops.running != nil }

    // MARK: Move / rename

    private var moveCard: some View {
        OperationCard(
            title: ops.isPostgres ? "Rename or move to schema" : "Rename or move to database",
            subtitle: "Change the table's name, or move it to \(ops.isPostgres ? "another schema" : "another database"). Privileges are not adjusted.",
            plan: ops.movePlan, status: ops.statuses[.move], applyTitle: "Apply", applyLabel: "Apply rename or move",
            busy: ops.running == .move, disabled: locked || ops.hasPendingEdits,
            apply: { Task { await ops.applyMove() } }
        ) {
            FormRow("Table") {
                HStack(spacing: 6) {
                    Picker("Target \(ops.isPostgres ? "schema" : "database")", selection: $ops.targetSchema) {
                        ForEach(ops.schemas, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180, alignment: .leading)
                    Text(".").foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
                    TextField("Table name", text: $ops.targetName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 240)
                        .accessibilityLabel("New table name")
                }
            }
        }
    }

    // MARK: Table options

    private var optionsCard: some View {
        OperationCard(
            title: "Table options", subtitle: nil, plan: ops.optionsPlan, status: ops.statuses[.options],
            applyTitle: "Apply", applyLabel: "Apply table options", busy: ops.running == .options, disabled: locked,
            apply: { Task { await ops.applyOptions() } }
        ) {
            FormRow("Comment") {
                TextField("Table comment", text: $ops.comment)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
                    .accessibilityLabel("Table comment")
            }
            if ops.isPostgres {
                FormRow("Tablespace") {
                    TextField("Default", text: $ops.tablespace)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 240)
                        .accessibilityLabel("Tablespace")
                }
                if let sequence = ops.current?.sequence {
                    FormRow("Next value") {
                        VStack(alignment: .leading, spacing: 3) {
                            TextField("Next value", text: $ops.autoIncrement)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13, design: .monospaced))
                                .frame(width: 160)
                                .accessibilityLabel("Next sequence value")
                            Text("Restarts \(sequence.schema).\(sequence.name)")
                                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            } else {
                FormRow("Storage engine") {
                    Picker("Storage engine", selection: $ops.engine) {
                        ForEach(ops.engines.contains(ops.engine) ? ops.engines : [ops.engine] + ops.engines, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180, alignment: .leading)
                }
                FormRow("Collation") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Collation", selection: $ops.collation) {
                            ForEach(ops.collationNames, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 280, alignment: .leading)
                        Toggle("Change all column collations", isOn: $ops.convertColumns)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 13))
                            .help("CONVERT TO CHARACTER SET: converts every text column as well as the table default")
                    }
                }
                if ops.current?.autoIncrement != nil {
                    FormRow("AUTO_INCREMENT") {
                        TextField("Next id", text: $ops.autoIncrement)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(width: 160)
                            .accessibilityLabel("AUTO_INCREMENT value")
                    }
                }
                FormRow("ROW_FORMAT") {
                    Picker("Row format", selection: $ops.rowFormat) {
                        ForEach(Self.rowFormatChoices(including: ops.rowFormat), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180, alignment: .leading)
                }
            }
        }
    }

    private static func rowFormatChoices(including current: String) -> [String] {
        let all = TableOperationsModel.rowFormats
        return current.isEmpty || all.contains(current) ? all : [current] + all
    }

    // MARK: Copy

    private var copyCard: some View {
        OperationCard(
            title: "Copy table to", subtitle: nil, plan: ops.copyPlan, status: ops.statuses[.copy],
            applyTitle: "Copy", applyLabel: "Copy table", busy: ops.running == .copy, disabled: locked,
            apply: { Task { await ops.applyCopy() } }
        ) {
            FormRow("Table") {
                HStack(spacing: 6) {
                    Picker("Copy to \(ops.isPostgres ? "schema" : "database")", selection: $ops.copySchema) {
                        ForEach(ops.schemas, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180, alignment: .leading)
                    Text(".").foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
                    TextField("Copy name", text: $ops.copyName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 240)
                        .accessibilityLabel("Name of the copy")
                }
            }
            FormRow("Copy") {
                Picker("What to copy", selection: $ops.copyMode) {
                    Text("Structure only").tag(CopyMode.structureOnly)
                    Text("Structure and data").tag(CopyMode.structureAndData)
                    Text("Data only").tag(CopyMode.dataOnly)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityLabel("What to copy")
            }
            FormRow("Options") {
                VStack(alignment: .leading, spacing: 4) {
                    let structural = ops.copyMode != .dataOnly
                    Toggle(ops.isPostgres ? "Add DROP TABLE IF EXISTS" : "Add DROP TABLE", isOn: $ops.dropCopyTarget)
                        .disabled(!structural)
                    if !ops.isPostgres {
                        Toggle("Add AUTO_INCREMENT value", isOn: $ops.keepAutoIncrement).disabled(!structural)
                    }
                    Toggle("Add constraints (foreign keys)", isOn: $ops.addConstraints).disabled(!structural)
                    Toggle("Switch to copied table", isOn: $ops.switchToCopy)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
            }
        }
    }

    // MARK: Maintenance

    private var maintenanceCard: some View {
        let sql = ops.maintenanceSQL
        let plan: TableOperationsModel.PlanState = sql.map { .ready(AlterationPlan(statements: [$0])) } ?? .invalid("Not available")
        return OperationCard(
            title: "Table maintenance", subtitle: ops.maintenanceCommand.summary, plan: plan, status: ops.statuses[.maintenance],
            applyTitle: "Run", applyLabel: "Run \(ops.maintenanceCommand.title)", busy: ops.running == .maintenance, disabled: locked,
            apply: { Task { await ops.runMaintenance() } }
        ) {
            FormRow("Command") {
                Picker("Maintenance command", selection: $ops.maintenanceCommand) {
                    ForEach(ops.availableMaintenance) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180, alignment: .leading)
            }
        } results: {
            if let output = ops.maintenanceOutput, !output.rows.isEmpty { MaintenanceResultTable(output: output) }
        }
    }

    // MARK: Delete

    private var deleteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CaptionLabel("Delete data or table")
            DangerRow(
                title: "Empty the table (TRUNCATE)", detail: "Removes every row, resets the counter and is not logged row by row.",
                sql: ops.truncateSQL, buttonTitle: "Empty…", disabled: locked || ops.hasPendingEdits
            ) { Task { await ops.truncate() } }
            Divider()
            DangerRow(
                title: "Empty the table (DELETE FROM)", detail: "Deletes row by row: fires triggers and keeps the counter. Slow on big tables.",
                sql: ops.deleteSQL, buttonTitle: "Delete all rows…", disabled: locked || ops.hasPendingEdits
            ) { Task { await ops.deleteAllRows() } }
            Divider()
            DangerRow(
                title: "Delete the table (DROP)", detail: "Removes the table, its data and its indexes.",
                sql: ops.dropSQL, buttonTitle: "Drop table…", disabled: locked || ops.hasPendingEdits
            ) { Task { await ops.drop() } }
            if let status = ops.statuses[.delete] { StatusLine(status: status) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Delete data or table")
    }
}

// MARK: - Pieces

/// One grouped section: form, the SQL that Apply will run, outcome line and the Apply button.
private struct OperationCard<Form: View, Results: View>: View {
    var title: String
    var subtitle: String?
    var plan: TableOperationsModel.PlanState
    var status: TableOperationsModel.Status?
    var applyTitle: String
    var applyLabel: String
    var busy: Bool
    var disabled: Bool
    var apply: () -> Void
    @ViewBuilder var form: Form
    @ViewBuilder var results: Results

    init(title: String, subtitle: String?, plan: TableOperationsModel.PlanState, status: TableOperationsModel.Status?,
         applyTitle: String, applyLabel: String, busy: Bool, disabled: Bool, apply: @escaping () -> Void,
         @ViewBuilder form: () -> Form, @ViewBuilder results: () -> Results) {
        self.title = title
        self.subtitle = subtitle
        self.plan = plan
        self.status = status
        self.applyTitle = applyTitle
        self.applyLabel = applyLabel
        self.busy = busy
        self.disabled = disabled
        self.apply = apply
        self.form = form()
        self.results = results()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                CaptionLabel(title)
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
            }
            VStack(alignment: .leading, spacing: 10) { form }
            switch plan {
            case .ready(let p):
                if !p.warnings.isEmpty { WarningCallout(title: nil, lines: p.warnings) }
                SQLBox(sql: p.script, maxHeight: 110, fontSize: 11)
            case .invalid(let message):
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            case .unchanged:
                Text("Nothing to change.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 10) {
                if let status { StatusLine(status: status) }
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small).accessibilityLabel("Running") }
                if case .ready(let p) = plan {
                    Button("Copy SQL") { copyToPasteboard(p.script) }
                        .buttonStyle(OutlineButtonStyle())
                }
                Button(applyTitle, action: apply)
                    .buttonStyle(AccentFillButtonStyle())
                    .disabled(disabled || busy || plan.plan == nil)
                    .accessibilityLabel(applyLabel)
            }
            .font(.system(size: 13, weight: .medium))
            results
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension OperationCard where Results == EmptyView {
    init(title: String, subtitle: String?, plan: TableOperationsModel.PlanState, status: TableOperationsModel.Status?,
         applyTitle: String, applyLabel: String, busy: Bool, disabled: Bool, apply: @escaping () -> Void,
         @ViewBuilder form: () -> Form) {
        self.init(title: title, subtitle: subtitle, plan: plan, status: status, applyTitle: applyTitle, applyLabel: applyLabel,
                  busy: busy, disabled: disabled, apply: apply, form: form, results: { EmptyView() })
    }
}

private struct FormRow<Content: View>: View {
    var label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .frame(width: 120, alignment: .trailing)
                .accessibilityHidden(true)
            content
            Spacer(minLength: 0)
        }
    }
}

private struct StatusLine: View {
    var status: TableOperationsModel.Status

    var body: some View {
        Label(status.message, systemImage: status.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(status.isError ? Theme.dangerText : Theme.connectedText)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityElement(children: .combine)
    }
}

private struct DangerRow: View {
    var title: String
    var detail: String
    var sql: String
    var buttonTitle: String
    var disabled: Bool
    var action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Text(sql + ";").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(buttonTitle, action: action)
                .buttonStyle(AccentFillButtonStyle(tint: Theme.dangerFill))
                .font(.system(size: 13, weight: .medium))
                .disabled(disabled)
                .accessibilityLabel("\(title): \(buttonTitle)")
        }
        .accessibilityElement(children: .contain)
    }
}

/// CHECK / ANALYZE / CHECKSUM output rows.
private struct MaintenanceResultTable: View {
    var output: TableOperationsModel.MaintenanceOutput

    var body: some View {
        let typeColumn = output.columns.firstIndex { $0.caseInsensitiveCompare("Msg_type") == .orderedSame }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ForEach(Array(output.columns.enumerated()), id: \.offset) { _, name in
                    Text(name.uppercased()).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.background)
            Divider()
            ForEach(Array(output.rows.enumerated()), id: \.offset) { _, row in
                let problem = typeColumn.map { row.indices.contains($0) && ["error", "warning"].contains(row[$0].lowercased()) } ?? false
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(problem ? Theme.dangerText : Theme.text)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .accessibilityElement(children: .combine)
            }
        }
        .background(Theme.elevated)
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.separator))
        .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Result of \(output.sql)")
    }
}
