import AppKit
import MailFeatures
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI

@MainActor
final class InlineComposerView: NSView {
    let session: ComposeSession
    private let layoutModel = InlineComposerLayout()
    private let hosting: NSHostingView<InlineComposerRoot>

    init(session: ComposeSession, manager: ComposeManager, theme: ThemeTokens) {
        self.session = session
        let resolved = Self.resolvedTheme(for: theme)
        hosting = NSHostingView(rootView: InlineComposerRoot(session: session, manager: manager, layout: layoutModel,
                                                             theme: resolved))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.sizingOptions = [.intrinsicContentSize]
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(false)
        identifier = NSUserInterfaceItemIdentifier("reader.inlineComposer")
        layoutModel.reveal = ComposerReveal { [weak self] frame in self?.reveal(frame) }
    }

    private var revealedCardFrame: CGRect?

    /// The AI panel's frame in this view. The card reports it in its own coordinates while it is still being laid
    /// out, so it is moved by where the card sits in the hosting view and converted when read.
    var revealedPanelFrame: NSRect? {
        revealedCardFrame.map {
            hosting.convert($0.offsetBy(dx: layoutModel.cardOrigin.x, dy: layoutModel.cardOrigin.y), to: self)
        }
    }

    func reveal(_ cardFrame: CGRect) {
        revealedCardFrame = cardFrame
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.enclosingScrollView?.documentView?.layoutSubtreeIfNeeded()
            guard let frame = self.revealedPanelFrame else { return }
            _ = self.scrollToVisible(frame.insetBy(dx: 0, dy: -ComposerRevealMetrics.margin))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static func resolvedTheme(for tokens: ThemeTokens) -> ResolvedTheme {
        let shared = ComposerWindows.shared.theme
        if shared.tokens == tokens { return shared }
        return ResolvedTheme(themeID: shared.themeID, themeName: shared.themeName, accentID: shared.accentID,
                             appearance: ReaderAppearance.appearance(of: tokens), tokens: tokens)
    }

    var cardFrame: NSRect { bounds }

    var hostMessage: MessageContainerView? {
        var view = superview
        while let current = view, !(current is MessageContainerView) { view = current.superview }
        return view as? MessageContainerView
    }

    override func layout() {
        super.layout()
        updateLayoutModel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayoutModel()
    }

    private static let updatesPerTurn = 4
    private var updatesThisTurn = 0
    private var reportedRepeats = false
    private var busyTurns = InlineComposerBusyTurns()

    // The hosting view's content reads the width and the editor's cap, so each change asks for another constraint
    // pass. A few changes in one turn of the main queue are applied at once; more wait for the next turn, so something
    // that answers each change with a new width (a scroll bar coming and going) cannot hold AppKit in a loop of
    // constraint passes.
    private func updateLayoutModel() {
        guard let change = changedLayout() else { return }
        guard updatesThisTurn < Self.updatesPerTurn else {
            if !reportedRepeats {
                reportedRepeats = true
                Log(.app).notice("inline composer: layout changed \(updatesThisTurn) times in one turn; the rest waits")
            }
            return
        }
        if updatesThisTurn == 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let busy = self.updatesThisTurn >= Self.updatesPerTurn
                if self.busyTurns.turnEnded(busy: busy) {
                    #if DEBUG
                    Log(.app).notice("inline composer: the layout kept changing for "
                        + "\(InlineComposerBusyTurns.reportAfter) turns in a row")
                    #endif
                }
                self.updatesThisTurn = 0
                self.updateLayoutModel()
            }
        }
        updatesThisTurn += 1
        if let width = change.width { layoutModel.width = width }
        if let cap = change.cap { layoutModel.maxEditorHeight = cap }
    }

    // Sub-point changes are ignored
    private func changedLayout() -> (width: CGFloat?, cap: CGFloat?)? {
        var width: CGFloat?
        var cap: CGFloat?
        if bounds.width > 0, abs(layoutModel.width - bounds.width) >= 1 { width = bounds.width }
        if let visible = enclosingScrollView?.contentView.bounds.height, visible > 0 {
            let wanted = max(ComposerMetrics.editorMinDocked, (visible * ComposerMetrics.dockedMaxFraction).rounded())
            if abs(layoutModel.maxEditorHeight - wanted) >= 1 { cap = wanted }
        }
        return width == nil && cap == nil ? nil : (width, cap)
    }

    var hasKeyboardFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    func focusIfRequested(attempt: Int = 0, didFocus: @escaping @MainActor () -> Void) {
        guard session.focusRequest != session.focusHandled, window != nil else { return }
        let request = session.focusRequest
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.session.focusRequest == request else { return }
            if self.session.mode == .forward, self.session.to.tokens.isEmpty {
                self.session.focusHandled = request
                didFocus()
                return
            }
            guard let editor = self.session.editor else {
                if attempt < 10 { self.focusIfRequested(attempt: attempt + 1, didFocus: didFocus) }
                return
            }
            editor.focusEditor()
            self.session.focusHandled = request
            didFocus()
        }
    }
}

// Turns of the main queue in a row that used up their layout updates. Something that keeps answering each width with
// another never settles; this counts it so it is reported once. It changes nothing in the layout.
struct InlineComposerBusyTurns {
    static let reportAfter = 60
    private(set) var inARow = 0
    private(set) var reported = false

    // Whether this turn is the one to report
    mutating func turnEnded(busy: Bool) -> Bool {
        inARow = busy ? inARow + 1 : 0
        guard inARow >= Self.reportAfter, !reported else { return false }
        reported = true
        return true
    }
}

@MainActor @Observable
final class InlineComposerLayout {
    var width: CGFloat = 600
    var maxEditorHeight: CGFloat = 400
    /// Where the card sits in the hosting view. The hosting view takes the card's ideal height, which can differ
    /// from the height it is laid out at, and then centres it.
    @ObservationIgnored var cardOrigin: CGPoint = .zero
    @ObservationIgnored var reveal: ComposerReveal?
}

enum ComposerRevealMetrics {
    static let margin: CGFloat = 12
}

struct InlineComposerRoot: View {
    static let space = "inlineComposer.host"

    let session: ComposeSession
    let manager: ComposeManager
    let layout: InlineComposerLayout
    let theme: ResolvedTheme

    var body: some View {
        ComposerCard(session: session, manager: manager, onClose: { manager.close(session) }) {
            ComposerBody(session: session, manager: manager, theme: theme.tokens, focusOnAppear: false,
                         placeholder: ComposerEditor.placeholder(for: session.mode), growsWithContent: true,
                         minHeight: ComposerMetrics.editorMinDocked, maxHeight: layout.maxEditorHeight,
                         onClose: { manager.close(session) })
        }
        .frame(width: layout.width)
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named(Self.space)).origin } action: { origin in
            layout.cardOrigin = origin
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: Self.space)
        .floatsCompletions()
        .shortcutTipRoot()
        .environment(\.composerReveal, layout.reveal)
        .environment(\.theme, theme)
        .environment(\.colorScheme, theme.appearance == .dark ? .dark : .light)
        .tint(theme.accentFill.color)
    }
}
