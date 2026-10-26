import QuerywellCore
import SwiftUI
import UniformTypeIdentifiers

/// Presents the export / import / result-export sheets of a connection window and accepts dropped `.sql` files.
struct TransferSheets: ViewModifier {
    let workspace: ConnectionWorkspace

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { workspace.tools.exportSheet != nil }, set: { if !$0 { workspace.tools.exportSheet = nil } })) {
                if let model = workspace.tools.exportSheet {
                    ExportSheetView(model: model) { workspace.tools.exportSheet = nil }
                        .interactiveDismissDisabled(model.isRunning)
                }
            }
            .sheet(isPresented: Binding(get: { workspace.tools.importSheet != nil }, set: { if !$0 { workspace.tools.importSheet = nil } })) {
                if let model = workspace.tools.importSheet {
                    ImportSheetView(model: model) { workspace.tools.importSheet = nil }
                        .interactiveDismissDisabled(model.isRunning)
                }
            }
            .sheet(isPresented: Binding(get: { workspace.tools.resultExport != nil }, set: { if !$0 { workspace.tools.resultExport = nil } })) {
                if let model = workspace.tools.resultExport {
                    ResultExportSheet(model: model) { workspace.tools.resultExport = nil }
                        .interactiveDismissDisabled(model.isRunning)
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: Binding(get: { workspace.tools.isDropTargeted }, set: { workspace.tools.isDropTargeted = $0 })) { providers in
                guard workspace.isConnected, let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, ConnectionWorkspace.isImportable(url) else { return }
                    Task { @MainActor in workspace.presentImport(file: url) }
                }
                return true
            }
            .overlay {
                if workspace.tools.isDropTargeted {
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                        .background(Theme.accentSubtleBackground.opacity(0.35))
                        .overlay {
                            Label("Drop an .sql or .sql.gz file to import it", systemImage: "square.and.arrow.down")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accentSubtleText)
                                .padding(.horizontal, 18).padding(.vertical, 12)
                                .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                        }
                        .padding(6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: workspace.tabs.tabs.map(\.id)) { _, ids in workspace.tools.prune(openTabs: Set(ids)) }
    }
}

extension View {
    func transferSheets(for workspace: ConnectionWorkspace) -> some View {
        modifier(TransferSheets(workspace: workspace))
    }
}
