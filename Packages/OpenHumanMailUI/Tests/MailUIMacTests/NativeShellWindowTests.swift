import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
@testable import MailUI
import SwiftUI
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized) struct NativeShellWindowTests {
    static let frameName = "dev.openhuman.tests.native-shell"

    private func contentFrame(_ w: InlineReplyWindow) throws -> NSRect {
        let scroll = try #require(w.content.tableView.enclosingScrollView)
        return scroll.convert(scroll.bounds, to: nil)
    }

    private func settledContentFrame(_ w: InlineReplyWindow) async throws -> NSRect {
        var last: NSRect?
        try await until {
            w.window.contentView?.layoutSubtreeIfNeeded()
            let frame = try? contentFrame(w)
            defer { last = frame }
            return frame != nil && frame == last
        }
        return try contentFrame(w)
    }

    @Test func theWindowHasAUnifiedToolbarTheSystemTitleAndNoDragStrip() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName)
        defer { w.close() }
        #expect(w.window.toolbar != nil, "SwiftUI installed the toolbar")
        await awaitObserved("the title and subtitle") {
            w.window.title == ShellTitles.title(w.router) && w.window.subtitle == ShellTitles.subtitle(w.router)
        }
        let root = try #require(w.window.contentView)
        let strips = subviews(of: NSView.self, in: root).filter { String(describing: type(of: $0)).contains("DragView") }
        #expect(strips.isEmpty, "the title bar is the system's, not a strip over the content")
        let list = try await settledContentFrame(w)
        #expect(list.maxY <= w.window.contentLayoutRect.maxY + 0.5,
                "the list starts under the toolbar (list \(list), layout \(w.window.contentLayoutRect))")
    }

    @Test func theSearchFieldOpensInTheToolbarAndTakesTheKeys() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        #expect(w.content.searchField(in: w.window) == nil, "a Search button until search opens")
        #expect(w.router.perform(.search))
        try await until { w.content.searchField(in: w.window) != nil }
        let field = try #require(w.content.searchField(in: w.window))
        let content = try #require(w.window.contentView)
        #expect(!field.isDescendant(of: content), "the field is a toolbar item, not a band over the content")
        try await until { OverlayFocusKeeper.control(of: w.window.firstResponder) === field }
        #expect(KeyRouter.isTextInput(w.window.firstResponder), "typing in the field is typing, not shortcuts")
    }

    @Test func aStatusBannerFloatsOverTheListWithoutMovingIt() async throws {
        let environment = AppEnvironment.fake(corpus: .small, options: .init(remoteAck: .immediate, liveConnectivity: true),
                                              notices: NoticeCenter(autoExpire: false))
        let store = try #require(environment.data as? FakeMailStore)
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, environment: environment)
        defer { w.close() }
        let before = try await settledContentFrame(w)
        store.setOffline(true)
        try await until { w.router.banner()?.kind == .offline }
        let after = try await settledContentFrame(w)
        #expect(after == before, "the banner floats; the list keeps its place (before \(before), after \(after))")
    }

    @Test func theReaderShowsBackAndItsActionsAndTheListShowsSelectAll() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName)
        defer { w.close() }
        #expect(ShellSurface(router: w.router).selectableList != nil)
        #expect(!ShellSurface(router: w.router).isReader)
        let thread = try #require(w.router.list?.rows.first?.id)
        let reader = try await w.open(thread)
        let surface = ShellSurface(router: w.router)
        #expect(surface.isReader && surface.reader === reader)
        #expect(surface.selectableList == nil && surface.splitState == nil && !surface.showsSearchField)
        let actions = ReaderToolbarActions(router: w.router, reader: reader)
        #expect(actions.primary.map(\.id).contains(.markDone))
        #expect(actions.primary.map(\.id).contains(.trash))
        #expect(actions.navigation.map(\.id) == ReaderActions.navigationActionIDs)
        let more = actions.more.joined().map(\.id)
        #expect(Set(more).isDisjoint(with: ReaderToolbarActions.primaryIDs), "nothing twice between the group and More")
    }
}

@MainActor
@Suite struct MenuSymbolTests {
    @Test func menuItemsShowSymbolsOnlyWhereTheSystemDrawsThem() {
        #expect(MailCommands.menuSymbol(for: .markDone, features: .macOS26) == nil, "text only on macOS 26")
        #expect(MailCommands.menuSymbol(for: .markDone, features: .macOS27) == ReaderActions.symbol(for: .markDone))
        #expect(MailCommands.menuSymbol(for: .refresh, features: .macOS27) == nil, "only actions with a toolbar symbol")
    }
}
