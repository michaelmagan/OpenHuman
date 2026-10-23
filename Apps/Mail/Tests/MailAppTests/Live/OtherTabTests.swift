import AppKit
import Foundation
import MailFeatures
import MailModel
import OpenHumanCore
import MailUI
import OpenHumanStore
import SwiftUI
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

private func removeSeededCalendarSplit(_ store: MailStore, _ account: AccountID) throws {
    for split in try store.splits(account: account) where split.name == "Calendar" { try store.deleteSplit(split.id) }
    try store.setSetting(.hideSplitWhenEmpty, [], scope: .account(account))
}

@MainActor
@Test(.timeLimit(.minutes(2))) func otherTabExistsForAnAccountWithOnlyTheImportantSplit() async throws {
    let store = try MailStore.openInMemoryForTesting()
    let account = try FixtureStoreSeeder.seedLargeInbox(store, count: 400, now: Date())
    try removeSeededCalendarSplit(store, account)
    var important: [MessageUpsert] = []
    for index in 0..<8 {
        var labels = ["INBOX", "IMPORTANT"]
        if index < 5 { labels.append("UNREAD") }
        important.append(MessageUpsert(
            gmailMessageID: GmailMessageID("im\(index)"), gmailThreadID: GmailThreadID("it\(index)"),
            historyID: HistoryID(UInt64(10_000 + index)), internalDate: Date(), labelIDs: labels.map { GmailLabelID($0) },
            snippet: "Important \(index)", sizeEstimate: 1_000,
            headers: MessageHeaderFields(subject: "Important \(index)", from: EmailAddress(email: "boss@example.com"),
                                         to: [EmailAddress(email: "large@example.com")], cc: [], bcc: [], replyTo: [],
                                         date: Date(), messageID: "<im\(index)@fake.example>", inReplyTo: nil, references: [])))
    }
    _ = try store.upsertMessages(important, account: account, generation: 1)

    let items = try store.splits(account: account)
    #expect(items.map(\.name) == ["Important"], "the splits table holds only the Important row")

    let environment = AppEnvironment(data: MailStoreAdapter(store: store), settings: MailStoreSettings(store: store), isFake: true)
    let router = environment.router
    router.start()
    defer { router.stop() }
    await eventually("tabs") { router.active?.tabs.count == 2 }
    let state = try #require(router.active)
    #expect(state.tabs.map(\.title) == ["Important", "Other"])
    let other = try #require(state.tabs.last)
    #expect(other.location == .splitOther)
    await eventually("other unread") { state.tabs.last?.unread == (0..<400).filter { $0 % 3 == 0 }.count }
    await eventually("other total") { state.tabs.last?.total == 400 }
    #expect(state.tabs.first?.total == 8 && state.tabs.first?.unread == 5)

    router.go(to: .splitOther)
    await eventually("other list") { router.list?.state == .loaded && router.list?.totalCount == 400 }
    #expect(router.list?.rows.allSatisfy { $0.subject.hasPrefix("Synthetic thread") } == true)
}

@MainActor
@Test(.timeLimit(.minutes(2))) func hideWhenEmptyHidesAnEmptyTabButNeverTheSelectedOne() async throws {
    let store = try MailStore.openInMemoryForTesting()
    let account = try FixtureStoreSeeder.seedLargeInbox(store, count: 30, now: Date())
    try removeSeededCalendarSplit(store, account)
    let settings = MailStoreSettings(store: store)
    let environment = AppEnvironment(data: MailStoreAdapter(store: store), settings: settings, isFake: true)
    let router = environment.router
    router.start()
    defer { router.stop() }
    await eventually("tabs") { router.active?.tabs.count == 2 }
    let state = try #require(router.active)
    let important = try #require(try store.splits(account: account).first)
    #expect(state.hiddenWhenEmpty.isEmpty, "off by default for Important and Other")

    router.go(to: .splitOther)
    try await settings.set(AppSettings.hideSplitWhenEmpty(account), [important.id.rawValue, AppSettings.otherSplitToken])
    await eventually("important hidden") { state.tabs.map(\.title) == ["Other"] }
    #expect(state.tabs.first?.total == 30, "Other is not empty, so it stays")

    router.go(to: .split(important.id))
    await eventually("shown tab kept") { state.tabs.map(\.title) == ["Important", "Other"] }
    router.go(to: .splitOther)
    await eventually("hidden again") { state.tabs.map(\.title) == ["Other"] }

    try await settings.set(AppSettings.hideSplitWhenEmpty(account), [])
    await eventually("shown again") { state.tabs.count == 2 }

    let model = SplitSettingsModel(environment: environment)
    model.start()
    await eventually("settings other row") { model.otherTotal == 30 && model.otherUnread == state.tabs.last?.unread }
    await model.setOtherHiddenWhenEmpty(true)
    #expect(try await settings.get(AppSettings.hideSplitWhenEmpty(account)) == [AppSettings.otherSplitToken])
    let split = try #require(model.splits.first)
    await model.setHiddenWhenEmpty(split, true)
    await eventually("both stored") { model.isHiddenWhenEmpty(split) && model.isOtherHiddenWhenEmpty }
}

@MainActor
@Test(.timeLimit(.minutes(2))) func bothTabsStayWhenHideWhenEmptyIsOnButNeitherIsEmpty() async throws {
    let store = try MailStore.openInMemoryForTesting()
    let account = try FixtureStoreSeeder.seedLargeInbox(store, count: 400, now: Date())
    try removeSeededCalendarSplit(store, account)
    var important: [MessageUpsert] = []
    for index in 0..<8 {
        important.append(MessageUpsert(
            gmailMessageID: GmailMessageID("im\(index)"), gmailThreadID: GmailThreadID("it\(index)"),
            historyID: HistoryID(UInt64(10_000 + index)), internalDate: Date(),
            labelIDs: ["INBOX", "IMPORTANT", "UNREAD"].map { GmailLabelID($0) },
            snippet: "Important \(index)", sizeEstimate: 1_000,
            headers: MessageHeaderFields(subject: "Important \(index)", from: EmailAddress(email: "boss@example.com"),
                                         to: [EmailAddress(email: "large@example.com")], cc: [], bcc: [], replyTo: [],
                                         date: Date(), messageID: "<im\(index)@fake.example>", inReplyTo: nil, references: [])))
    }
    _ = try store.upsertMessages(important, account: account, generation: 1)
    let importantID = try #require(try store.splits(account: account).first).id.rawValue
    let settings = MailStoreSettings(store: store)
    try await settings.set(AppSettings.hideSplitWhenEmpty(account), [importantID, AppSettings.otherSplitToken])

    let environment = AppEnvironment(data: MailStoreAdapter(store: store), settings: settings, isFake: true)
    let router = environment.router
    router.start()
    defer { router.stop() }

    var seen: [[String]] = []
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(15)
    var settled = false
    while clock.now < deadline {
        if let state = router.active {
            let titles = state.tabs.map(\.title)
            if seen.last != titles { seen.append(titles) }
            if !state.hiddenWhenEmpty.isEmpty, state.counts != nil, !state.labels.isEmpty, state.location != nil {
                #expect(state.isOnTab, "the toolbar keeps drawing the tab bar")
                settled = true
                break
            }
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(settled)
    #expect(seen.last == ["Important", "Other"])
    #expect(seen.allSatisfy { $0 == ["Important", "Other"] || $0 == ["Inbox"] || $0.isEmpty }, "tab states seen: \(seen)")
    router.go(to: .splitOther)
    router.go(to: .split(try #require(try store.splits(account: account).first).id))
    #expect(router.active?.tabs.map(\.title) == ["Important", "Other"])
}

@MainActor
@Test(.timeLimit(.minutes(2))) func aSavedPlainInboxPlaceOpensOnTheTabsNotTheBareInbox() async throws {
    let store = try MailStore.openInMemoryForTesting()
    let account = try FixtureStoreSeeder.seedLargeInbox(store, count: 120, now: Date())
    try removeSeededCalendarSplit(store, account)
    let saved = InMemoryNavigationStore(NavigationSnapshot(activeAccount: account, places: [
        AccountPlace(account: account, location: .system(.inbox))]))
    let environment = AppEnvironment(data: MailStoreAdapter(store: store), settings: MailStoreSettings(store: store),
                                     isFake: true, navigationStore: saved)
    let router = environment.router
    router.start()
    defer { router.stop() }
    await eventually("tabs") { router.active?.tabs.count == 2 }
    let state = try #require(router.active)
    await eventually("moved to a tab") { state.location == state.tabs.first?.location }
    #expect(state.isOnTab, "the toolbar draws SplitInboxPicker, not the location title")
    #expect(state.tabs.map(\.title) == ["Important", "Other"])
    await eventually("list") { router.list?.state == .loaded }
}

@MainActor
@Test(.timeLimit(.minutes(2)), arguments: [500.0, 800.0, 1_100.0, 1_500.0])
func theSplitPickerHoldsTheImportantAndOtherTabsAtEveryWidth(width: Double) async throws {
    let store = try MailStore.openInMemoryForTesting()
    let account = try FixtureStoreSeeder.seedLargeInbox(store, count: 60, now: Date())
    try removeSeededCalendarSplit(store, account)
    let environment = AppEnvironment(data: MailStoreAdapter(store: store), settings: MailStoreSettings(store: store), isFake: true)
    let router = environment.router
    router.start()
    defer { router.stop() }
    await eventually("tabs") { router.active?.tabs.count == 2 && router.active?.isOnTab == true }

    let state = try #require(router.active)
    #expect(SplitInboxPicker.shows(state), "the toolbar shows the split picker on a tab")
    #expect(SplitInboxPicker.layout(state.tabs, active: state.location).overflow.isEmpty, "two splits need no More menu")

    // The picker in the style this Mac uses is sized for both titles and fits the window
    let titles = state.tabs.map { SplitInboxPicker.segmentTitle($0, count: state.tabCount($0)) }
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let textWidth = titles.reduce(0) { $0 + ($1 as NSString).size(withAttributes: [.font: font]).width }
    let (window, hosting) = try await hostOffscreen(SplitInboxPicker(router: router, state: state), width: width,
                                                    appearance: .aqua)
    defer { window.orderOut(nil) }
    let ideal = hosting.fittingSize.width
    #expect(ideal >= textWidth && ideal <= width, "width \(width): the picker wants \(ideal) pt for \(textWidth) pt of \(titles)")

    // cacheDisplay draws the tabs style's glass selection as a blank pill, so the labels are measured on the segmented
    // style over a solid backing, in light and dark
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let picker = SplitInboxPicker(router: router, state: state, features: .macOS26)
            .frame(width: width, height: 120)
            .background(Color(nsColor: .windowBackgroundColor))
        let (segmentedWindow, segmentedHosting) = try await hostOffscreen(picker, width: width, appearance: appearance)
        defer { segmentedWindow.orderOut(nil) }
        let control = try #require(segmentedControls(in: segmentedHosting).first,
                                   "the segmented style draws an NSSegmentedControl")
        #expect(control.segmentCount == titles.count, "one segment per tab")
        #expect(control.frame.width >= control.intrinsicContentSize.width - 1, "width \(width): the segments are cut short")
        let columns = try segmentLabelInk(control, in: segmentedHosting)
        #expect(columns.count == titles.count && columns.allSatisfy { $0 > 30 } && columns.reduce(0, +) > 60,
                "width \(width), \(appearance.rawValue): inked label columns per segment \(columns)")
    }
}

@MainActor
private func hostOffscreen<V: View>(_ root: V, width: Double, appearance: NSAppearance.Name) async throws
    -> (NSWindow, NSHostingView<V>) {
    let hosting = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: width, height: 120), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.contentView = hosting
    window.orderFrontRegardless()
    try await Task.sleep(for: .milliseconds(300))
    hosting.layoutSubtreeIfNeeded()
    return (window, hosting)
}

@MainActor
private func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
    if let control = view as? NSSegmentedControl { return [control] }
    return view.subviews.flatMap { segmentedControls(in: $0) }
}

// Inked columns in the middle band of each segment, measured against the segment's own fill so that a selected pill
// does not count as a label
@MainActor
private func segmentLabelInk(_ control: NSSegmentedControl, in hosting: NSView) throws -> [Int] {
    hosting.displayIfNeeded()
    let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / hosting.bounds.width
    var frame = control.convert(control.bounds, to: hosting)
    if !hosting.isFlipped { frame.origin.y = hosting.bounds.height - frame.maxY }
    let rows = Int((frame.minY + frame.height * 0.25) * scale)..<Int((frame.maxY - frame.height * 0.25) * scale)
    let segmentWidth = frame.width / CGFloat(max(1, control.segmentCount))
    return (0..<control.segmentCount).map { index in
        let start = Int((frame.minX + segmentWidth * CGFloat(index)) * scale)
        let end = Int((frame.minX + segmentWidth * CGFloat(index + 1)) * scale)
        guard let fill = rep.colorAt(x: start + Int(6 * scale), y: (rows.lowerBound + rows.upperBound) / 2) else { return 0 }
        return (start..<end).filter { x in
            rows.contains { y in
                guard let c = rep.colorAt(x: x, y: y) else { return false }
                return abs(c.redComponent - fill.redComponent) + abs(c.greenComponent - fill.greenComponent)
                    + abs(c.blueComponent - fill.blueComponent) > 0.25
            }
        }.count
    }
}

@MainActor
@Test(.timeLimit(.minutes(2))) func aNewAccountsCalendarTabShowsOnlyOnceAnInviteArrives() async throws {
    let store = try MailStore.openInMemoryForTesting()
    let account = try FixtureStoreSeeder.seedLargeInbox(store, count: 20, now: Date())
    let seeded = try store.splits(account: account)
    #expect(seeded.map(\.name) == ["Important", "Calendar"])
    let calendar = try #require(seeded.last)
    #expect(try store.setting(.hideSplitWhenEmpty, scope: .account(account)) == [calendar.id.rawValue])

    let environment = AppEnvironment(data: MailStoreAdapter(store: store), settings: MailStoreSettings(store: store), isFake: true)
    let router = environment.router
    router.start()
    defer { router.stop() }
    await eventually("hidden while empty") {
        router.active?.hiddenWhenEmpty.isEmpty == false && router.active?.tabs.map(\.title) == ["Important", "Other"]
    }
    let state = try #require(router.active)

    let invite = MessageUpsert(
        gmailMessageID: GmailMessageID("invite1"), gmailThreadID: GmailThreadID("invite-thread"),
        historyID: HistoryID(20_000), internalDate: Date(), labelIDs: ["INBOX", "UNREAD"].map { GmailLabelID($0) },
        snippet: "Invitation", sizeEstimate: 1_000,
        headers: MessageHeaderFields(subject: "Invitation: planning", from: EmailAddress(email: "pat@example.net"),
                                     to: [EmailAddress(email: "large@example.com")], cc: [], bcc: [], replyTo: [],
                                     date: Date(), messageID: "<invite1@fake.example>", inReplyTo: nil, references: []),
        body: MessageBodyUpsert(text: "x", hasCalendarInvite: true, decodeWarnings: [], searchText: "x"))
    _ = try store.upsertMessages([invite], account: account, generation: 1)
    await eventually("calendar tab") { state.tabs.map(\.title) == ["Important", "Calendar", "Other"] }
    #expect(state.location == state.tabs.first?.location, "the window stays on Important")
}
