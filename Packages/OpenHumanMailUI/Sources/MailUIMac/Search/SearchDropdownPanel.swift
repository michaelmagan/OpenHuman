import AppKit
import MailFeatures
import MailTheme
import MailUI
import SwiftUI

// The search suggestions in a borderless child panel under the toolbar's search field. The toolbar cannot draw over
// the window's content, so the panel floats above it: nothing under it moves, and it never becomes key, so the field
// keeps the caret and every key.
@MainActor
final class SearchDropdownPanel {
    static let shadowRoom: CGFloat = 16
    static let identifier = "search.suggestionsPanel"
    /// A window capture leaves glass blank, so off-screen renders draw the panel on the system material.
    static var drawsMaterial = false

    private var panel: SearchDropdownPanelWindow?
    private let content = SearchDropdownPanelContent()
    private weak var parent: NSWindow?
    private weak var anchor: NSView?
    private var observers: [NSObjectProtocol] = []

    var isVisible: Bool { panel?.isVisible == true && parent != nil }

    /// The panel's visible frame on screen, without the room around it for the shadow.
    var contentFrame: NSRect? {
        guard isVisible, let frame = panel?.frame else { return nil }
        return frame.insetBy(dx: Self.shadowRoom, dy: Self.shadowRoom)
    }

    var placement: SearchDropdownPlacement? { isVisible ? content.placement : nil }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let panel {
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    /// Does nothing more than keep the field's newest closures when the panel already shows the same thing in the same
    /// place.
    func show(_ request: SearchDropdownRequest, below anchor: NSView) {
        guard request.isPresented, let window = anchor.window, window.isVisible,
              !KeyRouter.hasMarkedText(window.firstResponder) else {
            hide()
            return
        }
        content.accept = request.accept
        if !request.draws(sameAs: content.request) { content.request = request }
        if content.drawsMaterial != Self.drawsMaterial { content.drawsMaterial = Self.drawsMaterial }
        let panel = self.panel ?? makePanel()
        let appearance: NSAppearance.Name = request.theme.appearance == .dark ? .darkAqua : .aqua
        if panel.appearance?.name != appearance { panel.appearance = NSAppearance(named: appearance) }
        if self.anchor !== anchor {
            self.anchor = anchor
            watch(anchor)
        }
        place(panel)
        if parent !== window {
            if let parent { parent.removeChildWindow(panel) }
            window.addChildWindow(panel, ordered: .above)
            parent = window
        }
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func reposition() {
        guard let panel, isVisible else { return }
        place(panel)
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

    private func place(_ panel: NSPanel) {
        guard let anchor, let window = anchor.window, let request = content.request else { return }
        let search = request.search
        let suggestions = search.suggestions
        let listHeight = SearchDropdownLayout.listHeight(rows: suggestions.count,
                                                         headers: SearchDropdownView.headerCount(suggestions),
                                                         extraRows: SearchDropdownView.extraRows(search))
        let field = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let placement = SearchDropdownLayout.place(field: field, window: Self.bounds(of: window), listHeight: listHeight)
        if content.placement != placement { content.placement = placement }
        let frame = placement.frame.insetBy(dx: -Self.shadowRoom, dy: -Self.shadowRoom)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    // The window's content under the toolbar. In full screen the toolbar lives in a window of its own; the panel then
    // keeps to the screen.
    static func bounds(of window: NSWindow) -> NSRect {
        let content = window.convertToScreen(window.contentLayoutRect)
        guard content.height >= 200 else { return window.screen?.visibleFrame ?? window.frame }
        return content
    }

    private func makePanel() -> SearchDropdownPanelWindow {
        let panel = SearchDropdownPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320),
                                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.owner = self
        panel.identifier = NSUserInterfaceItemIdentifier(Self.identifier)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // The parent window resigning key already hides it; with this on, an inactive app never orders it in
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        let hosting = FirstMouseHostingView(rootView: SearchDropdownPanelRoot(content: content))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func watch(_ anchor: NSView) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard let window = anchor.window else { return }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            })
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            })
        }
    }
}

@MainActor @Observable
final class SearchDropdownPanelContent {
    /// Replaced only when what the panel draws changes; the field's newest `accept` is kept apart in `accept`.
    var request: SearchDropdownRequest?
    @ObservationIgnored var accept: (@MainActor (SearchSuggestion) -> Void)?
    var placement: SearchDropdownPlacement?
    var drawsMaterial = false
}

extension SearchDropdownRequest {
    /// The panel would draw the same for both; the closures are not compared.
    func draws(sameAs other: SearchDropdownRequest?) -> Bool {
        guard let other else { return false }
        return search === other.search && isPresented == other.isPresented && cursor == other.cursor
            && showsPreview == other.showsPreview && theme == other.theme
    }

    func accepting(_ accept: @escaping @MainActor (SearchSuggestion) -> Void) -> SearchDropdownRequest {
        SearchDropdownRequest(search: search, isPresented: isPresented, cursor: cursor, showsPreview: showsPreview,
                              theme: theme, accept: accept, keysChanged: keysChanged)
    }
}

struct SearchDropdownPanelRoot: View {
    let content: SearchDropdownPanelContent
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let theme = content.request?.theme ?? .light
        Group {
            if let request = content.request, let placement = content.placement {
                let forwarding = request.accepting { [content] suggestion in content.accept?(suggestion) }
                SearchDropdownView(request: forwarding, placement: placement)
                    .searchPanelSurface(material: content.drawsMaterial || reduceTransparency)
            }
        }
        .padding(SearchDropdownPanel.shadowRoom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.theme, theme)
        .environment(\.colorScheme, theme.appearance == .dark ? .dark : .light)
        .tint(theme.accentFill.color)
    }
}

final class SearchDropdownPanelWindow: NSPanel {
    weak var owner: SearchDropdownPanel?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// Showing, moving and hiding the panel waits for the next turn of the main queue, and the requests that arrive before
// it are folded into one. SwiftUI tracks every observed value read inside `updateNSView`, so the panel replacing its
// content there, after an earlier update had read it, would start the next update, without end.
final class SearchDropdownAnchorView: NSView {
    private enum Pending { case reposition, refresh }

    let panel = SearchDropdownPanel()
    /// What the field asks for now.
    var request: SearchDropdownRequest? {
        didSet { schedule(.refresh) }
    }
    var keysChanged: (@MainActor (Bool) -> Void)?
    /// How many times the panel was brought up to date.
    private(set) var refreshCount = 0
    private var pending: Pending?
    private var keyObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var responderObservation: NSKeyValueObservation?
    // The window gave up key: the suggestions stay away until it is key again, wherever its first responder is
    private var windowLeftKey = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        windowLeftKey = false
        guard let window else {
            panel.hide()
            reportKeysSoon()
            return
        }
        // SwiftUI's focus state for a field in the window's toolbar can stay off while the field has the keys, so the
        // field learns it from the window's first responder
        responderObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.reportKeysSoon() }
        }
        // Back in a key window, the suggestions the panel hid on leaving come back
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.windowLeftKey = false
                self.reportKeysSoon()
                if self.request != nil { self.schedule(.refresh) }
            }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windowLeftKey = true
                self?.reportKeysSoon()
            }
        }
        if request != nil { schedule(.refresh) }
    }

    isolated deinit {
        stopObserving()
    }

    private func stopObserving() {
        for observer in [keyObserver, resignObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        keyObserver = nil
        resignObserver = nil
        responderObservation = nil
    }

    /// True when the window's first responder is the text field this anchor sits under (its field editor included)
    /// and the window has not given up key since.
    var fieldHasTheKeys: Bool {
        guard let window, !windowLeftKey else { return false }
        var view = OverlayFocusKeeper.control(of: window.firstResponder)
        while let current = view, !(current is NSTextField) { view = current.superview }
        guard let field = view, field.window === window else { return false }
        let frame = field.convert(field.bounds, to: nil)
        return convert(bounds, to: nil).contains(NSPoint(x: frame.midX, y: frame.midY))
    }

    func reportKeys() {
        keysChanged?(fieldHasTheKeys)
    }

    // After the change that moved the keys, so the field's state never changes in the middle of a view update
    private func reportKeysSoon() {
        DispatchQueue.main.async { [weak self] in self?.reportKeys() }
    }

    // SwiftUI lays the anchor out inside its view update, so the panel follows on the next turn
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        schedule(.reposition)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        schedule(.reposition)
    }

    override func isAccessibilityElement() -> Bool { false }

    private func schedule(_ work: Pending) {
        guard pending != .refresh else { return }
        let scheduled = pending != nil
        pending = work
        guard !scheduled else { return }
        DispatchQueue.main.async { [weak self] in self?.applyPending() }
    }

    private func applyPending() {
        guard let work = pending else { return }
        pending = nil
        switch work {
        case .reposition:
            panel.reposition()
        case .refresh:
            refresh()
        }
    }

    /// Shows the panel for the latest request, or hides it.
    func refresh() {
        refreshCount += 1
        if let request, request.isPresented, window != nil {
            panel.show(request, below: self)
        } else {
            panel.hide()
        }
    }
}

struct SearchDropdownPanelAnchor: NSViewRepresentable {
    let request: SearchDropdownRequest

    func makeNSView(context: Context) -> SearchDropdownAnchorView { SearchDropdownAnchorView() }

    // Records the request only: the anchor applies it after this update
    func updateNSView(_ view: SearchDropdownAnchorView, context: Context) {
        view.keysChanged = request.keysChanged
        view.request = request
    }

    static func dismantleNSView(_ view: SearchDropdownAnchorView, coordinator: ()) {
        view.keysChanged = nil
        view.request = nil
        view.panel.hide()
    }
}

extension FloatingSearchDropdown {
    static let panel = FloatingSearchDropdown { request in AnyView(SearchDropdownPanelAnchor(request: request)) }
}

extension View {
    /// The toolbar's search field floats its suggestions in a child panel over the window.
    func floatsSearchDropdown() -> some View {
        environment(\.floatingSearchDropdown, .panel)
    }
}
