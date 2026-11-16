import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct SidebarFocusRouterTests {
    func shell() async -> AppRouter {
        let env = AppEnvironment.fake(corpus: .small, options: .init())
        let router = env.router
        router.start()
        await eventually { router.list?.state == .loaded }
        return router
    }

    @Test func leftAsksForTheSidebarAndShowsItWhenHidden() async throws {
        let router = await shell()
        let location = router.location
        router.isLabelSidebarVisible = false
        #expect(router.isEnabled(.focusLabelSidebar))
        #expect(router.perform(.focusLabelSidebar))
        #expect(router.isLabelSidebarVisible, "← shows a hidden sidebar")
        #expect(router.sidebarFocusRequest == 1, "the window gives it the keys")
        #expect(router.location == location, "going to the sidebar opens nothing")
        #expect(router.perform(.focusLabelSidebar))
        #expect(router.isLabelSidebarVisible && router.sidebarFocusRequest == 2, "a shown sidebar stays shown")
    }

    @Test func leavingDropsTheHighlightAndGivesTheKeysBack() async throws {
        let router = await shell()
        let account = try #require(router.active?.id)
        router.sidebarHasKeys = true
        router.sidebarHighlight = .location(account, .system(.starred))
        #expect(router.perform(.focusLabelSidebar))
        #expect(router.sidebarHighlight == nil, "the sidebar starts at the current place")
        router.sidebarHighlight = .location(account, .system(.starred))
        router.leaveSidebar()
        #expect(router.sidebarHighlight == nil && router.sidebarReturnRequest == 1)
        #expect(router.location != .system(.starred), "leaving opens nothing")
        router.sidebarHighlight = .location(account, .system(.sent))
        router.sidebarHasKeys = false
        #expect(router.sidebarHighlight == nil, "the highlight goes with the keys")
    }
}
