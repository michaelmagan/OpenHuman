import Foundation
import MailActions
import MailModel
import OpenHumanCore

extension AppRouter {
    public var isAllInboxesShown: Bool { unifiedInbox != nil }

    public var showsAllInboxes: Bool { showsAccountSwitcher && allInboxesEnabled }

    @discardableResult
    public func goToAllInboxes() -> Bool {
        guard showsAllInboxes else { return false }
        environment.calendarWindowIfStarted?.stepAside()
        if unifiedInbox != nil { return true }
        startAllInboxes()
        return true
    }

    // An open All Inboxes reads the accounts it started with, so it starts again, with the same text, when one is
    // added, removed or renamed
    func allInboxesFollowAccounts() {
        guard let model = unifiedInbox, !model.reads(accounts.map(\.account)) else { return }
        let query = model.query, everywhere = model.searchAllAccounts
        leaveAllInboxes()
        guard showsAllInboxes else { return }
        startAllInboxes()
        unifiedInbox?.setSearchAllAccounts(everywhere)
        unifiedInbox?.setQuery(query)
    }

    private func startAllInboxes() {
        let model = AllInboxesModel(accounts: accounts.map(\.account), open: { [weak self] key in
            guard let self else { return }
            // A row of an account removed since: opening it would open the key in the active account
            guard self.accounts.contains(where: { $0.id == key.account }) else {
                self.leaveAllInboxes()
                self.goToAllInboxes()
                return
            }
            self.switchAccount(to: key.account)
            self.open(key)
        }, done: { [weak self] keys in
            guard let self, let actions = self.environment.actions.threadActions else { return false }
            return actions.markDone(keys, host: self) != nil
        }, label: { [weak self] keys in
            guard let self, self.environment.overlays.canPresent(.labelPicker) else { return false }
            self.environment.overlays.present(.labelPicker(targets: keys, mode: .label))
            return true
        }, localReads: accounts.reduce(into: [:]) { $0.merge($1.localReads) { max($0, $1) } })
        unifiedInbox = model
        model.start(data: environment.data)
    }

    public func leaveAllInboxes() {
        guard let model = unifiedInbox else { return }
        model.close()
        unifiedInbox = nil
    }

    public var allInboxesUnread: Int? {
        Self.allInboxesCount(accounts.map { $0.badgeCount(accountCountMode) })
    }

    public nonisolated static func allInboxesCount(_ badges: [Int?]) -> Int? {
        let total = badges.reduce(0) { $0 + max(0, $1 ?? 0) }
        return total > 0 ? total : nil
    }

    func observeAccountCounts() {
        guard accountCountsTask == nil, let stream = environment.settings?.observe(AppSettings.accountCounts) else { return }
        accountCountsTask = Task { [weak self] in
            for await mode in stream {
                guard !Task.isCancelled else { return }
                if self?.accountCountMode != mode { self?.accountCountMode = mode }
            }
        }
    }

    func followAllInboxesSetting() {
        guard allInboxesTask == nil, let stream = environment.settings?.observe(AppSettings.allInboxesShown) else { return }
        allInboxesTask = Task { [weak self] in
            for await on in stream {
                guard !Task.isCancelled else { return }
                self?.applyAllInboxesSetting(on)
            }
        }
    }

    func applyAllInboxesSetting(_ on: Bool) {
        if allInboxesEnabled != on { allInboxesEnabled = on }
        if !on { leaveAllInboxes() }
    }

    @discardableResult
    public func setAllInboxesShown(_ on: Bool) async -> Bool {
        guard let settings = environment.settings else { return false }
        do {
            try await settings.set(AppSettings.allInboxesShown, on)
            return true
        } catch {
            environment.notices.post("Couldn't change All Inboxes", style: .error)
            return false
        }
    }

    public static let allInboxesOffNotice = "All Inboxes is off. Settings › Sidebar turns it back on."

    public func hideAllInboxes() {
        Task { [weak self] in
            guard let self, await self.setAllInboxesShown(false) else { return }
            self.environment.notices.post(Self.allInboxesOffNotice, actionTitle: "Undo") { [weak self] in
                _ = await self?.setAllInboxesShown(true)
            }
        }
    }

    @discardableResult
    public func setFolder(_ folder: SidebarFolder, shown: Bool) async -> Bool {
        guard let settings = environment.settings else { return false }
        do {
            let stored = try await settings.get(AppSettings.sidebarHidden)
            try await settings.set(AppSettings.sidebarHidden,
                                   SidebarFolder.hiddenList(stored, setting: folder.token, hidden: !shown))
            return true
        } catch {
            environment.notices.post("Couldn't change the sidebar", style: .error)
            return false
        }
    }

    public func sidebarRoute(of folder: SidebarFolder) -> String? {
        let descriptor = folder.goAction.flatMap { environment.actions.descriptor($0) ?? ActionCatalog.descriptor($0) }
        return SidebarFolder.route(of: folder, descriptor: descriptor)
    }

    public func hideFromSidebar(_ location: MailLocation) {
        guard let folder = active?.sidebarFolder(for: location) else { return }
        let notice = SidebarFolder.hiddenNotice(folder, route: sidebarRoute(of: folder))
        Task { [weak self] in
            guard let self, await self.setFolder(folder, shown: false) else { return }
            self.environment.notices.post(notice, actionTitle: "Undo") { [weak self] in
                _ = await self?.setFolder(folder, shown: true)
            }
        }
    }
}
