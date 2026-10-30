import AppKit
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI

// A borderless child panel under a text field that shows a CompletionListModel. It never becomes key, so the field
// keeps the caret and its keys; it floats over the window, so opening it moves nothing in the form.
@MainActor
final class CompletionPanel {
    static let shadowRoom: CGFloat = 12
    static let gap: CGFloat = 4

    private var panel: CompletionPanelWindow?
    private let content = CompletionPanelContent()
    private weak var parent: NSWindow?
    private weak var anchor: NSView?
    private var observers: [NSObjectProtocol] = []

    var isVisible: Bool { panel?.isVisible == true && parent != nil }

    var frame: NSRect? { isVisible ? panel?.frame : nil }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let panel {
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    func show(_ list: CompletionListModel, below anchor: NSView, theme: ResolvedTheme, label: String, identifier: String,
              accessory: (@MainActor (EmailAddress) -> String?)? = nil,
              accept: @escaping @MainActor (EmailAddress) -> Void) {
        guard let window = anchor.window, !list.items.isEmpty else {
            hide()
            return
        }
        content.list = list
        content.theme = theme
        content.label = label
        content.identifier = identifier
        content.accessory = accessory
        content.accept = accept
        let panel = self.panel ?? makePanel()
        panel.list = list
        panel.appearance = NSAppearance(named: theme.appearance == .dark ? .darkAqua : .aqua)
        if self.anchor !== anchor {
            self.anchor = anchor
            watch(anchor)
        }
        place(panel, rows: list.items.count, in: window)
        if parent !== window {
            if let parent { parent.removeChildWindow(panel) }
            window.addChildWindow(panel, ordered: .above)
            parent = window
        }
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func reposition() {
        guard let panel, isVisible, let window = anchor?.window, let list = content.list else { return }
        place(panel, rows: list.items.count, in: window)
    }

    func hide() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        anchor = nil
        guard let panel else { return }
        if let parent { parent.removeChildWindow(panel) }
        parent = nil
        panel.orderOut(nil)
    }

    private func place(_ panel: NSPanel, rows: Int, in window: NSWindow) {
        guard let anchor else { return }
        let field = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let size = Self.size(fieldWidth: field.width, rows: rows)
        let bounds = window.screen?.visibleFrame ?? window.frame
        let frame = NSRect(origin: Self.origin(for: size, below: field, within: bounds), size: size)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    static func size(fieldWidth: CGFloat, rows: Int) -> NSSize {
        NSSize(width: max(fieldWidth, CompletionListMetrics.minWidth) + 2 * shadowRoom,
               height: CompletionListMetrics.height(rows: rows) + 2 * shadowRoom)
    }

    // Below the field when it fits on the screen, otherwise above it; the shadow room overhangs on every side
    static func origin(for size: NSSize, below field: NSRect, within bounds: NSRect) -> NSPoint {
        let room = shadowRoom
        let listHeight = size.height - 2 * room
        var x = field.minX - room
        x = min(max(x, bounds.minX - room), max(bounds.minX - room, bounds.maxX + room - size.width))
        var y = field.minY - gap - listHeight - room
        if y + room < bounds.minY, field.maxY + gap + listHeight <= bounds.maxY {
            y = field.maxY + gap - room
        }
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    private func makePanel() -> CompletionPanelWindow {
        let panel = CompletionPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        let hosting = FirstMouseHostingView(rootView: CompletionPanelRoot(content: content))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func watch(_ anchor: NSView) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        var clips: [NSClipView] = []
        var view = anchor.superview
        while let current = view {
            if let clip = current as? NSClipView { clips.append(clip) }
            view = current.superview
        }
        observers = clips.map { clip in
            clip.postsBoundsChangedNotifications = true
            return NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                          queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            }
        }
        if let window = anchor.window {
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window,
                                                                    queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            })
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window,
                                                                        queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.content.list?.dismiss()
                        self?.hide()
                    }
                })
            }
        }
    }
}

@MainActor @Observable
final class CompletionPanelContent {
    var list: CompletionListModel?
    var theme: ResolvedTheme = .light
    var label = ""
    var identifier = ""
    @ObservationIgnored var accessory: (@MainActor (EmailAddress) -> String?)?
    @ObservationIgnored var accept: @MainActor (EmailAddress) -> Void = { _ in }
}

struct CompletionPanelRoot: View {
    let content: CompletionPanelContent

    var body: some View {
        Group {
            if let list = content.list {
                CompletionListView(model: list, label: content.label, identifier: content.identifier,
                                   accessory: content.accessory) { address in
                    content.accept(address)
                }
                // The panel clips at its shadow room, so the shadow is the small one that fits inside it
                .themeShadow(content.theme.shadow1)
            }
        }
        .padding(CompletionPanel.shadowRoom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.theme, content.theme)
        .environment(\.colorScheme, content.theme.appearance == .dark ? .dark : .light)
        .tint(content.theme.accentFill.color)
    }
}

final class CompletionPanelWindow: NSPanel {
    weak var list: CompletionListModel?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class CompletionAnchorView: NSView {
    let panel = CompletionPanel()
    var listIdentifier = ""
    var refresh: (@MainActor (CompletionAnchorView) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { panel.hide() } else { refresh?(self) }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        panel.reposition()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        panel.reposition()
    }

    override func isAccessibilityElement() -> Bool { false }
}

struct CompletionPanelAnchor: NSViewRepresentable {
    let list: CompletionListModel
    let isPresented: Bool
    let rows: Int
    let theme: ResolvedTheme
    let label: String
    let identifier: String
    var accessory: (@MainActor (EmailAddress) -> String?)?
    let accept: @MainActor (EmailAddress) -> Void

    func makeNSView(context: Context) -> CompletionAnchorView { CompletionAnchorView() }

    func updateNSView(_ view: CompletionAnchorView, context: Context) {
        let list = list, presented = isPresented, theme = theme, label = label, identifier = identifier
        let accept = accept, accessory = accessory
        view.listIdentifier = identifier
        view.refresh = { anchor in
            if presented, anchor.window != nil {
                anchor.panel.show(list, below: anchor, theme: theme, label: label, identifier: identifier,
                                  accessory: accessory, accept: accept)
            } else {
                anchor.panel.hide()
            }
        }
        view.refresh?(view)
    }

    static func dismantleNSView(_ view: CompletionAnchorView, coordinator: ()) {
        view.refresh = nil
        view.panel.hide()
    }
}

private struct CompletionPanelModifier: ViewModifier {
    let list: CompletionListModel?
    let isActive: Bool
    let label: String
    let identifier: String
    let accept: @MainActor (EmailAddress) -> Void
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.background {
            if let list {
                CompletionPanelAnchor(list: list, isPresented: isActive && list.isShowing, rows: list.items.count,
                                      theme: theme, label: label, identifier: identifier, accept: accept)
            }
        }
    }
}

extension FloatingCompletion {
    // The composer's recipient fields float their suggestions in the same child panel as the calendar's guest field
    static let panel = FloatingCompletion { request in
        AnyView(CompletionPanelAnchor(list: request.list, isPresented: request.isPresented && request.list.isShowing,
                                      rows: request.list.items.count, theme: request.theme, label: request.label,
                                      identifier: request.identifier, accessory: request.accessory,
                                      accept: request.accept))
    }
}

extension View {
    func floatsCompletions() -> some View {
        environment(\.floatingCompletion, .panel)
    }

    func completionPanel(_ list: CompletionListModel?, isActive: Bool, label: String, identifier: String,
                         accept: @escaping @MainActor (EmailAddress) -> Void) -> some View {
        modifier(CompletionPanelModifier(list: list, isActive: isActive, label: label, identifier: identifier,
                                         accept: accept))
    }

    // Return stays with the field's onSubmit so marked text is committed first; see CompletionListModel.handle
    func completionKeys(_ list: CompletionListModel?, accept: @escaping @MainActor (EmailAddress) -> Void) -> some View {
        func route(_ key: CompletionKey) -> KeyPress.Result {
            guard !KeyRouter.hasMarkedText(NSApp.keyWindow?.firstResponder), let list else { return .ignored }
            switch list.handle(key) {
            case .ignored: return .ignored
            case .moved, .dismissed: return .handled
            case .accepted(let address):
                accept(address)
                return .handled
            }
        }
        return self
            .onKeyPress(.downArrow) { route(.down) }
            .onKeyPress(.upArrow) { route(.up) }
            .onKeyPress(.escape) { route(.escape) }
            .onKeyPress(.tab, phases: .down) { press in
                press.modifiers.contains(.shift) ? .ignored : route(.accept)
            }
    }
}
