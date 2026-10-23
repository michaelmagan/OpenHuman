import AppKit
import MailRender
import OpenHumanCore
import WebKit

@MainActor
protocol ReaderWebViewOwner: AnyObject {
    func readerWebView(_ view: ReaderWebView, hovered link: ReaderWebView.HoveredLink?)
    func readerWebView(_ view: ReaderWebView, activated url: URL, modifiers: NSEvent.ModifierFlags)
    func readerWebView(_ view: ReaderWebView, keyDown event: NSEvent) -> Bool
    func readerWebViewFind(_ view: ReaderWebView)
    func readerWebView(_ view: ReaderWebView, selected text: String)
}

extension ReaderWebViewOwner {
    func readerWebView(_ view: ReaderWebView, selected text: String) {}
}

@MainActor
public final class ReaderWebView: WKWebView {
    public struct HoveredLink: Equatable, Sendable {
        public let url: URL
        public let rect: CGRect?
    }

    static var heightCache = BoundedLRU<String, CGFloat>(countLimit: 5_000)

    public let mode: ReaderWebKit.Mode
    private var heightConstraint: NSLayoutConstraint!
    private var contentHash: UInt64 = 0
    private var shown = false
    private(set) var currentNavigation: WKNavigation?
    private var committed = false
    private var hoverArea: NSTrackingArea?
    public private(set) var rendered: RenderedMessage?
    public var onHeightChange: ((CGFloat) -> Void)?
    public var onShown: (() -> Void)?
    public var onToggleQuotes: (() -> Void)?
    public var onDateClicked: ((Int) -> Void)?
    public var isShown: Bool { shown }
    public private(set) var measuredHeight: CGFloat?
    private var cssHeight: CGFloat?
    var awaitsLayoutWidth = false
    private var pendingReport: (cssHeight: CGFloat, loaded: Bool, width: CGFloat?)?
    private var selfGrowth = ReaderSelfGrowthGuard()
    var inlineParts: InlinePartSource?
    weak var owner: ReaderWebViewOwner?
    public private(set) var hoveredLink: HoveredLink?
    public private(set) var loadCount = 0

    init(mode: ReaderWebKit.Mode, configuration: WKWebViewConfiguration, webKit: ReaderWebKit) {
        self.mode = mode
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 10), configuration: configuration)
        navigationDelegate = webKit.navigationPolicy
        uiDelegate = webKit.uiDelegate
        allowsMagnification = false
        allowsBackForwardNavigationGestures = false
        allowsLinkPreview = false
        if responds(to: NSSelectorFromString("_setDrawsBackground:")) { setValue(false, forKey: "drawsBackground") }
        underPageBackgroundColor = .clear
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: 44)
        heightConstraint.isActive = true
        alphaValue = 0
        setAccessibilityLabel("Message body")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // nil when the content rule list did not compile: fail closed rather than show HTML unblocked
    public static func make(for message: RenderedMessage, width: CGFloat, webKit: ReaderWebKit = .shared,
                            imagesAllowed: Bool = false, zoom: CGFloat = 1) -> ReaderWebView? {
        guard let mode = webKit.mode(for: message, imagesAllowed: imagesAllowed),
              let view = webKit.pool.dequeue(mode, webKit: webKit) else { return nil }
        view.load(message, width: width, zoom: zoom)
        return view
    }

    func load(_ message: RenderedMessage, width: CGFloat, zoom: CGFloat) {
        rendered = message
        contentHash = message.contentHash
        shown = false
        committed = false
        measuredHeight = nil
        cssHeight = nil
        pendingReport = nil
        selfGrowth = ReaderSelfGrowthGuard()
        pageZoom = zoom
        alphaValue = 0
        setFrameSize(NSSize(width: max(width, 100), height: frame.height))
        heightConstraint.constant = Self.cachedHeight(hash: message.contentHash, width: width, zoom: zoom)
            ?? Self.estimatedHeight(message, width: width, zoom: zoom)
        loadCount += 1
        currentNavigation = loadHTMLString(message.html, baseURL: URL(string: "about:blank"))
    }

    static func estimatedHeight(_ message: RenderedMessage, width: CGFloat, zoom: CGFloat = 1) -> CGFloat {
        let charsPerLine = max(20, width / (7.5 * zoom))
        let lines = (CGFloat(message.textLength) / charsPerLine).rounded(.up)
        return min(max(44, lines * 22 * zoom), 4_000)
    }

    static func widthBucket(_ width: CGFloat) -> Int { Int(width / 40) }

    static func cacheKey(hash: UInt64, width: CGFloat, zoom: CGFloat) -> String {
        "\(hash):\(Int((zoom * 100).rounded())):\(widthBucket(width))"
    }

    static func cachedHeight(hash: UInt64, width: CGFloat, zoom: CGFloat = 1) -> CGFloat? {
        heightCache.value(for: cacheKey(hash: hash, width: width, zoom: zoom))
    }

    func navigationCommitted(_ navigation: WKNavigation?) {
        if navigation === currentNavigation { committed = true }
    }

    func contentHeightDidChange(_ reported: CGFloat, loaded: Bool = true, width: CGFloat? = nil) {
        guard committed, rendered != nil else { return }
        let stoppedBefore = selfGrowth.stopped
        let cssHeight = selfGrowth.height(for: reported, width: width)
        if selfGrowth.stopped, !stoppedBefore {
            Log(.app).notice("reader: the body grew by the same step \(ReaderSelfGrowthGuard.limit) times; "
                + "it stays at \(Int(cssHeight)) pt")
        }
        self.cssHeight = cssHeight
        let height = (cssHeight * pageZoom).rounded(.up)
        measuredHeight = height
        heightConstraint.constant = max(height, 1)
        let atViewWidth = width.map { abs($0 - bounds.width / pageZoom) <= 1 } ?? true
        if awaitsLayoutWidth || !atViewWidth {
            pendingReport = atViewWidth ? (cssHeight, loaded || pendingReport?.loaded == true, width) : nil
            onHeightChange?(height)
            return
        }
        if loaded { Self.heightCache.insert(height, for: Self.cacheKey(hash: contentHash, width: bounds.width, zoom: pageZoom)) }
        if !shown, loaded || mode == .imagesAllowed {
            shown = true
            alphaValue = 1
            onShown?()
        }
        onHeightChange?(height)
    }

    func layoutWidthSettled() {
        guard awaitsLayoutWidth else { return }
        awaitsLayoutWidth = false
        guard let report = pendingReport else { return }
        pendingReport = nil
        contentHeightDidChange(report.cssHeight, loaded: report.loaded, width: report.width)
    }

    func linkHovered(_ link: HoveredLink?) {
        guard committed, link != hoveredLink else { return }
        hoveredLink = link
        owner?.readerWebView(self, hovered: link)
    }

    func quoteControlClicked() {
        guard committed, rendered != nil else { return }
        onToggleQuotes?()
    }

    func linkActivated(_ url: URL, modifiers: NSEvent.ModifierFlags) {
        owner?.readerWebView(self, activated: url, modifiers: modifiers)
    }

    func selectionChanged(_ text: String) {
        guard committed, rendered != nil else { return }
        owner?.readerWebView(self, selected: text)
    }

    func pageText() async -> String? {
        guard committed, rendered != nil else { return nil }
        let text = try? await evaluateJavaScript(ReaderWebKit.dateTextScript, in: nil, contentWorld: .defaultClient)
        return text as? String
    }

    func underlineDates(_ phrases: [String]) async {
        guard committed, rendered != nil, !phrases.isEmpty,
              let data = try? JSONEncoder().encode(Array(phrases.prefix(CalendarDateMentionLimit.max))),
              let json = String(data: data, encoding: .utf8) else { return }
        _ = try? await evaluateJavaScript(ReaderWebKit.dateMarkScript(json), in: nil, contentWorld: .defaultClient)
    }

    func dateClicked(_ index: Int) {
        guard committed, rendered != nil else { return }
        onDateClicked?(index)
    }

    func contentProcessTerminated() {
        guard let rendered else { return }
        load(rendered, width: bounds.width, zoom: pageZoom)
    }

    func resetForPool() {
        removeFromSuperview()
        stopLoading()
        owner = nil
        inlineParts = nil
        onHeightChange = nil
        onShown = nil
        onToggleQuotes = nil
        onDateClicked = nil
        rendered = nil
        hoveredLink = nil
        measuredHeight = nil
        cssHeight = nil
        pendingReport = nil
        selfGrowth = ReaderSelfGrowthGuard()
        awaitsLayoutWidth = false
        shown = false
        committed = false
        alphaValue = 0
        pageZoom = 1
        currentNavigation = loadHTMLString("<!doctype html><html><body></body></html>", baseURL: URL(string: "about:blank"))
    }

    func setZoom(_ zoom: CGFloat) {
        guard pageZoom != zoom else { return }
        pageZoom = zoom
        if let cssHeight { contentHeightDidChange(cssHeight, loaded: shown) }
    }

    func setQuotesExpanded(_ open: Bool) async {
        _ = try? await evaluateJavaScript(ReaderWebKit.quotesScript(open: open), in: nil, contentWorld: .defaultClient)
    }

    func findNext(_ text: String, backwards: Bool) async -> Bool {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = false
        configuration.caseSensitive = false
        let result: WKFindResult = await withCheckedContinuation { continuation in
            __find(text, with: configuration) { continuation.resume(returning: $0) }
        }
        return result.matchFound
    }

    func clearSelection() async {
        _ = try? await evaluateJavaScript("window.getSelection().removeAllRanges(); 0", in: nil, contentWorld: .defaultClient)
    }

    func selectionRect() async -> CGRect? {
        let script = """
        (function(){var s=window.getSelection();if(!s||s.rangeCount===0){return null;}\
        var r=s.getRangeAt(0).getBoundingClientRect();return [r.left,r.top,r.width,r.height];})();
        """
        guard let values = try? await evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) as? [NSNumber],
              values.count == 4 else { return nil }
        let z = pageZoom
        return CGRect(x: CGFloat(values[0].doubleValue) * z, y: CGFloat(values[1].doubleValue) * z,
                      width: CGFloat(values[2].doubleValue) * z, height: CGFloat(values[3].doubleValue) * z)
    }

    public override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    public override func keyDown(with event: NSEvent) {
        if owner?.readerWebView(self, keyDown: event) == true { return }
        super.keyDown(with: event)
    }

    public override func performTextFinderAction(_ sender: Any?) {
        owner?.readerWebViewFind(self)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if hoveredLink != nil {
            hoveredLink = nil
            owner?.readerWebView(self, hovered: nil)
        }
    }

    public override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        Self.filterContextMenu(menu)
    }

    static let allowedMenuItems: Set<String> = [
        "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierCopyImage",
        "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierTranslate", "WKMenuItemIdentifierSpeechMenu",
    ]

    static func filterContextMenu(_ menu: NSMenu) {
        for item in menu.items.reversed() {
            let keep = item.isSeparatorItem || item.identifier.map { allowedMenuItems.contains($0.rawValue) } == true
            if !keep { menu.removeItem(item) }
        }
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        var previousWasSeparator = false
        for item in menu.items.reversed() {
            if item.isSeparatorItem, previousWasSeparator { menu.removeItem(item) }
            previousWasSeparator = item.isSeparatorItem
        }
    }
}

// A body that grows by the same step on every report is following its own height: content sized from the viewport
// (which is as tall as the view) with something below it. After `limit` such steps in a row the height stops growing
// until the next load or another width; it can still shrink.
struct ReaderSelfGrowthGuard {
    static let limit = 32

    private var last: CGFloat?
    private var step: CGFloat?
    private var streak = 0
    private var width: CGFloat?
    private(set) var ceiling: CGFloat?

    var stopped: Bool { ceiling != nil }

    mutating func height(for reported: CGFloat, width newWidth: CGFloat?) -> CGFloat {
        if let newWidth, let width, abs(newWidth - width) > 1 { self = ReaderSelfGrowthGuard() }
        if let newWidth { width = newWidth }
        if let ceiling { return min(reported, ceiling) }
        defer { last = reported }
        guard let last, reported > last else {
            streak = 0
            step = nil
            return reported
        }
        let delta = reported - last
        streak = step.map { abs(delta - $0) <= 1 } == true ? streak + 1 : 1
        step = delta
        if streak >= Self.limit { ceiling = reported }
        return reported
    }
}
