#if os(macOS)
import AppKit
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI

@MainActor
private func layOut(_ model: LabelPickerModel, name: String, theme: ResolvedTheme = .light) throws -> NSView {
    let view = LabelPickerView(model: model, dismiss: {})
        .environment(\.theme, theme)
        .environment(\.colorScheme, theme.appearance == .dark ? .dark : .light)
        .background(theme.bgWindow.color)
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
    hosting.layoutSubtreeIfNeeded()
    if let dir = ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] {
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
    return hosting
}

@MainActor
private final class Calls {
    var count = 0
}

@MainActor
private func moveModel(_ calls: Calls, superset: Bool, sender: Bool = true) -> LabelPickerModel {
    let account = AccountID(1)
    let labels = ["Clients", "Projects/Atlas", "Receipts"].enumerated().map { index, name in
        LabelInfo(id: Int64(index + 1), account: account, labelID: GmailLabelID("Label_\(index + 1)"), kind: .user,
                  name: name, displayName: String(name.split(separator: "/").last ?? Substring(name)), position: index)
    }
    let splits = [SplitInfo(id: SplitKey("s1"), account: account, name: "Client tab", position: 1, ruleText: "label:Clients"),
                  SplitInfo(id: SplitKey("s2"), account: account, name: "Newsletters", position: 2,
                            ruleText: "category:promotions")]
    let options = MoveOptions(places: [MovePlaceOption(place: .important), MovePlaceOption(place: .other)],
                              splits: splits, sender: sender ? SplitRuleChoice(kind: .sender, value: "dana@example.com") : nil)
    let actions = LabelPickerActions(setLabels: { _, _ in calls.count += 1 }, move: { _ in calls.count += 1 },
                                     create: { _ in calls.count += 1 }, navigate: { _ in calls.count += 1 },
                                     moveToPlace: { _ in calls.count += 1 }, moveToSplit: { _, _ in calls.count += 1 },
                                     addSenderToSplit: { _, _ in calls.count += 1 })
    return LabelPickerModel(mode: .move, targets: [ThreadKey(account: account, rowID: 1, gmailThreadID: GmailThreadID("t1"))],
                            account: nil, labels: labels, targetRows: [], actions: actions,
                            move: superset ? options : nil)
}

@MainActor
@Test func moveToCardLaysOutWithSectionHeadersAndAnUnavailableRow() throws {
    let model = moveModel(Calls(), superset: true)
    #expect(model.rows.map(\.title) == ["Important", "Other", "Client tab", "Newsletters",
                                        "Add this sender to Newsletters", "Atlas", "Receipts"])
    #expect(LabelPickerView.headerCount(model) == 3)
    #expect(model.header(before: 0) == "Places" && model.header(before: 2) == "Splits" && model.header(before: 5) == "Labels")
    _ = try layOut(model, name: "move-to-superset")
    _ = try layOut(model, name: "move-to-superset-dark", theme: .dark)
    model.query = "newsletters"
    _ = try layOut(model, name: "move-to-rule-split")

    let labelsOnly = moveModel(Calls(), superset: false)
    #expect(LabelPickerView.headerCount(labelsOnly) == 0)
    #expect(labelsOnly.rows.map(\.title) == ["Clients", "Atlas", "Receipts"])
    _ = try layOut(labelsOnly, name: "move-to-labels-only")
}

@MainActor
@Test func returnAndAClickOnTheUnavailableRowApplyNothing() throws {
    let calls = Calls()
    let model = moveModel(calls, superset: true, sender: false)
    model.query = "newsletters"
    #expect(model.rows.map(\.title) == ["Newsletters"])
    let row = try #require(model.rows.first)
    #expect(!row.isEnabled && row.disabledReason == MoveToSuperset.ruleSplitReason)
    _ = try layOut(model, name: "move-to-rule-split-only")
    model.confirm()
    model.choose(row)
    model.moveCursor(by: 1)
    #expect(calls.count == 0 && !model.isClosed && model.cursor == 0)

    model.query = ""
    model.confirm()
    #expect(calls.count == 1 && model.isClosed, "↵ applies the first row that can be chosen")
}

@MainActor
@Test func anEmptyPickerSaysWhatWasTyped() {
    #expect(LabelPickerView.emptyText(query: "") == "No labels")
    #expect(LabelPickerView.emptyText(query: "  ") == "No labels")
    #expect(LabelPickerView.emptyText(query: " zzz ") == "Nothing matches “zzz”")
}
#endif
