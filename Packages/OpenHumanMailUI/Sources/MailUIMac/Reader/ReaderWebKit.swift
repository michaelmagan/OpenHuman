import AppKit
import MailRender
import WebKit

@MainActor
public final class ReaderWebKit {
    public static let shared = ReaderWebKit()

    public enum Mode: Sendable, Hashable { case blocked, imagesAllowed }

    public static let ruleListIdentifier = "dev.openhuman.mail.block-all-remote.v1"
    public static let blockAllRemoteRules = """
    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},\
    {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]
    """
    public static let imagesRuleListIdentifier = "dev.openhuman.mail.images-only.v1.t\(TrackerList.version)"
    public static var imagesOnlyRules: String {
        let nonImage = #"{"trigger":{"url-filter":"^https?://","resource-type":["document","style-sheet","script","font","raw","svg-document","media","popup","ping","fetch","websocket","other"]},"action":{"type":"block"}}"#
        let sockets = #"{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}"#
        let trackers = TrackerList.contentRuleListJSON().dropFirst().dropLast()
        return "[" + nonImage + "," + sockets + (trackers.isEmpty ? "" : "," + trackers) + "]"
    }

    static let heightHandlerName = "ohHeight"
    static let linkHandlerName = "ohLink"
    static let quotesHandlerName = "ohQuotes"
    static let selectionHandlerName = "ohSelection"
    static let dateHandlerName = "ohDate"
    static let maxSelection = 20_000

    // Why: Math.ceil of the #oh-root height, since scrollHeight is floored at the viewport height
    public static let measureScript = """
    (function () {
      var handler = window.webkit.messageHandlers.\(heightHandlerName);
      var doc = document;
      var byId = Document.prototype.getElementById;
      var rect = Element.prototype.getBoundingClientRect;
      var docElement = Object.getOwnPropertyDescriptor(Document.prototype, 'documentElement').get;
      var clientWidth = Object.getOwnPropertyDescriptor(Element.prototype, 'clientWidth').get;
      var RO = window.ResizeObserver;
      var last = -1;
      var lastWidth = -1;
      var loaded = 0;
      function report(force) {
        var root = byId.call(doc, 'oh-root');
        if (!root) { return; }
        var h = Math.ceil(rect.call(root).height);
        var page = docElement.call(doc);
        var w = page ? clientWidth.call(page) : 0;
        if (h !== last || w !== lastWidth || force) { last = h; lastWidth = w; handler.postMessage([h, loaded, w]); }
      }
      doc.addEventListener('DOMContentLoaded', function () {
        report(false);
        var root = byId.call(doc, 'oh-root');
        if (RO && root) { new RO(function () { report(false); }).observe(root); }
      });
      window.addEventListener('load', function () { loaded = 1; report(true); });
    })();
    """

    public static let linkHoverScript = """
    (function () {
      var handler = window.webkit.messageHandlers.\(linkHandlerName);
      var closest = Element.prototype.closest;
      var rect = Element.prototype.getBoundingClientRect;
      var hrefOf = Object.getOwnPropertyDescriptor(HTMLAnchorElement.prototype, 'href').get;
      var current = null;
      function post(a) {
        if (a === current) { return; }
        current = a;
        if (!a) { handler.postMessage({}); return; }
        var r = rect.call(a);
        handler.postMessage({ href: String(hrefOf.call(a)), x: r.left, y: r.top, w: r.width, h: r.height });
      }
      document.addEventListener('mouseover', function (e) {
        var t = e.target;
        post(t && t.nodeType === 1 ? closest.call(t, 'a[href]') : null);
      }, true);
      document.addEventListener('mouseout', function (e) { if (!e.relatedTarget) { post(null); } }, true);
    })();
    """

    public static let quoteControlScript = """
    (function () {
      var handler = window.webkit.messageHandlers.\(quotesHandlerName);
      var doc = document;
      var all = Document.prototype.querySelectorAll;
      var closest = Element.prototype.closest;
      var setTitle = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'title').set;
      doc.addEventListener('DOMContentLoaded', function () {
        var s = all.call(doc, 'details.oh-quoted > summary');
        for (var i = 0; i < s.length; i++) {
          if (i === 0) { setTitle.call(s[i], 'Show quoted text  .'); } else { s[i].style.display = 'none'; }
        }
      });
      doc.addEventListener('click', function (e) {
        var t = e.target;
        var s = t && t.nodeType === 1 ? closest.call(t, 'details.oh-quoted > summary') : null;
        if (!s) { return; }
        e.preventDefault();
        handler.postMessage(1);
      }, true);
    })();
    """

    public static let selectionScript = """
    (function () {
      var handler = window.webkit.messageHandlers.\(selectionHandlerName);
      var getSelection = window.getSelection;
      var last = '';
      function report() {
        var s = getSelection.call(window);
        var text = s ? String(s).slice(0, \(maxSelection)) : '';
        if (text !== last) { last = text; handler.postMessage(text); }
      }
      document.addEventListener('DOMContentLoaded', function () { handler.postMessage(''); });
      document.addEventListener('mouseup', report, true);
      document.addEventListener('keyup', report, true);
      document.addEventListener('selectionchange', function () {
        var s = getSelection.call(window);
        if (!s || s.isCollapsed) { report(); }
      });
    })();
    """

    static func quotesScript(open: Bool) -> String {
        let title = open ? "Hide quoted text  ." : "Show quoted text  ."
        return "(function(){var d=document.querySelectorAll('details.oh-quoted');for(var i=0;i<d.length;i++){d[i].open=\(open);}"
            + "var s=document.querySelector('details.oh-quoted > summary');if(s){s.title='\(title)';}return d.length;})();"
    }

    public private(set) var ruleList: WKContentRuleList?
    public private(set) var imagesRuleList: WKContentRuleList?
    public private(set) var compileError: Error?
    public private(set) var imagesCompileError: Error?
    private let blockRules: String
    private let blockIdentifier: String
    private let imagesRules: String
    private let imagesIdentifier: String
    private var configurations: [Mode: WKWebViewConfiguration] = [:]
    private var preparing: Task<Void, Never>?
    let cidHandler = CIDSchemeHandler()
    let heightRouter = HeightMessageRouter()
    let linkRouter = LinkMessageRouter()
    let quotesRouter = QuoteMessageRouter()
    let selectionRouter = SelectionMessageRouter()
    let dateRouter = DateMessageRouter()
    let navigationPolicy = ReaderNavigationPolicy()
    let uiDelegate = ReaderUIDelegate()
    let pool = ReaderWebViewPool()

    public init(blockRules: String = ReaderWebKit.blockAllRemoteRules, blockIdentifier: String = ReaderWebKit.ruleListIdentifier,
                imagesRules: String = ReaderWebKit.imagesOnlyRules,
                imagesIdentifier: String = ReaderWebKit.imagesRuleListIdentifier) {
        self.blockRules = blockRules
        self.blockIdentifier = blockIdentifier
        self.imagesRules = imagesRules
        self.imagesIdentifier = imagesIdentifier
    }

    public var isPrepared: Bool { ruleList != nil || compileError != nil }

    public func prepare() async {
        if isPrepared { return }
        if let preparing { return await preparing.value }
        let task = Task { @MainActor in
            do {
                self.ruleList = try await Self.compile(blockRules, identifier: blockIdentifier)
            } catch {
                self.compileError = error
            }
            do {
                self.imagesRuleList = try await Self.compile(imagesRules, identifier: imagesIdentifier)
            } catch {
                self.imagesCompileError = error
            }
        }
        preparing = task
        await task.value
    }

    private static func compile(_ rules: String, identifier: String) async throws -> WKContentRuleList {
        guard let store = WKContentRuleListStore.default() else { throw ReaderWebKitError.noRuleListStore }
        if let cached = try? await store.contentRuleList(forIdentifier: identifier) { return cached }
        guard let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) else {
            throw ReaderWebKitError.noRuleList
        }
        return list
    }

    public func makeConfiguration(_ mode: Mode = .blocked) -> WKWebViewConfiguration? {
        if let configuration = configurations[mode] { return configuration }
        let list: WKContentRuleList? = switch mode {
        case .blocked: ruleList
        case .imagesAllowed: ruleList == nil ? nil : imagesRuleList
        }
        guard let list else { return nil }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.suppressesIncrementalRendering = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.setURLSchemeHandler(cidHandler, forURLScheme: URLPolicy.inlinePartScheme)
        let controller = WKUserContentController()
        controller.add(list)
        controller.add(heightRouter, contentWorld: .defaultClient, name: Self.heightHandlerName)
        controller.add(linkRouter, contentWorld: .defaultClient, name: Self.linkHandlerName)
        controller.add(quotesRouter, contentWorld: .defaultClient, name: Self.quotesHandlerName)
        controller.add(selectionRouter, contentWorld: .defaultClient, name: Self.selectionHandlerName)
        controller.add(dateRouter, contentWorld: .defaultClient, name: Self.dateHandlerName)
        controller.addUserScript(WKUserScript(source: Self.quoteControlScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .defaultClient))
        controller.addUserScript(WKUserScript(source: Self.measureScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .defaultClient))
        controller.addUserScript(WKUserScript(source: Self.linkHoverScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .defaultClient))
        controller.addUserScript(WKUserScript(source: Self.selectionScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .defaultClient))
        config.userContentController = controller
        configurations[mode] = config
        return config
    }

    public func mode(for message: RenderedMessage, imagesAllowed: Bool) -> Mode? {
        if imagesAllowed, makeConfiguration(.imagesAllowed) != nil { return .imagesAllowed }
        return makeConfiguration(.blocked) == nil ? nil : .blocked
    }
}

public enum ReaderWebKitError: Error { case noRuleListStore, noRuleList }

extension ReaderWebKit {
    static let dateTextScript = """
    (function () {
      var root = document.getElementById('oh-root') || document.body;
      return root ? String(root.innerText || '') : '';
    })();
    """

    // Wraps matches through DOM calls only, so no HTML is ever parsed from message text
    static func dateMarkScript(_ phrasesJSON: String) -> String {
        """
        (function (phrases) {
          var root = document.getElementById('oh-root') || document.body;
          if (!root || root.getAttribute('data-oh-dates') === '1') { return 0; }
          root.setAttribute('data-oh-dates', '1');
          if (!document.getElementById('oh-date-style')) {
            var style = document.createElement('style');
            style.id = 'oh-date-style';
            style.textContent = '.oh-date { text-decoration-line: underline; text-decoration-style: solid; '
              + 'text-decoration-thickness: 1px; text-underline-offset: 3px; '
              + 'text-decoration-color: color-mix(in srgb, currentColor 45%, transparent); cursor: pointer; '
              + 'border-radius: 3px; transition: background-color 120ms ease, text-decoration-color 120ms ease; } '
              + '.oh-date:hover { text-decoration-color: currentColor; '
              + 'background-color: color-mix(in srgb, currentColor 10%, transparent); }';
            (document.head || document.documentElement).appendChild(style);
          }
          var handler = window.webkit.messageHandlers.\(dateHandlerName);
          var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
          var nodes = [];
          var node;
          while ((node = walker.nextNode())) {
            var parent = node.parentElement;
            if (parent && !parent.closest('a, style, script, .oh-date')) { nodes.push(node); }
          }
          var count = 0;
          phrases.forEach(function (phrase, index) {
            if (typeof phrase !== 'string' || phrase.length < 3) { return; }
            for (var i = 0; i < nodes.length; i++) {
              var at = nodes[i].data.indexOf(phrase);
              if (at < 0) { continue; }
              var match = nodes[i].splitText(at);
              var rest = match.splitText(phrase.length);
              var span = document.createElement('span');
              span.className = 'oh-date';
              span.setAttribute('data-oh-date', String(index));
              span.setAttribute('role', 'link');
              span.title = 'Show on the calendar';
              match.parentNode.insertBefore(span, match);
              span.appendChild(match);
              nodes.splice(i, 1, rest);
              count += 1;
              break;
            }
          });
          root.addEventListener('click', function (e) {
            var t = e.target;
            var el = t && t.nodeType === 1 ? t.closest('.oh-date') : null;
            if (!el) { return; }
            e.preventDefault();
            e.stopPropagation();
            handler.postMessage(Number(el.getAttribute('data-oh-date')));
          }, true);
          return count;
        })(\(phrasesJSON));
        """
    }
}

@MainActor
final class DateMessageRouter: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = message.webView as? ReaderWebView, let number = message.body as? NSNumber else { return }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value < Double(CalendarDateMentionLimit.max), value == value.rounded() else { return }
        view.dateClicked(Int(value))
    }
}

enum CalendarDateMentionLimit {
    static let max = 50
}

@MainActor
final class HeightMessageRouter: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = message.webView as? ReaderWebView, let (height, loaded, width) = Self.parse(message.body) else {
            return
        }
        view.contentHeightDidChange(height, loaded: loaded, width: width)
    }

    static func parse(_ body: Any) -> (CGFloat, Bool, CGFloat?)? {
        let parts = (body as? [NSNumber]) ?? (body as? NSNumber).map { [$0] } ?? []
        guard let first = parts.first, parts.count <= 3 else { return nil }
        let height = first.doubleValue
        guard height.isFinite, height >= 0, height <= 1_000_000 else { return nil }
        var width: CGFloat?
        if parts.count == 3 {
            let value = parts[2].doubleValue
            guard value.isFinite, value >= 0, value <= 1_000_000 else { return nil }
            width = CGFloat(value)
        }
        return (CGFloat(height), parts.count >= 2 && parts[1].intValue == 1, width)
    }
}

@MainActor
final class LinkMessageRouter: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = message.webView as? ReaderWebView else { return }
        view.linkHovered(Self.parse(message.body))
    }

    static func parse(_ body: Any) -> ReaderWebView.HoveredLink? {
        guard let dict = body as? [String: Any], let href = dict["href"] as? String, href.utf8.count <= 8_192,
              let url = URL(string: href), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        func number(_ key: String) -> CGFloat? {
            guard let n = dict[key] as? NSNumber, n.doubleValue.isFinite, abs(n.doubleValue) < 10_000_000 else { return nil }
            return CGFloat(n.doubleValue)
        }
        guard let x = number("x"), let y = number("y"), let w = number("w"), let h = number("h"), w >= 0, h >= 0 else {
            return ReaderWebView.HoveredLink(url: url, rect: nil)
        }
        return ReaderWebView.HoveredLink(url: url, rect: CGRect(x: x, y: y, width: w, height: h))
    }
}

@MainActor
final class QuoteMessageRouter: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = message.webView as? ReaderWebView, (message.body as? NSNumber)?.intValue == 1 else { return }
        view.quoteControlClicked()
    }
}

@MainActor
final class SelectionMessageRouter: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = message.webView as? ReaderWebView, let text = Self.parse(message.body) else { return }
        view.selectionChanged(text)
    }

    static func parse(_ body: Any) -> String? {
        guard let text = body as? String else { return nil }
        return text.count > ReaderWebKit.maxSelection ? String(text.prefix(ReaderWebKit.maxSelection)) : text
    }
}

@MainActor
final class ReaderUIDelegate: NSObject, WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}
