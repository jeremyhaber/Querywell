import SwiftUI

/// Presents `AppModel.alert` in whichever window is key, so several windows don't all show it.
struct AppAlertModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content.alert(
            model.alert?.title ?? "Error",
            isPresented: Binding(
                get: { model.alert != nil && activeState == .key },
                set: { if !$0 { model.alert = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            if let alert = model.alert {
                Text([alert.message, alert.recovery].compactMap { $0 }.joined(separator: "\n\n"))
            }
        }
    }
}

extension View {
    func appAlert() -> some View { modifier(AppAlertModifier()) }
}

/// Filled button in the design's "subtle accent" colours (the card's Connect button).
struct SubtleAccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.accentSubtleText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Theme.accentSubtleBackground.opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            .opacity(isEnabled ? 1 : 0.5)
    }
}
