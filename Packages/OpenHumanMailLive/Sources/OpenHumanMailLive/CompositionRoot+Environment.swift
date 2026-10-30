import Foundation
import MailFakes
import MailFeatures
import MailModel
import MailSystem
import MailUI
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore
import OpenHumanAI

@MainActor
public enum CompositionRoot {
    // Why: developer variables are read only in the app target, so a release build never contains them
    public static var developerHome: ([String: String]) -> String? = { _ in nil }

    public static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static let storeBusyTitle = "Another copy of OpenHuman Mail is using your mail"
    static let storeNoticeTitle = "Mail couldn't open the mail on this Mac"

    static func storeNoticeMessage(_ error: any Error) -> String {
        if case StoreError.schemaTooNew = error {
            return "A newer version of Mail last used the mail on this Mac. Install the newest version of Mail."
        }
        return "Quit and open Mail again. Your Gmail is unchanged."
    }

    public static func storeProblem(_ error: any Error) -> StartupProblem {
        if case StoreError.busy = error {
            return StartupProblem(title: storeBusyTitle,
                                  message: "Quit the other copy, then open OpenHuman Mail again. Your Gmail is unchanged.",
                                  details: nil)
        }
        if case StoreError.schemaTooNew = error {
            return StartupProblem(title: storeNoticeTitle, message: storeNoticeMessage(error))
        }
        return StartupProblem(title: storeNoticeTitle, message: storeNoticeMessage(error), details: detailCode(error))
    }

    static func syncStartMessage(_ error: any Error) -> String {
        if case GmailError.reauthRequired = error {
            return "Google needs you to sign in again."
        }
        return "Sign in again, or quit and open Mail again."
    }

    static func detailCode(_ error: any Error) -> String {
        if let gmail = error as? GmailError { return gmail.code }
        if error is StoreError {
            let text = String(describing: error)
            return String(text.prefix { $0 != "(" })
        }
        return String(describing: type(of: error))
    }

    public static func stableID(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    public static let storeRebuildTitle = "Mail needs to rebuild the mail on this Mac"
    public static let storeRebuildMessage = "This development build keeps mail in a new format, so the next time Mail opens it "
        + "starts over with an empty copy: you sign in again and your mail downloads again. The current copy is kept as a "
        + "backup (mail.sqlite.pre-erase-… in Mail's folder); splits, snippets, reminders and changes not yet sent to "
        + "Gmail stay only in that backup. Your Gmail is unchanged. Quit Mail and open it again to continue."

    static func storeRebuildMarker(_ location: StoreLocation) -> URL {
        location.directory.appendingPathComponent("mail.sqlite.rebuild-notice-shown")
    }

    public static func showsStoreRebuildNotice(_ location: StoreLocation,
                                               wouldErase: (StoreLocation) -> Bool = MailStore.schemaChangeWouldErase) -> Bool {
        let marker = storeRebuildMarker(location)
        let shown = FileManager.default.fileExists(atPath: marker.path)
        guard wouldErase(location) else {
            if shown { try? FileManager.default.removeItem(at: marker) }
            return false
        }
        if shown {
            try? FileManager.default.removeItem(at: marker)
            Log(.app).notice("debug store rebuild: the notice was shown at the last launch; the store backs up and erases now")
            return false
        }
        FileManager.default.createFile(atPath: marker.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        Log(.app).notice("debug store rebuild: schema v1 changed; the notice shows before anything is erased")
        return true
    }

    static func environment(store: any MailStoreAdapter.Store & MailStoreSettings.Store & ImportanceRulesStoring,
                            ensureBody: (@Sendable (MessageKey) async throws -> Void)? = nil,
                            attachmentFile: (@Sendable (MessageKey, AttachmentInfo) async throws -> URL)? = nil,
                            connectivity: (@Sendable () -> AsyncStream<[AccountID: ConnectivityState]>)? = nil,
                            syncProgress: (@Sendable () -> AsyncStream<[AccountID: String]>)? = nil,
                            commands: (any MailCommanding)? = nil, accounts: (any AccountManaging)? = nil,
                            draftsDirectory: URL? = nil,
                            isFake: Bool = false, isLiveAccount: Bool = false,
                            onDemand: MailStoreAdapter.OnDemand? = nil,
                            calendar: (any CalendarProviding)? = nil,
                            calendarConnection: (any CalendarConnecting)? = nil,
                            calendarConnections: (any CalendarConnectionsProviding)? = nil) -> AppEnvironment {
        let ai = AIServices.aiCenter(model: .onDevice, persistent: !isFake)
        let semanticStorage: SemanticServices.Storage = isFake ? .inMemory
            : AIServices.cacheDirectory.map { .directory(SemanticServices.folder(storeDirectory: $0)) } ?? .inMemory
        let semantic = SemanticServices(store: store, storage: semanticStorage, ai: ai,
                                        makeProvider: { SemanticServices.appleProvider(ai.settings.smartSearch) })
        SemanticServices.current = semantic
        let autoLabelStore: any AutoLabelStoring = isFake ? InMemoryAutoLabelStore()
            : AIServices.cacheDirectory.flatMap {
                try? SQLiteAutoLabelStore(url: $0.appendingPathComponent(SQLiteAutoLabelStore.fileName))
            } ?? InMemoryAutoLabelStore()
        let calendarCache: (any CalendarCachePersisting)? = isFake ? nil : AIServices.cacheDirectory.flatMap {
            try? SQLiteCalendarCache(url: $0.appendingPathComponent(SQLiteCalendarCache.fileName))
        }
        let searchRanking = searchRankingService(store: store, isFake: isFake)
        let environment = AppEnvironment(data: MailStoreAdapter(store: store, ensureBody: ensureBody, attachmentFile: attachmentFile,
                                                     connectivity: connectivity, syncProgress: syncProgress,
                                                     onDemand: onDemand, semantic: semantic?.arm, ranking: searchRanking),
                              commands: commands, accounts: accounts, settings: MailStoreSettings(store: store),
                              isFake: isFake, navigationStore: navigationStore(isFake ? "fakeGmail" : "live"),
                              importance: MailStoreImportance(store: store),
                              draftsDirectory: draftsDirectory,
                              aiOnboarding: aiOnboarding(isFake: isFake, center: ai), secrets: secretStore(isFake: isFake),
                              ai: ai, isLiveAccount: isLiveAccount, calendar: calendar,
                              calendarConnection: calendarConnection, calendarConnections: calendarConnections,
                              autoLabelStore: autoLabelStore, calendarCache: calendarCache,
                              learnedBehaviourStore: isFake ? nil
                                  : AIServices.cacheDirectory.map { LearnedBehaviourFile(directory: $0) },
                              waiting: (store as? any WaitingOverrideStoring).map { MailStoreWaiting(store: $0) })
        attachClassification(environment, isFake: isFake)
        environment.installSearchRanking(searchRanking)
        CategoryImportanceMatcher.install(on: environment.autoLabels, store: store)
        if let searching = store as? any MailSearching {
            environment.overlays.search.interpretation.resolver = SearchPlanResolver(isValidQuery: { text in
                (try? searching.parseSearch(text)) != nil
            })
        }
        if let semantic, environment.smartSearchEnabled {
            Task { await semantic.apply() }
            if let syncProgress {
                Task { for await _ in syncProgress() { semantic.nudge() } }
            }
        }
        return environment
    }

    static func aiOnboarding(isFake: Bool, center: AICenter? = nil,
                             underTest: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
        -> (any AIOnboardingPort)? {
        if isFake { return FakeAIOnboarding() }
        if underTest { return nil }
        return center.map { AICenterOnboarding(center: $0) } ?? AISettingsOnboarding()
    }

    static func secretStore(isFake: Bool, underTest: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
        -> (any SecretStoring)? {
        if isFake { return InMemorySecretStore() }
        return underTest ? nil : KeychainSecretStore()
    }

    public static func navigationStore(_ scope: String,
                                       _ environment: [String: String] = ProcessInfo.processInfo.environment) -> any NavigationStateStoring {
        guard environment["XCTestConfigurationFilePath"] == nil else { return InMemoryNavigationStore() }
        let base: URL
        if let home = developerHome(environment) {
            base = URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            base = support.appendingPathComponent("OpenHuman", isDirectory: true).appendingPathComponent("Mail", isDirectory: true)
        }
        return FileNavigationStore(directory: base.appendingPathComponent("State", isDirectory: true), scope: scope,
                                   legacy: UserDefaultsNavigationStore(scope: scope))
    }
}
