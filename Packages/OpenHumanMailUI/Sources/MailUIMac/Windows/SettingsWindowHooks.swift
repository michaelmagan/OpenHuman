import AppKit
import SwiftUI

/// Put behind the Settings window's content: makes the window resizable. The system keeps its Settings window at a
/// fixed size; resizable, it can show more of a long page, and it reopens at the size it was left at.
public struct SettingsWindowHook: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> SettingsWindowHookView {
        SettingsWindowHookView()
    }

    public func updateNSView(_ view: SettingsWindowHookView, context: Context) {
        view.applyToWindow()
    }
}

public final class SettingsWindowHookView: NSView {
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyToWindow()
    }

    func applyToWindow() {
        guard let window else { return }
        SettingsWindowHooks.configure(window)
        // Why: the scene sets the window's style after its content is attached, which takes the first change back
        DispatchQueue.main.async { [weak self] in
            if let window = self?.window { SettingsWindowHooks.configure(window) }
        }
    }
}

@MainActor
public enum SettingsWindowHooks {
    public static func configure(_ window: NSWindow) {
        if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
    }
}
