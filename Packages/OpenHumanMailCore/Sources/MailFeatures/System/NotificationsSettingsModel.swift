import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class NotificationsSettingsModel {
    public struct AccountRow: Identifiable, Hashable {
        public let id: AccountID
        public let title: String
        public var mode: NewMailNotifications
        public var isOn: Bool { mode != .off }
    }

    public static let newMailNote = "Important only follows your importance rules, not Gmail's categories. "
        + "New mail notifies only while Mail is in the background."

    public private(set) var accounts: [AccountRow] = []
    public private(set) var remindersOn = true
    public private(set) var authorization: NotificationAuthorization = .notDetermined
    public private(set) var testSent = false

    @ObservationIgnored private unowned let environment: AppEnvironment
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    isolated deinit {
        for task in tasks { task.cancel() }
    }

    public var preferences: SystemPreferences { environment.system.preferences }
    public var showsPermissionWarning: Bool { authorization == .denied }

    public func start() {
        guard tasks.isEmpty else { return }
        let data = environment.data
        let preferences = self.preferences
        tasks.append(Task { [weak self] in
            do {
                for try await list in data.accounts() {
                    guard let self else { return }
                    self.accounts = list.map {
                        AccountRow(id: $0.id, title: $0.alias ?? $0.displayName ?? $0.email, mode: preferences.newMailMode($0.id))
                    }
                }
            } catch {}
        })
        if let settings = environment.settings {
            tasks.append(Task { [weak self] in
                for await value in settings.observe(AppSettings.schedulerReminders) { self?.remindersOn = value }
            })
        }
        let notifier = environment.system.platform.notifier
        Task { [weak self] in
            let authorization = await notifier.authorization()
            self?.authorization = authorization
        }
    }

    public func refreshAuthorization() async {
        authorization = await environment.system.platform.notifier.authorization()
    }

    public func setNewMailMode(_ mode: NewMailNotifications, for account: AccountID) async {
        preferences.setNewMailMode(mode, for: account)
        if let index = accounts.firstIndex(where: { $0.id == account }) { accounts[index].mode = mode }
        if mode != .off { await askPermission() }
    }

    public func setNewMail(_ on: Bool, for account: AccountID) async {
        let current = preferences.newMailMode(account)
        await setNewMailMode(on ? (current == .off ? .important : current) : .off, for: account)
    }

    public func setReminders(_ on: Bool) async {
        remindersOn = on
        try? await environment.settings?.set(AppSettings.schedulerReminders, on)
        if on { await askPermission() }
    }

    public func setSnoozeReturned(_ on: Bool) async {
        preferences.snoozeReturned = on
        if on { await askPermission() }
    }

    public func setAgentDrafts(_ on: Bool) async {
        preferences.agentDrafts = on
        if on { await askPermission() }
    }

    public func setShowPreviews(_ on: Bool) { preferences.hidePreviews = !on }

    private func askPermission() async {
        _ = await environment.system.notifications?.requestPermissionIfNeeded()
        await refreshAuthorization()
    }

    public func sendTest() async {
        let notifier = environment.system.platform.notifier
        if await notifier.authorization() == .notDetermined { _ = await notifier.requestAuthorization() }
        await refreshAuthorization()
        guard authorization == .authorized else { return }
        await notifier.schedule(SystemNotification(identifier: "test.\(UUID().uuidString)", title: "Test notification",
                                                   body: "Notifications from Mail look like this."))
        testSent = true
    }

    public func openSystemSettings() { environment.system.platform.openNotificationSettings() }
}
