import AppKit
import Testing

// SwiftUI builds the accessibility tree of an NSHostingView only after an assistive app turns on
// AXEnhancedUserInterface for the process. Its elements are also not NSAccessibilityProtocol values in Swift, so a
// cast skips them. A window test that finds and presses real SwiftUI controls turns the attribute on, as VoiceOver
// does, and reads the elements through their Objective-C accessibility methods.
@MainActor
struct HostedControl {
    let object: AnyObject

    var identifier: String? { object.accessibilityIdentifier?() }
    var label: String? { object.accessibilityLabel?() ?? nil }
    var value: Any? { object.accessibilityValue?() ?? nil }
    var isEnabled: Bool { object.isAccessibilityEnabled?() ?? false }
    var frame: NSRect { object.accessibilityFrame?() ?? .zero }
    func press() -> Bool { object.accessibilityPerformPress?() ?? false }

    fileprivate var children: [AnyObject] { (object.accessibilityChildren?() ?? nil)?.map { $0 as AnyObject } ?? [] }
}

@MainActor
enum HostedAccessibility {
    static func setAssistiveClient(_ on: Bool) {
        (NSApplication.shared as any AccessibilityAttributeSetting)
            .accessibilitySetValue(on, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }

    static func elements(in node: AnyObject, depth: Int = 0) -> [HostedControl] {
        guard depth < 40 else { return [] }
        let element = HostedControl(object: node)
        return [element] + element.children.flatMap { elements(in: $0, depth: depth + 1) }
    }

    static func control(_ id: String, in hosting: NSView) async throws -> HostedControl {
        try await until { elements(in: hosting).contains { $0.identifier == id } }
        return try #require(elements(in: hosting).first { $0.identifier == id })
    }
}

// The setter is the attribute call an assistive app makes. Calling it through a protocol keeps its deprecation
// warning out of the test build.
@MainActor
private protocol AccessibilityAttributeSetting {
    func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute)
}

extension NSApplication: AccessibilityAttributeSetting {}
