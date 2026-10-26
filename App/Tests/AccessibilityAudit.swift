import AppKit
import Testing

/// Walks the NSAccessibility tree below a view (the same tree VoiceOver and the Accessibility Inspector
/// read) and reports controls a screen reader user could not identify.
@MainActor
enum AccessibilityAudit {
    struct Stats { var elements = 0; var buttons = 0 }

    /// The attribute API (what the accessibility server actually calls); SwiftUI's nodes implement only this.
    private static func legacy(_ obj: NSObject, _ attribute: NSAccessibility.Attribute) -> Any? {
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        guard obj.responds(to: selector) else { return nil }
        return obj.perform(selector, with: attribute.rawValue)?.takeUnretainedValue()
    }

    /// Roles that must be nameable: an empty label, title and help leaves VoiceOver saying only "button".
    private static let nameRequired: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .menuButton, .disclosureTriangle, .slider, .image,
    ]
    // Not audited: SwiftUI Form text fields, pop-ups and switches. SwiftUI hands their titles to the accessibility
    // server through the form row, which this in-process walk does not see (it reports them unlabeled even when
    // an explicit label is set). Their titles are the Form row titles in the source.
    private static let formControlClasses = ["PlatformSwitch", "SwiftUIPopupButtonCell"]

    /// Findings for everything below `root`, as `role at path` strings. `stats` is filled for sanity checks.
    static func findings(in root: NSView, stats: inout Stats, dump: Bool = false) -> [String] {
        var out: [String] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ element: Any, path: String, depth: Int) {
            guard depth < 60 else { return }
            guard let obj = element as? NSObject else { return }
            guard seen.insert(ObjectIdentifier(obj)).inserted else { return }
            let ax = element as? NSAccessibilityProtocol
            stats.elements += 1
            if dump { print("A11YTREE \(type(of: obj)) \(path) label=\(ax?.accessibilityLabel() ?? "-")") }
            // The system scroll bars' arrow buttons are unlabeled by AppKit itself.
            if let r = ax?.accessibilityRole(), r == .scrollBar { return }
            if let ax, ax.isAccessibilityElement(), let role = ax.accessibilityRole() {
                if role == .button { stats.buttons += 1 }
                if nameRequired.contains(role), !formControlClasses.contains(where: { "\(type(of: obj))".contains($0) }) {
                    // SwiftUI's nodes answer the attribute API; AppKit controls answer both.
                    func text(_ attr: NSAccessibility.Attribute, _ direct: String?) -> String {
                        let v = (direct ?? (legacy(obj, attr) as? String)) ?? ""
                        return v.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    // AppKit cells delegate to their control view (where SwiftUI puts the label it computed).
                    let controlLabel = ((obj as? NSCell)?.controlView?.accessibilityLabel() ?? (obj as? NSCell)?.controlView?.accessibilityTitle() ?? "")
                    let label = text(.description, ax.accessibilityLabel() ?? (controlLabel.isEmpty ? nil : controlLabel))
                    let title = text(.title, ax.accessibilityTitle())
                    let help = text(.help, ax.accessibilityHelp())
                    var placeholder = ""
                    if role == .textField || role == .comboBox { placeholder = (ax.accessibilityPlaceholderValue() ?? (legacy(obj, .placeholderValue) as? String) ?? "") }
                    let titleElement = ax.accessibilityTitleUIElement() != nil || legacy(obj, .titleUIElement) != nil
                    var valueName = ""
                    if role == .textField || role == .comboBox || role == .tabGroup { valueName = "" }
                    if label.isEmpty, title.isEmpty, help.isEmpty, placeholder.isEmpty, !titleElement, valueName.isEmpty {
                        out.append("unlabeled \(role.rawValue) at \(path)")
                    }
                }
            }
            // What the accessibility server walks: accessibilityChildren; a plain NSView without any falls back to its subviews.
            var children: [Any] = ax?.accessibilityChildren() ?? []
            if children.isEmpty, let view = obj as? NSView, !(view is NSControl) { children = view.subviews }
            for (i, child) in children.enumerated() {
                let childRole = (child as? NSAccessibilityProtocol)?.accessibilityRole()?.rawValue ?? "?"
                walk(child, path: path + "/" + childRole + "[\(i)]", depth: depth + 1)
            }
        }
        walk(root, path: "root", depth: 0)
        return out
    }

    /// Records an issue for each finding on `window`'s content view.
    static func audit(_ window: NSWindow, name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let content = window.contentView else { return }
        var stats = Stats()
        let found = findings(in: content, stats: &stats)
        if stats.elements < 3 { Issue.record("a11y \(name): the walk saw only \(stats.elements) elements", sourceLocation: sourceLocation) }
        for f in found { Issue.record("a11y \(name): \(f)", sourceLocation: sourceLocation) }
    }
}
