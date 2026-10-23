#if os(macOS)
import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI

@MainActor
@Suite(.serialized) struct SearchFieldLayoutTests {
    private static let fixedNow = Date(timeIntervalSince1970: 1_791_000_000)

    private func fitted<V: View>(_ view: V, width: CGFloat?) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width ?? 10_000, height: 10_000))
    }

    // MARK: The completion in the field

    @Test func theCompletionKeepsToTheFieldsWidthAndEndsInAnEllipsis() {
        let ghost = SearchGhost(remainder: "", detail: "Clients/Partners and suppliers")
        let view = SearchGhostText(rest: "e", ghost: ghost).environment(\.theme, .light)
        let natural = fitted(view.fixedSize(), width: nil).width
        let field = SearchFieldView.minTextWidth
        #expect(natural > field, "the completion is longer than the narrowest field (\(natural) pt)")
        let shown = fitted(view, width: field)
        #expect(shown.width <= field + 0.5, "it ends inside the field, before the clear button: \(shown.width) of \(field)")
        #expect(SearchGhostText.completion(ghost) == " ⇥ Clients/Partners and suppliers")
        #expect(SearchGhostText.completion(SearchGhost(remainder: "m:", detail: nil)) == "m:")
        #expect(SearchGhostText.completion(SearchGhost(remainder: "chael", detail: "michael@example.com"))
                == "chael  ⇥ michael@example.com")
    }

    /// The toolbar's field with three pills and a long completion: nothing is drawn in the gap between the text and
    /// the clear button.
    @Test(arguments: [("light", ResolvedTheme.light), ("dark", ResolvedTheme.dark)])
    func theCompletionStopsBeforeTheClearButton(_ name: String, _ theme: ResolvedTheme) async throws {
        let env = AppEnvironment.fake(corpus: .rich(threadCount: 20, now: Self.fixedNow), featureFlags: FeatureFlags())
        let router = env.router
        router.start()
        defer { router.stop() }
        await awaitObserved("the list loads") { router.list?.state == .loaded }
        let search = env.overlays.search
        search.text = "from:dana subject:\"q4 budget\" -label:Receipts e"
        await awaitObserved("a completion for the last word") {
            search.suggestions.contains { SearchSuggestions.ghost(text: search.text, suggestion: $0) != nil }
        }

        // Stands in for the window's panel: reports the keys in the field, as the toolbar's host does
        final class Shown { var presented = false }
        let shown = Shown()
        let floating = FloatingSearchDropdown { request in
            shown.presented = request.isPresented
            return AnyView(Color.clear.onAppear { request.keysChanged?(true) })
        }
        let scheme: ColorScheme = theme.appearance == .dark ? .dark : .light
        let size = NSSize(width: NativeMetrics.Search.focusedFieldWidth + 16, height: ShellMetrics.tabHeight + 16)
        let hosting = NSHostingView(rootView: SearchFieldView(search: search)
            .frame(width: NativeMetrics.Search.focusedFieldWidth)
            .padding(8)
            .frame(width: size.width, height: size.height)
            .background(theme.bgWindow.color)
            .environment(\.floatingSearchDropdown, floating)
            .environment(\.theme, theme)
            .environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        func textFields(in view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(textFields)
        }
        try await waitUntil(timeout: .seconds(10)) {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            return shown.presented && textFields(in: hosting).first?.stringValue == "e"
        }
        hosting.layoutSubtreeIfNeeded()
        let field = try #require(textFields(in: hosting).first)
        let frame = field.convert(field.bounds, to: hosting)
        let top = hosting.isFlipped ? frame.minY : hosting.bounds.height - frame.maxY
        #expect(frame.width < 120, "the pills leave the text a narrow field, as in the toolbar: \(frame)")

        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = try #require(rep.cgImage)
        try writeSnapshot(image, "search-field-ghost-\(name)")
        let pixels = try #require(Pixels(image))
        let scale = CGFloat(rep.pixelsWide) / max(rep.size.width, 1)

        func spread(x: ClosedRange<CGFloat>) -> Int {
            var low = Int.max, high = Int.min
            var y = top + 2
            while y <= top + frame.height - 2 {
                var px = x.lowerBound
                while px <= x.upperBound {
                    let pixel = pixels.at(px, y, scale: scale)
                    let luminance = (pixel.0 + pixel.1 + pixel.2) / 3
                    low = min(low, luminance)
                    high = max(high, luminance)
                    px += 1 / scale
                }
                y += 1 / scale
            }
            return high - low
        }
        #expect(spread(x: (frame.minX + 14)...(frame.maxX - 2)) > 20, "the completion is drawn after the typed text")
        let gap: ClosedRange<CGFloat> = (frame.maxX + 2)...(frame.maxX + theme.space3 - 2)
        #expect(spread(x: gap) <= 12, "nothing is drawn between the field and the clear button (\(name))")
    }

    // MARK: The tips beside the suggestions

    @Test func everyTipShownIsWholeInsideTheColumn() {
        let metrics = NativeMetrics.Search.self
        let width = metrics.panelSideWidth - 2 * SearchTipsView.insetX
        let examples = SearchTips.all.map { fitted(SearchTipsView.example($0), width: nil) }
        let exampleWidth = min(examples.map(\.width).max() ?? 0, width)
        let meaningWidth = width - exampleWidth - SearchTipsLayout.columnSpacing
        let meanings = SearchTips.all.map { fitted(SearchTipsView.meaning($0), width: meaningWidth) }
        // The panel keeps the tips' one-line height whatever the list beside them holds
        let column = SearchDropdownLayout.sideHeight - 2 * metrics.panelPadding - SearchDropdownLayout.headerHeight
        let rows = SearchTipsLayout.rows(examples: examples, meanings: meanings, exampleWidth: exampleWidth,
                                         meaningWidth: meaningWidth, height: column, minRowHeight: metrics.panelTipRowHeight)
        let bounds = CGRect(x: 0, y: 0, width: width, height: column)
        #expect(rows.count == SearchTips.all.count)
        #expect(rows.contains { !$0.shown }, "meanings on two lines leave no room for the last tips")
        #expect(rows.contains { $0.shown }, "the first tips show")
        for (tip, row) in zip(SearchTips.all, rows) where row.shown {
            #expect(bounds.contains(row.example) && bounds.contains(row.meaning),
                    "“\(tip.example)” is whole inside the column: \(row.example), \(row.meaning) in \(bounds)")
        }
        let firstHidden = rows.firstIndex { !$0.shown } ?? rows.count
        #expect(rows[firstHidden...].allSatisfy { !$0.shown }, "a tip after one left out is left out too")
        let tall = SearchTipsLayout.rows(examples: examples, meanings: meanings, exampleWidth: exampleWidth,
                                         meaningWidth: meaningWidth, height: .infinity,
                                         minRowHeight: metrics.panelTipRowHeight)
        #expect(tall.allSatisfy { $0.shown }, "with room every tip shows")
    }

    @Test func aTipRowIsShownOnlyWhenItFitsWhole() {
        let line = CGSize(width: 60, height: 15)
        let twoLines = CGSize(width: 100, height: 30)
        let rows = SearchTipsLayout.rows(examples: [line, line, line, line], meanings: [line, twoLines, line, line],
                                         exampleWidth: 80, meaningWidth: 100, height: 75, minRowHeight: 20)
        #expect(rows.map(\.shown) == [true, true, true, false], "20 + 35 + 20 fit in 75; the fourth would end at 95")
        #expect(rows[0].example == CGRect(x: 0, y: 2.5, width: 60, height: 15), "a single line sits in the middle of its row")
        #expect(rows[1].meaning == CGRect(x: 90, y: 22.5, width: 100, height: 30), "beside the examples' column")
        #expect(rows[2].example.minY == 57.5, "after the taller row")
    }
}
#endif
