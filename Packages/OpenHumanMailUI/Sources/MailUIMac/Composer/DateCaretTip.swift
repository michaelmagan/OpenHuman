import AppKit
import MailFeatures
import MailTheme
import MailUI
import SwiftUI

@MainActor
final class DateCaretTip {
    private var panel: NSPanel?
    private let model = DateCaretTipModel()
    private weak var parent: NSWindow?
    private var observers: [NSObjectProtocol] = []

    var isVisible: Bool { panel?.isVisible == true }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let panel {
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    func show(under caret: NSRect, in window: NSWindow, theme: ResolvedTheme, scrolling: [NSClipView]) {
        model.theme = theme
        let panel = self.panel ?? makePanel()
        guard let content = panel.contentView else { return }
        let size = content.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(Self.origin(for: size, under: caret, in: window))
        if parent !== window {
            if let parent { parent.removeChildWindow(panel) }
            window.addChildWindow(panel, ordered: .above)
            parent = window
        }
        if !panel.isVisible { panel.orderFront(nil) }
        watch(scrolling)
    }

    func hide() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard let panel else { return }
        if let parent { parent.removeChildWindow(panel) }
        parent = nil
        panel.orderOut(nil)
    }

    static func origin(for size: NSSize, under caret: NSRect, in window: NSWindow) -> NSPoint {
        let gap: CGFloat = 6
        let screen = window.screen?.visibleFrame ?? window.frame
        var x = caret.minX - DateCaretTipRoot.shadowRoom
        x = min(max(x, screen.minX), max(screen.minX, screen.maxX - size.width))
        var y = caret.minY - gap - size.height + DateCaretTipRoot.shadowRoom
        if y < screen.minY { y = caret.maxY + gap - DateCaretTipRoot.shadowRoom }
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    private func makePanel() -> NSPanel {
        let panel = FormatBarWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        let hosting = NSHostingView(rootView: DateCaretTipRoot(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func watch(_ clips: [NSClipView]) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = clips.map { clip in
            clip.postsBoundsChangedNotifications = true
            return NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                          queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }
}

@MainActor @Observable
final class DateCaretTipModel {
    var theme: ResolvedTheme = .light
}

struct DateCaretTipRoot: View {
    static let shadowRoom: CGFloat = 8
    let model: DateCaretTipModel

    var body: some View {
        DateCaretTipView()
            .fixedSize()
            .padding(Self.shadowRoom)
            .environment(\.theme, model.theme)
            .environment(\.colorScheme, .dark)
    }
}

struct DateCaretTipView: View {
    @Environment(\.theme) private var theme

    struct Row: Hashable {
        let title: String
        let keys: [String]
    }

    static let rows: [Row] = [
        Row(title: String(localized: "Previous Day"), keys: ["⌘", "⇧", "−"]),
        Row(title: String(localized: "Next Day"), keys: ["⌘", "⇧", "="]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            ForEach(Self.rows, id: \.title) { row in
                HStack(spacing: theme.space4) {
                    Text(row.title).themeFont(theme.typeMeta).foregroundStyle(theme.textOnToast.color)
                    Spacer(minLength: theme.space3)
                    HStack(spacing: theme.space1) {
                        ForEach(row.keys, id: \.self) { key in
                            Text(verbatim: key)
                                .themeFont(theme.typeCaption)
                                .foregroundStyle(theme.textOnToast.color)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(RoundedRectangle(cornerRadius: theme.radiusXS).fill(theme.textOnToast.color.opacity(0.14)))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, theme.space3)
        .padding(.vertical, theme.space2)
        .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgToast.color).themeShadow(theme.shadow2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Previous day: Command Shift Minus. Next day: Command Shift Equals.")
        .accessibilityIdentifier("composer.dateTip")
    }
}
