import Foundation
import MailModel
import OpenHumanAI

extension ComposeManager {
    public var calendarSidebar: CalendarSidebarModel? { environment.calendarSidebar }

    public func openEvent(at mention: CalendarDateMention, from session: ComposeSession) {
        guard let sidebar = environment.calendarSidebar else { return }
        let thread = session.thread
        let key = PendingEventKey.draft(session.id)
        Task { await sidebar.reveal(mention, in: thread, key: key) }
    }

    public func makeSendMarksDoneSetting() -> StoredSetting<Bool> {
        StoredSetting(AppSettings.sendAndMarkDone, port: environment.settings)
    }
}

extension AICenter {
    public var showsQuickReplyChips: Bool {
        settings.enabled && settings.instantReplyStrip && settings.draftReplies == .onDeviceAuto
    }
}
