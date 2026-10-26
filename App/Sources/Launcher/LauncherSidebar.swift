import QuerywellCore
import SwiftUI

/// Sheet content: name a new folder or rename one.
struct FolderNameSheet: View {
    var title: String
    var confirmTitle: String
    @State var name: String
    var onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSubmit(name)
        dismiss()
    }
}

enum FolderSheet: Identifiable {
    case add
    case rename(ConnectionFolder)

    var id: String {
        switch self {
        case .add: "add"
        case .rename(let folder): "rename-\(folder.id)"
        }
    }
}

/// Folders and tags.
struct LauncherSidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var query: ConnectionLibraryQuery
    var onAddFolder: () -> Void
    var onRename: (ConnectionFolder) -> Void
    var onDelete: (ConnectionFolder) -> Void

    private var selection: Binding<FolderFilter?> {
        Binding(get: { query.folder }, set: { if let value = $0 { query.folder = value } })
    }

    var body: some View {
        let counts = query.folderCounts(in: model.library)
        List(selection: selection) {
            Section {
                row("All connections", symbol: "tray.full", filter: .all, counts: counts)
                row("Favourites", symbol: "star", filter: .favourites, counts: counts)
                ForEach(model.sortedFolders) { folder in
                    row(folder.name, symbol: "folder", filter: .folder(folder.id), counts: counts)
                        .contextMenu {
                            Button("Rename…") { onRename(folder) }
                            Divider()
                            Button("Delete…", role: .destructive) { onDelete(folder) }
                        }
                        .dropDestination(for: String.self) { items, _ in
                            drop(items, into: folder.id)
                        }
                }
                row("Unfiled", symbol: "tray", filter: .unfiled, counts: counts)
                    .dropDestination(for: String.self) { items, _ in
                        drop(items, into: nil)
                    }
            } header: {
                HStack {
                    CaptionLabel("Folders")
                    Spacer()
                    Button(action: onAddFolder) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New folder")
                    .accessibilityLabel("Add folder")
                }
            }

            Section {
                tagRow("Production · confirm writes", tag: .production, kind: .production, counts: counts)
                tagRow("Staging", tag: .staging, kind: .staging, counts: counts)
                tagRow("Local", tag: .local, kind: .local, counts: counts)
            } header: {
                CaptionLabel("Tags")
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Folders and tags")
    }

    private func row(_ title: String, symbol: String, filter: FolderFilter, counts: [FolderFilter: Int]) -> some View {
        HStack {
            Label(title, systemImage: symbol)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(counts[filter] ?? 0)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityLabel("\(counts[filter] ?? 0) connections")
        }
        .tag(filter)
    }

    private func tagRow(_ title: String, tag: ColorTag, kind: ColorTagKind, counts: [FolderFilter: Int]) -> some View {
        HStack(spacing: 8) {
            ColorTagSwatch(tag: tag)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(counts[.tag(kind)] ?? 0)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityLabel("\(counts[.tag(kind)] ?? 0) connections")
        }
        .font(.system(size: 12))
        .tag(FolderFilter.tag(kind))
    }

    private func drop(_ items: [String], into folderID: UUID?) -> Bool {
        let profiles = items.compactMap { UUID(uuidString: $0) }.compactMap { model.profile(id: $0) }
        guard !profiles.isEmpty else { return false }
        Task {
            for profile in profiles { await model.move(profile, toFolder: folderID) }
        }
        return true
    }
}
