import AppKit
import SwiftUI

/// Animations that honour System Settings > Accessibility > Display > Reduce motion.
/// With the setting on, state changes still happen but without movement or fades.
enum Motion {
    @MainActor static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// `withAnimation` that does nothing visual when Reduce motion is on.
    @MainActor @discardableResult
    static func animate<T>(_ animation: Animation? = .easeOut(duration: 0.15), _ body: () throws -> T) rethrows -> T {
        try withAnimation(reduced ? nil : animation, body)
    }
}

private struct MotionAwareAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var animation: Animation?
    var value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that is skipped under Reduce motion.
    func motionAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(MotionAwareAnimation(animation: animation, value: value))
    }
}
