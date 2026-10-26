import SwiftUI
import QuerywellCore

@main
struct QuerywellApp: App {
    var body: some Scene {
        WindowGroup("Connections") {
            LauncherView()
        }

        Settings {
            SettingsPlaceholderView()
        }
    }
}

struct LauncherView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Querywell")
                .font(.largeTitle.bold())
            Text("Supported engines")
                .font(.headline)
            List(DatabaseEngine.allCases, id: \.self) { engine in
                Text(engine.displayName)
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 320)
    }
}

struct SettingsPlaceholderView: View {
    var body: some View {
        Text("Settings coming soon")
            .padding()
            .frame(width: 360, height: 160)
    }
}
