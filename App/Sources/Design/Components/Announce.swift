import AppKit

/// Spoken status updates for VoiceOver (long operations finishing, progress milestones, errors).
/// Silent when VoiceOver is off, so it is safe to call from model code.
enum Announce {
    @MainActor
    static func post(_ message: String, important: Bool = false) {
        guard !message.isEmpty else { return }
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: (important ? NSAccessibilityPriorityLevel.high : .medium).rawValue,
            ])
    }
}
