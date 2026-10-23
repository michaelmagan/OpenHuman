import Foundation
import MailModel
import MailTheme
import Testing
@testable import MailRender

@Test(arguments: hostileVectors, RenderVariant.all)
func hostileVectorIsNeutralized(_ vector: HostileVector, _ variant: RenderVariant) throws {
    guard let rendered = variant.render(vector.html) else { return }
    let problems = try SafetyInvariants.violations(in: rendered.html, allowRemote: variant.allowRemote)
    #expect(problems.isEmpty, "\(vector.name) [\(variant.testDescription)]: \(problems)\n\(rendered.html.prefix(3000))")
}

@Test func hostileCorpusIsLargeEnough() {
    #expect(hostileVectors.count >= 150)
    #expect(Set(hostileVectors.map(\.name)).count == hostileVectors.count, "vector names are unique")
}

@Test func randomHostileCombinationsStaySafe() throws {
    let fragments = [
        "<script>alert(1)</script>", "<img src=x onerror=alert(1)>", "<a href=\"javascript:alert(1)\">", "</a>",
        "<svg onload=alert(1)>", "<math><mtext>", "<style>", "</style>", "@import url(https://e.example/x.css);",
        "p{background:url(https://e.example/a.png)}", "<table>", "<tr><td>", "</table>", "<div style=\"",
        "background:url(javascript:alert(1))", "\">", "<!--", "-->", "<noscript>", "</noscript>", "<template>",
        "<iframe src=x>", "<form action=x>", "<base href=x>", "<meta http-equiv=refresh content=0>", "<p title=\"",
        "\" onclick=alert(1)", "<details open ontoggle=alert(1)>", "<blockquote type=cite>", "&lt;script&gt;",
        "<div class=\"oh-quoted\" id=\"oh-root\">", "<img src=\"https://t.example/o.gif\" width=1 height=1>",
        "<a href=\"https://evil.example\">https://bank.example</a>", "<font color=\"#000\">", "<td bgcolor=\"#fff\">",
        "text ", "\u{202E}", "<xmp>", "</xmp>", "<plaintext>", "<textarea>", "</textarea>", "<object data=x>",
    ]
    var generator = SplitMix64(seed: 0x0E07)
    for round in 0..<400 {
        var html = ""
        for _ in 0..<(4 + Int(generator.next() % 16)) { html += fragments[Int(generator.next() % UInt64(fragments.count))] }
        let variant = RenderVariant.all[round % RenderVariant.all.count]
        guard let rendered = variant.render(html) else { continue }
        let problems = try SafetyInvariants.violations(in: rendered.html, allowRemote: variant.allowRemote)
        #expect(problems.isEmpty, "round \(round): \(html)\n\(problems)")
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func sanitize(_ html: String, allowRemote: Bool = false) -> SanitizedHTML {
    HTMLSanitizer.sanitize(html, options: SanitizerOptions(allowRemoteImages: allowRemote))
}

@Test func safeLinkKeepsHrefDropsTargetAndHandlerAddsRel() {
    let out = sanitize("<a href=\"https://example.com/a?x=1&amp;y=2\" target=\"_blank\" onclick=\"x()\">ok</a>").bodyHTML
    #expect(out == "<a href=\"https://example.com/a?x=1&amp;y=2\" rel=\"noopener noreferrer\">ok</a>")
}

@Test func mailtoLinksSurvive() {
    #expect(sanitize("<a href=\"mailto:dana@example.com\">Dana</a>").bodyHTML.contains("href=\"mailto:dana@example.com\""))
}

@Test func remoteImagesAreBlockedCountedAndMarked() {
    let s = sanitize("<img src=\"https://images.example/hero.png\" alt=\"Hero\" width=\"600\"><p style=\"background:url(https://x.example/b.png);color:red\">t</p>")
    #expect(s.remoteReferences == 2)
    #expect(s.blockedRemote == 2)
    #expect(s.trackers == 0)
    #expect(s.bodyHTML.contains("<span class=\"oh-placeholder\">Hero</span>"))
    #expect(!s.bodyHTML.contains("<img"))
    #expect(s.bodyHTML.contains("<p style=\"color:red\">t</p>"))
    #expect(!s.bodyHTML.contains("images.example"))
    let original = HTMLSanitizer.sanitize("<img src=\"https://images.example/hero.png\" alt=\"Hero\" width=\"600\">",
                                          options: SanitizerOptions(trimBlankSpace: false))
    #expect(original.blockedRemote == 1)
    #expect(original.bodyHTML == "<img class=\"oh-blocked\" alt=\"Hero\" width=\"600\">")
}

@Test func remoteImagesStayWhenAllowed() {
    let s = sanitize("<img src=\"https://images.example/hero.png\">", allowRemote: true)
    #expect(s.remoteReferences == 1)
    #expect(s.blockedRemote == 0)
    #expect(s.bodyHTML.contains("src=\"https://images.example/hero.png\""))
}

@Test func trackerHostIsRemovedEvenWhenRemoteAllowed() {
    let options = SanitizerOptions(allowRemoteImages: true, trackerHosts: ["tracker.example"])
    let s = HTMLSanitizer.sanitize("<img src=\"https://pixel.tracker.example/o.gif\" width=\"20\" height=\"20\">", options: options)
    #expect(s.trackers == 1)
    #expect(s.trackerReferences == 1)
    #expect(s.trackerDomains == ["tracker.example"])
    #expect(!s.bodyHTML.contains("tracker.example"))
}

@Test func bundledTrackerHostsAndOpenPathsAreRemoved() {
    let s = sanitize("""
        <img src="https://us5.list-manage.com/track/open.php?u=1" width="40" height="40">
        <img src="https://news.example/wf/open?upn=x" width="30" height="30">
        <div style="background:url(https://o.sendgrid.net/x.gif)">x</div>
        <img src="https://images.example/real.png" width="300" height="100">
        """, allowRemote: true)
    #expect(s.trackers == 3)
    #expect(s.trackerReferences == 3)
    #expect(s.blockedRemote == 0)
    #expect(s.remoteReferences == 4)
    #expect(s.trackerDomains == ["list-manage.com", "news.example", "sendgrid.net"])
    #expect(s.bodyHTML.contains("https://images.example/real.png"))
}

@Test func trackingPixelsAreRemoved() {
    let s = sanitize("<p>a</p><img src=\"https://t.example/o.gif\" width=\"1\" height=\"1\"><img src=\"cid:x\" width=\"0\"><img src=\"https://t.example/h.gif\" style=\"max-height:0\">")
    #expect(s.trackers == 3)
    #expect(s.remoteReferences == 2)
    #expect(s.trackerReferences == 2)
    #expect(s.bodyHTML == "<p>a</p>")
}

@Test func cidImagesAreRewrittenAndListed() {
    let s = sanitize("<img src=\"cid:logo@example\"><div style=\"background:url(cid:bg%40example)\">x</div><img src=\"CID:logo@example\">")
    #expect(s.bodyHTML.contains("src=\"ohcid:logo@example\""))
    #expect(s.bodyHTML.contains("url(&quot;ohcid:bg%40example&quot;)"))
    #expect(s.inlineContentIDs == ["logo@example", "bg@example"])
    #expect(s.remoteReferences == 0)
}

@Test func dataImagesAllowedOnlyForRasterTypes() {
    #expect(sanitize("<img src=\"data:image/png;base64,iVBORw0KGgo=\">").bodyHTML.contains("src=\"data:image/png;base64,"))
    #expect(!sanitize("<img src=\"data:image/svg+xml;base64,PHN2Zy8+\">").bodyHTML.contains("src="))
    #expect(!sanitize("<img src=\"data:text/html,hi\">").bodyHTML.contains("src="))
}

@Test func stylesheetsAreScopedUnderTheBodyWrapper() {
    let s = sanitize("<html><head><style>p { color: red } body { margin: 0 } html body > table, :root .x, body.dark h1 { padding: 1px } @import url(https://e.example/x.css); .x { background: url(https://e.example/a.png) }</style></head><body><p>x</p><style>a:hover{color:blue}</style></body></html>")
    #expect(s.headCSS == [
        ".oh-body p{color:red}.oh-body{margin:0}.oh-body > table,.oh-body .x,.oh-body.dark h1{padding:1px}",
        ".oh-body a:hover{color:blue}",
    ])
    #expect(s.blockedRemote == 1)
}

@Test func rulesNamingOurHooksAreDropped() {
    let s = sanitize("<style>#oh-root{display:none} .oh-quoted{display:none} [class~=\"oh-body\"]{color:red} .ok{color:red}</style>")
    #expect(s.headCSS == [".oh-body .ok{color:red}"])
}

@Test func mediaQueriesKeepSafeRulesAndKeyframesAreNotScoped() {
    let s = sanitize("<style>@media (max-width: 600px) { .a { width: 100% !important } .b { background: url(https://e.example/m.png) } } @keyframes pulse { from { opacity: 0 } 50% { opacity: .5 } to { opacity: 1 } }</style>")
    let css = s.headCSS.joined()
    #expect(css.contains("@media (max-width: 600px){.oh-body .a{width:100% !important}}"))
    #expect(css.contains("@keyframes pulse{from{opacity:0}50%{opacity:.5}to{opacity:1}}"))
    #expect(!css.contains("e.example"))
}

@Test func positionFixedAndZIndexAreNeutralized() {
    let s = sanitize("<div style=\"position: fixed; top: 0; z-index: 99999\">x</div>")
    #expect(s.bodyHTML == "<div style=\"top:0;z-index:100\">x</div>")
}

@Test func absurdLengthsAreClamped() {
    let s = sanitize("<div style=\"height: 99999999px; width: 1e308px; font-size: 5000em; margin: -50000pt\">x</div>")
    #expect(s.bodyHTML.contains("height:10000px"))
    #expect(s.bodyHTML.contains("width:10000px"))
    #expect(s.bodyHTML.contains("font-size:1000em"))
    #expect(s.bodyHTML.contains("margin:-10000pt"))
    let table = sanitize("<table><tr><td width=\"999999\" colspan=\"5\" height=\"50%\">x</td></tr></table>").bodyHTML
    #expect(table.contains("width=\"10000\" colspan=\"5\" height=\"50%\""))
}

// The reader's viewport is as tall as the message, so a length that follows it would grow the message without end
@Test func viewportHeightLengthsUseAFixedViewport() {
    let s = sanitize("<div style=\"height: 100vh\">hero</div><div style=\"min-height: calc(50dvh - 10px); "
        + "padding: 2VH 5vw; width: 50vmin; max-width: 10vmax; height: 99999svh\">footer</div>"
        + "<style>.hero { height: 100lvh } .box { inline-size: 20vi; block-size: 10vb; height: 40cqh }</style>")
    #expect(s.bodyHTML.contains("height:600px"))
    #expect(s.bodyHTML.contains("min-height:calc(300px - 10px)"))
    #expect(s.bodyHTML.contains("padding:12px 5vw"))
    #expect(s.bodyHTML.contains("width:min(50vw,300px)"))
    #expect(s.bodyHTML.contains("max-width:max(10vw,60px)"))
    #expect(s.bodyHTML.contains("height:6000px"), "clamped first, then fixed")
    let css = s.headCSS.joined()
    #expect(css.contains("height:600px"))
    #expect(css.contains("inline-size:20vi"), "the viewport's width does not follow the message")
    #expect(css.contains("block-size:60px") && css.contains("height:240px"))
    for unit in ["vh", "svh", "lvh", "dvh", "vb", "vmin", "vmax", "cqh"] {
        #expect(!(s.bodyHTML + css).lowercased().contains("0\(unit)"), "\(unit) is left")
    }
}

@Test func invertFiltersAndEditableCSSAreDropped() {
    let s = sanitize("<div style=\"filter: invert(1); opacity: .5; -webkit-user-modify: read-write\">x</div><div style=\"filter: blur(2px)\">y</div>")
    #expect(s.bodyHTML == "<div style=\"opacity:.5\">x</div><div style=\"filter:blur(2px)\">y</div>")
}

@Test func tableLayoutFixedIsKept() {
    #expect(sanitize("<table style=\"table-layout: fixed\"><tr><td>x</td></tr></table>").bodyHTML.contains("table-layout:fixed"))
}

@Test func videoBecomesPlaceholder() {
    #expect(sanitize("<video src=\"https://x.example/v.mp4\"></video>").bodyHTML == "<span class=\"oh-placeholder\">(media not shown)</span>")
}

@Test func ourHooksCannotBeSpoofed() {
    let s = sanitize("<div id=\"oh-root\" class=\"oh-quoted keep\">x</div>")
    #expect(s.bodyHTML == "<div class=\"keep\">x</div>")
}

@Test func bodyAttributesMoveToTheWrapper() {
    let s = sanitize("<html><body bgcolor=\"#f4f4f4\" text=\"333333\" background=\"cid:bg\" dir=\"RTL\" lang=\"he\" class=\"x oh-y\" style=\"margin:0;padding:8px\" onload=\"x()\"><p>x</p></body></html>")
    #expect(s.bodyAttributeCSS == ".oh-body{background-color:#f4f4f4;color:#333333;background-image:url(\"ohcid:bg\")}")
    #expect(s.bodyAttributes == " dir=\"rtl\" lang=\"he\" style=\"margin:0;padding:8px\"")
    #expect(s.bodyClass == "x")
    #expect(s.bodyHTML == "<p>x</p>")
}

@Test func gmailAppleYahooQuotesFoldIntoDetails() {
    let gmail = sanitize("<div>Sure.</div><div class=\"gmail_quote\"><div class=\"gmail_attr\">On Tue, Dana wrote:</div><blockquote class=\"gmail_quote\">old</blockquote></div>")
    #expect(gmail.hasQuotedText)
    #expect(gmail.bodyHTML.hasPrefix("<div>Sure.</div><details class=\"oh-quoted\"><summary"))
    #expect(gmail.bodyHTML.components(separatedBy: "<details").count == 2, "nested quote must not fold twice")
    let apple = sanitize("<p>Yes</p><blockquote type=\"cite\">old</blockquote>")
    #expect(apple.hasQuotedText)
    #expect(apple.bodyHTML.contains("<details class=\"oh-quoted\"><summary title=\"Show quoted text\">"))
    let yahoo = sanitize("<div>ok</div><div class=\"yahoo_quoted\"><div>On Monday, Sam wrote:</div><div>old</div></div>")
    #expect(yahoo.bodyHTML.contains("<details class=\"oh-quoted\"><summary title=\"Show quoted text\">•••</summary><div class=\"yahoo_quoted\">"))
}

@Test func forwardedMessagesStayExpanded() {
    let gmail = sanitize("<div>FYI</div><div class=\"gmail_quote\"><div class=\"gmail_attr\">---------- Forwarded message ---------<br>From: Dana</div><div>content</div></div>")
    #expect(!gmail.hasQuotedText)
    #expect(!gmail.bodyHTML.contains("<details"))
    let apple = sanitize("<div>FYI</div><div>Begin forwarded message:</div><blockquote type=\"cite\"><div>content</div></blockquote>")
    #expect(!apple.bodyHTML.contains("<details"))
}

@Test func outlookHistoryFoldsToTheEndOfItsParent() {
    let web = sanitize("<div>Reply</div><div id=\"appendonsend\"></div><hr><div id=\"divRplyFwdMsg\"><b>From:</b> Dana</div><div>old text</div>")
    #expect(web.bodyHTML == "<div>Reply</div><details class=\"oh-quoted\"><summary title=\"Show quoted text\">•••</summary><div id=\"appendonsend\"></div><hr><div id=\"divRplyFwdMsg\"><b>From:</b> Dana</div><div>old text</div></details>")
    let desktop = sanitize("<div class=\"WordSection1\"><p>Thanks</p><div><div style=\"border:none;border-top:solid #E1E1E1 1.0pt;padding:3.0pt 0in 0in 0in\"><p><b>From:</b> Sam</p></div></div><p>earlier</p></div>")
    #expect(desktop.hasQuotedText)
    #expect(desktop.bodyHTML.contains("<p>Thanks</p><details class=\"oh-quoted\">"))
    #expect(desktop.bodyHTML.hasSuffix("<p>earlier</p></details></div>"))
    let hotmail = sanitize("<div>Hi</div><hr id=\"stopSpelling\"><div>old</div>")
    #expect(hotmail.bodyHTML.contains("<details class=\"oh-quoted\"><summary title=\"Show quoted text\">•••</summary><hr id=\"stopSpelling\">"))
}

@Test func signaturesFold() {
    let gmail = sanitize("<div>Body</div><div class=\"gmail_signature\" data-smartmail=\"gmail_signature\">Dana Ruiz<br>Finance</div>")
    #expect(gmail.hasQuotedText)
    #expect(gmail.bodyHTML == "<div>Body</div><details class=\"oh-quoted oh-signature\"><summary title=\"Show signature\">•••</summary><div class=\"gmail_signature\">Dana Ruiz<br>Finance</div></details>")
    let thunderbird = sanitize("<p>Body</p><pre class=\"moz-signature\" cols=\"72\">-- \nSam</pre>")
    #expect(thunderbird.bodyHTML.contains("<details class=\"oh-quoted oh-signature\">"))
    let outlook = sanitize("<p>Body</p><div id=\"Signature\"><p>Sam</p></div>")
    #expect(outlook.bodyHTML.contains("oh-signature"))
}

@Test func textIsEscaped() {
    let s = sanitize("<p>&lt;script&gt;alert(1)&lt;/script&gt; &amp; 5 &gt; 3</p>")
    #expect(s.bodyHTML == "<p>&lt;script&gt;alert(1)&lt;/script&gt; &amp; 5 &gt; 3</p>")
}

@Test func suspiciousLinksAreReportedNotRewritten() {
    let s = sanitize("""
        <a href="https://evil.example/login">https://www.paypal.com/signin</a>
        <a href="https://www.paypal.com/help">www.paypal.com</a>
        <a href="mailto:x@evil.example">support@bank.example</a>
        <a href="https://news.example/r?u=1">Read more</a>
        """)
    #expect(s.suspiciousLinks.count == 2)
    #expect(s.suspiciousLinks.first?.reasons == [.domainMismatch])
    #expect(s.suspiciousLinks.first?.displayedDestination == "paypal.com")
    #expect(s.suspiciousLinks.first?.actualDestination == "evil.example")
    #expect(s.suspiciousLinks.last?.reasons == [.addressMismatch])
    #expect(s.bodyHTML.contains("href=\"https://evil.example/login\""))
}

@Test func documentCarriesCSPReferrerBaseCSSAndWrapper() throws {
    guard case .html(let r) = MessageRenderer().render(.init(html: "<p>Hello</p>", text: "Hello")) else {
        Issue.record("expected html"); return
    }
    #expect(r.html.hasPrefix("<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\""))
    #expect(r.html.contains("default-src &#39;none&#39;; img-src ohcid: data:;"))
    #expect(r.html.contains("<meta name=\"referrer\" content=\"no-referrer\">"))
    #expect(r.html.contains("<style id=\"oh-base\">" + ReaderCSS.stylesheet(tokens: .light, colorScheme: .light) + "</style>"))
    #expect(r.html.contains("#oh-root { display: flow-root; }"))
    #expect(r.html.hasSuffix("<div id=\"oh-root\"><div class=\"oh-body\"><p>Hello</p></div></div></body></html>"))
    #expect(!r.hasRemoteContent)
    #expect(r.tier == .plain && r.colorTreatment == .themeText && r.colorScheme == .light)
}

@Test func cspAllowsRemoteImagesOnlyWhenAsked() {
    #expect(!ReaderDocument.contentSecurityPolicy(allowRemoteImages: false).contains("https:"))
    #expect(ReaderDocument.contentSecurityPolicy(allowRemoteImages: true).contains("img-src ohcid: data: https: http:"))
}

@Test func textOnlyMessagesGoNative() {
    guard case .plain(let doc) = MessageRenderer().render(.init(html: nil, text: "Hi\n\n> old\n-- \nDana")) else {
        Issue.record("expected plain"); return
    }
    #expect(doc.blocks == [.body("Hi"), .quote("old", depth: 1), .signature("Dana")])
    #expect(MessageRenderer().render(.init(html: "  ", text: nil)) == .empty)
}

@Test func trackerOnlyMessagesDoNotAskToLoadImages() throws {
    guard case .html(let r) = MessageRenderer().render(.init(html: "<p>Hi</p><img src=\"https://t.example/o.gif\" width=\"1\" height=\"1\">", text: nil)) else {
        Issue.record("expected html"); return
    }
    #expect(!r.hasRemoteContent)
    #expect(r.trackerCount == 1)
    #expect(r.blockedCount == 0)
    #expect(r.trackerDomains == ["t.example"])
}
