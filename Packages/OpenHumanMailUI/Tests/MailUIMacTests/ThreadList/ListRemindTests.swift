import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized)
struct ListRemindTests {
    @Test func remindMeIsAHoverButtonAndAVoiceOverActionWhenAvailable() async throws {
        let host = StubListHost(enabled: [.markDone, .trash, .remind])
        let (controller, model, _, window) = try await ThreadListViewTests.list(threads: 5, host: host)
        defer { window.close() }
        #expect(controller.hoverActions.contains(.remind))
        let rowView = try #require(controller.tableView.rowView(atRow: 1, makeIfNecessary: false) as? ThreadRowBackgroundView)
        let view = try #require(controller.tableView.view(atColumn: 0, row: 1, makeIfNecessary: false) as? ThreadRowView)
        rowView.setHovering(true)
        view.layoutSubtreeIfNeeded()
        let plate = try #require(view.subviews.first)
        let buttons = plate.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.map { $0.accessibilityLabel() } == ["Mark done", "Remind me"])
        #expect(buttons.allSatisfy { $0.toolTip == nil }, "the shortcut tip replaces the native tooltip")
        rowView.setHovering(false)
        let actions = try #require(view.accessibilityCustomActions())
        #expect(actions.map(\.name) == ["Mark done", "Trash", "Remind me"])

        let target = model.rows[2].id
        #expect(controller.performRowAction(.remind, key: target))
        #expect(host.performed.last == .remind && model.cursor == target)
        #expect(model.index(of: target) != nil, "nothing leaves the list: the picker decides")
    }

    @Test func withoutRemindersTheRowHasNoRemindMe() async throws {
        let host = StubListHost(enabled: [.markDone, .trash])
        let (controller, _, _, window) = try await ThreadListViewTests.list(threads: 3, host: host)
        defer { window.close() }
        let view = try #require(controller.tableView.view(atColumn: 0, row: 0, makeIfNecessary: false) as? ThreadRowView)
        #expect(try #require(view.accessibilityCustomActions()).map(\.name) == ["Mark done", "Trash"])
        let first = try #require(controller.model?.rows.first?.id)
        #expect(!controller.performRowAction(.remind, key: first))
    }
}
