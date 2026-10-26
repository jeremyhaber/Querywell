import AppKit
import SwiftUI

/// Password field with a show/hide toggle.
struct RevealableSecureField: View {
    var title: String
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if revealed {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .accessibilityLabel(title)
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealed ? "Hide" : "Show")
            .accessibilityLabel(revealed ? "Hide \(title)" : "Show \(title)")
        }
    }
}

/// Path text field with a "Choose…" button that opens an `NSOpenPanel`.
struct FilePathField: View {
    var title: String
    @Binding var path: String
    /// Directory to open when the field is empty.
    var startingAt: URL?
    var showsHiddenFiles = false

    var body: some View {
        HStack(spacing: 6) {
            TextField(title, text: $path)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(.system(size: 12, design: .monospaced))
                .accessibilityLabel(title)
            Button("Choose…") {
                if let chosen = FilePicker.choose(
                    title: title, current: path, startingAt: startingAt, showsHiddenFiles: showsHiddenFiles) {
                    path = chosen
                }
            }
        }
    }
}

@MainActor
enum FilePicker {
    static func choose(title: String, current: String, startingAt: URL?, showsHiddenFiles: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = showsHiddenFiles
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded).deletingLastPathComponent()
        } else {
            panel.directoryURL = startingAt
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// `~/.ssh`
    static var sshDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
    }
}

/// Red caption under a field.
struct ValidationMessage: View {
    var text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(Theme.dangerText)
            .accessibilityLabel("Problem: \(text)")
    }
}
