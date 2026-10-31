import Foundation
import MailFakes
import MailFeatures
import MailModel
import MailRender
import MailUI
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import OpenHumanSync
import Synchronization
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

private final class RecordingEngine: MailEngineWriting {
    private let log = Mutex<[String]>([])
    var calls: [String] { log.withLock { $0 } }
    private func record(_ name: String) { log.withLock { $0.append(name) } }

    static let receipt = ActionReceipt(operationIDs: [])
    static let sendReceipt = SendReceipt(draftID: DraftID("d1"), sendOperationID: OperationID(rawValue: 1), sendAfter: Date())

    func perform(_ action: MailAction, origin: OperationOrigin) async throws -> ActionReceipt { record("perform"); return Self.receipt }
    func undo(_ receipt: ActionReceipt) async throws -> ActionReceipt? { record("undo"); return nil }
    func createLabel(account: AccountID, name: String, applyTo: [ThreadRef]) async throws -> ActionReceipt {
        record("createLabel"); return Self.receipt
    }
    func newDraft(account: AccountID, mode: ComposeMode, replyTo: GmailMessageID?, origin: DraftOrigin,
                  initial: DraftContent?) async throws -> NewDraft {
        record("newDraft"); return NewDraft(id: DraftID("d1"), version: 1)
    }
    func saveDraft(_ id: DraftID, content: DraftContent, expectedVersion: Int?) async throws -> Int { record("saveDraft"); return 2 }
    func flushDraft(_ id: DraftID) async throws { record("flushDraft") }
    func discardDraft(_ id: DraftID) async throws { record("discardDraft") }
    func setReviewState(_ id: DraftID, _ state: DraftReviewState) async throws { record("setReviewState") }
    func resolveDraftConflict(_ id: DraftID, keep: DraftConflictChoice) async throws { record("resolveDraftConflict") }
    func send(_ id: DraftID, authorization: SendAuthorization, undoWindow: Duration?) async throws -> SendReceipt {
        record("send"); return Self.sendReceipt
    }
    func cancelSend(_ receipt: SendReceipt) async throws -> Bool { record("cancelSend"); return true }
    func sendNow(_ receipt: SendReceipt) async throws -> Bool { record("sendNow"); return true }
    func scheduleSend(_ id: DraftID, at: Date) async throws { record("scheduleSend") }
    func cancelScheduledSend(_ id: DraftID) async throws { record("cancelScheduledSend") }
    func fetchDraft(account: AccountID, gmailDraftID: GmailDraftID) async throws -> DraftID? { record("fetchDraft"); return nil }
    func fetchThread(account: AccountID, gmailThreadID: GmailThreadID) async throws -> ThreadRef? {
        record("fetchThread"); return nil
    }
    func upsertSnippet(_ snippet: SnippetItem) async throws -> SnippetItem { record("upsertSnippet"); return snippet }
    func deleteSnippet(id: String) async throws { record("deleteSnippet") }
    func recordSnippetUse(id: String) async throws { record("recordSnippetUse") }
    func storeSnippetAttachment(file: URL, mimeType: String) async throws -> SnippetAttachment {
        record("storeSnippetAttachment")
        return SnippetAttachment(contentHash: String(repeating: "0", count: 64), filename: "x.txt", mimeType: mimeType, size: 1)
    }
    func storeSnippetAttachment(data: Data, filename: String, mimeType: String) async throws -> SnippetAttachment {
        record("storeSnippetAttachment")
        return SnippetAttachment(contentHash: String(repeating: "0", count: 64), filename: filename, mimeType: mimeType, size: data.count)
    }
    func upsertSplit(account: AccountID, id: SplitID?, name: String, ruleText: String, position: Int?,
                     enabled: Bool) async throws -> SplitID {
        record("upsertSplit"); return SplitID("s1")
    }
    func deleteSplit(_ id: SplitID) async throws { record("deleteSplit") }
    func reorderSplits(account: AccountID, _ ids: [SplitID]) async throws { record("reorderSplits") }
    func dismissFailedOperation(_ id: OperationID) async throws { record("dismissFailedOperation") }
}

private let account = AccountID(1)
private let thread = ThreadKey(account: account, rowID: 1, gmailThreadID: GmailThreadID("t1"))
private let message = MessageKey(account: account, rowID: 1, gmailMessageID: GmailMessageID("m1"))
private let draft = DraftKey("d1")
private let sendToken = SendToken(draft: draft, sendAfter: Date(),
                                  payload: try! JSONEncoder().encode(RecordingEngine.sendReceipt))
private let undoToken = UndoToken(payload: try! JSONEncoder().encode(RecordingEngine.receipt))

private let portCalls: [(name: String, call: @Sendable (any MailCommanding) async throws -> Void)] = [
    ("apply", { _ = try await $0.apply(.markDone([thread])) }),
    ("undo", { _ = try await $0.undo(undoToken) }),
    ("createDraft", { _ = try await $0.createDraft(DraftInput(account: account, mode: .new)) }),
    ("updateDraft", { _ = try await $0.updateDraft(draft, DraftFields(subject: "x"), expectedVersion: 1) }),
    ("flushDraft", { try await $0.flushDraft(draft) }),
    ("discardDraft", { try await $0.discardDraft(draft) }),
    ("setReviewState", { try await $0.setReviewState(draft, .approved) }),
    ("resolveDraftConflict", { try await $0.resolveDraftConflict(draft, .keepLocal) }),
    ("send", { _ = try await $0.send(draft, undoWindow: .seconds(10)) }),
    ("cancelSend", { _ = try await $0.cancelSend(sendToken) }),
    ("sendNow", { _ = try await $0.sendNow(sendToken) }),
    ("scheduleSend", { try await $0.scheduleSend(draft, at: Date().addingTimeInterval(3_600)) }),
    ("cancelScheduledSend", { try await $0.cancelScheduledSend(draft) }),
    ("fetchDraftNow", { _ = try await $0.fetchDraftNow(account, gmailDraftID: GmailDraftID("r1")) }),
    ("fetchThreadNow", { _ = try await $0.fetchThreadNow(account, gmailThreadID: GmailThreadID("t1")) }),
    ("createLabel", { _ = try await $0.createLabel(account, name: "Synthetic", applyTo: [thread]) }),
    ("upsertSnippet", { _ = try await $0.upsertSnippet(SnippetInfo(name: "x", bodyHTML: "<p>x</p>")) }),
    ("deleteSnippet", { try await $0.deleteSnippet("s1") }),
    ("recordSnippetUse", { try await $0.recordSnippetUse("s1") }),
    ("storeSnippetAttachment", { _ = try await $0.storeSnippetAttachment(URL(fileURLWithPath: "/dev/null"), mimeType: "text/plain") }),
    ("storeSnippetAttachment", { _ = try await $0.storeSnippetAttachment(data: Data("x".utf8), filename: "x.txt", mimeType: "text/plain") }),
    ("unsubscribe", { try await $0.unsubscribe(message) }),
    ("upsertSplit", { _ = try await $0.upsertSplit(SplitDefinition(account: account, name: "x", ruleText: "is:starred")) }),
    ("deleteSplit", { try await $0.deleteSplit(account, SplitKey("s1")) }),
    ("reorderSplits", { try await $0.reorderSplits(account, [SplitKey("s1")]) }),
    ("dismissFailedOperation", { try await $0.dismissFailedOperation(1) }),
]

private func outcome(_ call: @Sendable (any MailCommanding) async throws -> Void,
                     on port: any MailCommanding) async -> MailPortError? {
    do {
        try await call(port)
        return nil
    } catch let error as MailPortError {
        return error
    } catch {
        return .unavailable("unexpected \(type(of: error))")
    }
}

@MainActor
private func refusedByTheDenyList(_ body: () async throws -> Void) async -> Bool {
    do {
        try await body()
        return false
    } catch GmailError.transport(.refusedByGuard) {
        return true
    } catch {
        return false
    }
}

@Test func theWritePortPassesEveryCallToTheEngine() async {
    let engine = RecordingEngine()
    let oneClicks = Mutex(0)
    let port = MailStoreCommands(engine: { engine }, oneClick: { _ in oneClicks.withLock { $0 += 1 } })
    for (name, call) in portCalls {
        #expect(await outcome(call, on: port) == nil, "\(name)")
    }
    #expect(engine.calls.contains("send") && engine.calls.contains("perform"))
    #expect(oneClicks.withLock { $0 } == 1)
    let withoutRequest = MailStoreCommands(engine: { engine })
    #expect(await outcome({ try await $0.unsubscribe(message) }, on: withoutRequest) == .unsupported("one-click unsubscribe"))
}

@Test func theWritePortTakesAChangeOfAnySize() async {
    let many = (1...500).map { ThreadKey(account: account, rowID: Int64($0), gmailThreadID: GmailThreadID("t\($0)")) }
    let engine = RecordingEngine()
    let port = MailStoreCommands(engine: { engine })
    #expect(await outcome({ _ = try await $0.apply(.star(many)) }, on: port) == nil)
    #expect(await outcome({ _ = try await $0.createLabel(account, name: "Synthetic", applyTo: many) }, on: port) == nil)
    for (name, call) in portCalls where ["send", "sendNow", "scheduleSend"].contains(name) {
        #expect(await outcome(call, on: port) == nil, "\(name)")
    }
    #expect(engine.calls == ["perform", "createLabel", "send", "sendNow", "scheduleSend"])
}

@Test func anAccountWithoutWriteAccessIsAskedToSignInAgain() async {
    let missing = EngineError.writeAccessMissing("perform: account 1 has not granted gmail.modify")
    let port = MailStoreCommands(engine: { throw missing })
    #expect(await outcome({ _ = try await $0.apply(.markDone([thread])) }, on: port)
        == .unavailable("the account needs to sign in again"))
    let setup = LiveAccountManager.setupError(missing)
    #expect(setup.kind == .refused && setup.message == LiveBackend.writeAccessNotice)
}

@MainActor
@Test func liveRefusesInsideATestRunBeforeAnythingOpens() throws {
    let temp = TemporaryDirectory("oh-home")
    defer { temp.cleanup() }
    let home = temp.url
    let launches = [
        CompositionRoot.live(environment: ["XCTestConfigurationFilePath": "x"]),
        CompositionRoot.live(environment: ["XCTestConfigurationFilePath": "x", "OPENHUMAN_HOME": home.path], arguments: []),
        CompositionRoot.makeApp(arguments: [], environment: ["OPENHUMAN_HOME": home.path]),
    ]
    for app in launches {
        guard case .notice(let problem) = app.screen else {
            Issue.record("expected the test-host notice")
            continue
        }
        #expect(problem.title == CompositionRoot.testHostTitle && problem.message == CompositionRoot.testHostMessage)
        #expect(problem.action == nil)
        #expect(app.session == nil && app.liveAccounts == nil)
    }
    #expect(!FileManager.default.fileExists(atPath: home.path), "the store directory must not be created")
}

@MainActor
private func realAccountBackend(scopes: [String], storedSwitch: ((MailStore) throws -> Void)? = nil) throws
    -> (backend: LiveBackend, store: MailStore, google: FakeGoogle, corpus: FakeCorpus) {
    let corpus = FakeCorpus.make(threadCount: 3, now: Date(timeIntervalSince1970: 1_790_000_000))
    let store = try MailStore.openInMemoryForTesting()
    try FixtureStoreSeeder.seed(store, corpus: corpus)
    _ = try store.addAccount(email: corpus.account.email, displayName: nil, scopes: scopes)
    try storedSwitch?(store)
    let tokens = InMemoryTokenStore([corpus.account.email: StoredToken(refreshToken: "synthetic-refresh", grantedScopes: scopes,
                                                                       clientID: SyntheticClient.clientID)])
    let google = FakeGoogle(gmail: FakeGmail(accountEmail: corpus.account.email), grantedScope: scopes.joined(separator: " "))
    let backend = liveBackend(google: google, store: store, tokens: tokens, browser: RecordingBrowser(),
                              clientPath: try SyntheticClient.writeJSON())
    return (backend, store, google, corpus)
}

@MainActor
@Test func aStoredWriteSwitchFromAnOlderVersionIsIgnored() async throws {
    let leftovers: [(String, (MailStore) throws -> Void)] = [
        ("saved off", { try $0.setSetting(SettingKey<Bool>(name: "write_mode.allow_changes", defaultValue: true, isSafetyKey: true),
                                         false, scope: .global) }),
        ("unreadable", { try $0.setSetting(SettingKey<String>(name: "write_mode.allow_changes", defaultValue: "",
                                                              isSafetyKey: false), "yes", scope: .global) }),
    ]
    for (name, leftover) in leftovers {
        let f = try realAccountBackend(scopes: [GmailScope.modify], storedSwitch: leftover)
        guard case .session(let item) = f.backend.initialStep() else {
            Issue.record("\(name): expected the account to open")
            continue
        }
        let session = try await f.backend.makeSession(for: item)
        let environment = session.environment
        #expect(environment.isLiveAccount && environment.draftsDirectory != nil, "\(name)")
        #expect(await refusedByTheDenyList { try await session.api.deleteDraft(id: "../messages/m1") },
                "\(name): the client is behind the deny list")
        #expect(f.google.http.requests.allSatisfy { $0.url.path() == "/token" }, "\(name): nothing reached Gmail")

        let ref = try #require(try f.store.threadPage(view: .system(item.id, .inbox), after: nil, limit: 1).items.first?.ref)
        let port = try #require(environment.commands)
        let token = try await port.apply(.markDone([MailStoreAdapter.threadKey(ref)]))
        #expect(!token.changesNothing, "\(name)")
        #expect(try !f.store.operations(account: item.id, statuses: [.pending], limit: 10).isEmpty, "\(name): queued for Gmail")
    }
}

@MainActor
@Test func aGrantWithoutModifyOnlyOffersSigningInAgain() async throws {
    let f = try realAccountBackend(scopes: [GmailScope.readonly])
    let item = try #require(try f.store.accounts().first)
    #expect(f.backend.initialStep() == .needsWriteAccess(item))
    await #expect(throws: GmailError.self) { _ = try await f.backend.makeSession(for: item) }
    let app = AppModel(live: f.backend)
    await app.launched()
    guard case .signIn(let signIn) = app.screen else {
        Issue.record("expected the sign-in screen")
        return
    }
    #expect(signIn.notice == LiveBackend.writeAccessNotice && signIn.loginHint == f.corpus.account.email)
    #expect(app.session == nil)
    #expect(f.google.http.requests.isEmpty, "nothing was asked of Google")
}

private enum AppSources {
    static let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static let glue = app.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Packages/OpenHumanMailLive/Sources/OpenHumanMailLive")

    static func all() throws -> [String: String] {
        let files = [app.appendingPathComponent("Sources"), glue].flatMap { root in
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        }
        var out: [String: String] = [:]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            out[file.lastPathComponent] = text.joined(separator: "\n")
        }
        return out
    }

    static func files(_ sources: [String: String], matching pattern: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: pattern)
        return Set(sources.filter { regex.firstMatch(in: $0.value, range: NSRange($0.value.startIndex..., in: $0.value)) != nil }
            .map(\.key))
    }

    static func arguments(of name: String, in text: String) -> [String] {
        var out: [String] = []
        var search = text.startIndex
        while let open = text.range(of: name + "(", range: search..<text.endIndex) {
            var depth = 0
            var index = text.index(before: open.upperBound)
            var end = text.endIndex
            while index < text.endIndex {
                if text[index] == "(" { depth += 1 }
                if text[index] == ")" { depth -= 1; if depth == 0 { end = index; break } }
                index = text.index(after: index)
            }
            out.append(String(text[open.upperBound..<end]))
            search = open.upperBound
        }
        return out
    }

    static func body(of signature: String, in text: String) -> String? {
        guard let start = text.range(of: signature) else { return nil }
        let rest = text[start.upperBound...]
        let next = rest.range(of: "\n    static func ") ?? rest.range(of: "\n    func ")
        return String(rest[..<(next?.lowerBound ?? rest.endIndex)])
    }
}

private enum RepoSources {
    static let root = AppSources.app.deletingLastPathComponent().deletingLastPathComponent()
    static let textExtensions: Set<String> = ["swift", "json", "plist", "strings", "sh", "py", "txt", "md", "yml", "yaml",
                                              "xcconfig"]

    static func all() -> [String: String] {
        var out: [String: String] = [:]
        for top in ["Apps", "Packages"] {
            let files = FileManager.default.enumerator(at: root.appendingPathComponent(top), includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])?.compactMap { $0 as? URL } ?? []
            for file in files where file.path.contains("/Sources/") && textExtensions.contains(file.pathExtension)
                && !["/build/", "/DerivedData/", "/SourcePackages/"].contains(where: { file.path.contains($0) }) {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                out[String(file.path.dropFirst(root.path.count))] = text
            }
        }
        return out
    }
}

@Test func everyRealAccountGmailRequestGoesThroughTheDenyList() throws {
    let sources = try AppSources.all()
    #expect(sources.count > 15, "found the app's sources")
    func text(_ file: String) throws -> String { try #require(sources[file], "\(file)") }
    func codeLines(_ text: String, containing needle: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains(needle) }
    }

    let live = try #require(AppSources.body(of: "static func live(", in: try text("CompositionRoot.swift")))
    let testHost = try #require(live.range(of: "environment[\"XCTestConfigurationFilePath\"] != nil"))
    #expect(live.contains("|| ProcessInfo.processInfo.environment[\"XCTestConfigurationFilePath\"] != nil {"))
    for later in ["StoreLocation.resolve(", "MailStore.open(", "keychainStores(", "URLSessionTransport(", "LiveBackend("] {
        let at = try #require(live.range(of: later), "\(later)")
        #expect(testHost.upperBound < at.lowerBound, "a test run is refused before \(later)")
    }
    #expect(codeLines(live, containing: "testHostTitle") == [
        "return AppModel(screen: .notice(StartupProblem(title: testHostTitle, message: testHostMessage)))",
    ])
    let backends = AppSources.arguments(of: "LiveBackend", in: live)
    #expect(backends.count == 1 && backends.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("store: store,") })
    #expect(AppSources.files(sources, matching: #"LiveBackend\("#) == ["CompositionRoot.swift"])
    #expect(AppSources.files(sources, matching: #"(?i)safe_?mode|write_?mode|OPENHUMAN_SAFE_MODE|AppRelaunch|allowChanges|write_mode\.allow_changes"#)
        .isEmpty, "no launch mode, no saved switch")
    #expect(AppSources.files(sources, matching: #"openedReadOnly|onOpenReadOnly|readOnlyFallback|writesNow"#).isEmpty)

    let backend = try text("LiveBackend.swift")
    #expect(codeLines(backend, containing: "grantedScopes.contains(GmailScope.modify)") == [
        "if !token.grantedScopes.contains(GmailScope.modify) {",
    ])
    #expect(backend.contains("if !token.grantedScopes.contains(GmailScope.modify) {\n                refusal = refusal ?? .needsWriteAccess(account)"))
    #expect(AppSources.files(sources, matching: #"makeSession\(for:"#) == ["AppModel.swift"])
    let appModel = try text("AppModel.swift")
    #expect(codeLines(appModel, containing: "makeSession(for:") == ["let session = try await backend.makeSession(for: account)"])
    #expect(codeLines(appModel, containing: "LiveBackend.writeAccessNotice") == [
        "showSignIn(backend: live, loginHint: account.email, notice: LiveBackend.writeAccessNotice)",
    ])

    #expect(AppSources.files(sources, matching: #"WriteAllowlistStore|WriteGuard\b|SafeModeTransport|allowlist:"#).isEmpty)
    #expect(AppSources.files(sources, matching: #"DenyListTransport\(|ReadOnlyTransport\("#).isEmpty)
    #expect(AppSources.files(sources, matching: #"OneClickGuard\("#) == ["OneClickUnsubscribe.swift"])
    #expect(codeLines(try text("OneClickUnsubscribe.swift"), containing: "OneClickGuard(") == [
        "self.transport = OneClickGuard(wrapping: transport)",
    ])
    #expect(AppSources.files(sources, matching: #"DefaultGmailClientFactory\("#) == ["FakeGmailLaunch.swift", "LiveBackend.swift"])
    let liveFactory = AppSources.arguments(of: "DefaultGmailClientFactory", in: backend)
    #expect(liveFactory.count == 1 && liveFactory.allSatisfy {
        $0.hasPrefix("apiTransport: transports.api,") && !$0.contains("storeDirectory") && !$0.contains("recipientGate")
    })
    let fakeFactory = AppSources.arguments(of: "DefaultGmailClientFactory", in: try text("FakeGmailLaunch.swift"))
    #expect(fakeFactory.count == 1 && fakeFactory.allSatisfy {
        $0.hasPrefix("apiTransport: wire,") && !$0.contains("storeDirectory") && !$0.contains("recipientGate")
    })

    let packages = AppSources.app.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Packages")
    let gmailSources = packages.appendingPathComponent("OpenHumanGmail/Sources/OpenHumanGmail")
    let factorySource = try String(contentsOf: gmailSources.appendingPathComponent("Client/DefaultGmailClientFactory.swift"),
                                   encoding: .utf8)
    #expect(factorySource.contains("private let apiTransport: DenyListTransport"))
    #expect(factorySource.contains("self.apiTransport = DefaultGmailClientFactory.guarded(apiTransport, recipients: recipientGate)"))
    #expect(factorySource.contains("return DenyListTransport(wrapping: transport, recipients: recipients)"))
    #expect(factorySource.components(separatedBy: "GmailClient(accountEmail:").count == 2, "one client construction")
    #expect(factorySource.contains("transport: apiTransport, config: config"))
    #expect(factorySource.contains("guard scopes.contains(GmailScope.modify) else {"))
    let denyList = try String(contentsOf: gmailSources.appendingPathComponent("Guards/DenyListTransport.swift"), encoding: .utf8)
    #expect(denyList.contains("public struct DenyListTransport: HTTPTransport"))

    let repo = RepoSources.all()
    #expect(repo.count > sources.count, "found the repository's sources")
    #expect(repo.filter { $0.value.contains("OPENHUMAN_SAFE_MODE") }.keys.sorted() == [], "no Sources/ reads the old variable")
    let factoryCall = try NSRegularExpression(pattern: #"\b(\w*Factory)\("#)
    for (path, code) in repo where path.hasSuffix(".swift") {
        let names = Set(factoryCall.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap {
            Range($0.range(at: 1), in: code).map { String(code[$0]) }
        })
        for name in names {
            #expect(!AppSources.arguments(of: name, in: code).contains { $0.contains("safeMode") }, "\(path): \(name)(")
        }
        if (path as NSString).lastPathComponent.contains("Factory") { #expect(!code.contains("safeMode"), "\(path)") }
    }

    let endpoints = try String(contentsOf: gmailSources.appendingPathComponent("Client/GmailEndpoints.swift"), encoding: .utf8)
    let entry = try NSRegularExpression(pattern: #"GmailEndpoint\(httpMethod: "(\w+)", template: (api|upload) \+ "([^"]+)"\)"#)
    let table = entry.matches(in: endpoints, range: NSRange(endpoints.startIndex..., in: endpoints)).compactMap { match -> (String, String)? in
        guard let method = Range(match.range(at: 1), in: endpoints), let root = Range(match.range(at: 2), in: endpoints),
              let path = Range(match.range(at: 3), in: endpoints) else { return nil }
        let prefix = endpoints[root] == "api" ? "/gmail/v1/users/me/" : "/upload/gmail/v1/users/me/"
        return (String(endpoints[method]), prefix + endpoints[path].replacingOccurrences(of: "{id}", with: "x1"))
    }
    #expect(table.count >= 25, "read the client's endpoint table")
    for (method, path) in table {
        let request = HTTPRequest(method: method, url: URL(string: "https://gmail.googleapis.com" + path)!, headers: [:])
        #expect(DenyListTransport.refusalReason(for: request) == nil, "\(method) \(path) is one of the client's endpoints")
    }
    var everything = sources
    for package in ["OpenHumanCore", "OpenHumanGmail", "OpenHumanStore", "OpenHumanSync", "OpenHumanCLI"] {
        let root = packages.appendingPathComponent(package).appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files where !file.path.contains("/OpenHumanGmailTesting/") {
            let code = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            everything["\(package)/\(file.lastPathComponent)"] = code
        }
    }
    let guards: Set<String> = ["OpenHumanGmail/DenyListTransport.swift", "OpenHumanGmail/ReadOnlyTransport.swift",
                               "OpenHumanGmail/GmailEndpoints.swift", "OpenHumanGmail/CalendarGuardTransport.swift"]
    let callers = AppSources.files(everything, matching: #""DELETE""#).subtracting(guards)
    // Reviewed: the scoped removal sends each write with a one-use authorization the calendar guard re-checks.
    #expect(callers == ["OpenHumanGmail/GmailClient.swift", "OpenHumanGmail/GoogleCalendarClient.swift",
                        "OpenHumanGmail/GoogleCalendarScopedRemoval.swift"])
    let scopedRemoval = try #require(everything["OpenHumanGmail/GoogleCalendarScopedRemoval.swift"])
    let scopedDeletes = codeLines(scopedRemoval, containing: "\"DELETE\"")
    #expect(scopedDeletes.count == 6 && scopedDeletes.allSatisfy { $0.contains("performRemoval(") })
    #expect(codeLines(scopedRemoval, containing: "isWrite: true").count == 1)
    #expect(codeLines(scopedRemoval, containing: "extraHeaders:") == [
        "extraHeaders: [CalendarGuardTransport.scopedRemovalHeader: nonce, \"If-Match\": etag])",
    ])
    let deletes = codeLines(try #require(everything["OpenHumanGmail/GmailClient.swift"]), containing: "\"DELETE\"")
    #expect(deletes.count == 1 && deletes.allSatisfy { $0.contains(".deleteDraft") && $0.contains("drafts/") })
    let calendarDeletes = codeLines(try #require(everything["OpenHumanGmail/GoogleCalendarClient.swift"]),
                                    containing: "\"DELETE\"")
    #expect(calendarDeletes.count == 2 && calendarDeletes.allSatisfy { $0.contains("\"events\", id]") })
    let guardedRemovals = calendarDeletes.filter { $0.contains("extraHeaders") || $0.contains("isWrite: true") }
    #expect(guardedRemovals.count == 1, "only the card's Delete is a write that asks for the organizer rule")
    let deniedPath = #""[^"\n]*/?\b(batchDelete|emptyTrash|emptySpam|forwardingAddresses|autoForwarding|delegates|vacation|settings/filters|settings/imap|settings/pop|settings/language|messages/import)\b[^"\n]*""#
    #expect(AppSources.files(everything, matching: deniedPath).subtracting(guards).isEmpty)
    #expect(AppSources.files(everything, matching: #"write_mode\.allow_changes"#).isEmpty, "the old switch is never read")

    let gmailWrites = #"\b(api|client|gmail|session\.api)\s*\.\s*(batchModifyMessages|modifyMessage|modifyThread|trashThread|untrashThread|trashMessage|untrashMessage|sendMessage|createDraft|updateDraft|deleteDraft|sendDraft|insertMessage|createLabel)\("#
    #expect(AppSources.files(sources, matching: gmailWrites).isEmpty)

    let engineWrites = #"engine(\(\))?\s*\.\s*(perform|undo|newDraft|saveDraft|flushDraft|discardDraft|setReviewState|send|sendNow|scheduleSend|cancelScheduledSend|cancelSend|createLabel|createAgentDraft|updateAgentDraft|upsertSnippet|deleteSnippet|recordSnippetUse|upsertSplit|deleteSplit|reorderSplits|resolveDraftConflict|dismissFailedOperation)\("#
    #expect(AppSources.files(sources, matching: engineWrites) == ["MailStoreCommands.swift"])
    let storeWrites = #"store\s*\.\s*(apply|undo|createDraft|updateDraft|updateAgentDraft|saveDraftRemotely|discardDraft|setReviewState|send|scheduleSend|cancelScheduledSend|cancelSend|sendNow|resolveDraftConflict|upsertSnippet|deleteSnippet|recordSnippetUse|upsertSplit|deleteSplit|reorderSplits|dismissFailedOperation)\("#
    #expect(AppSources.files(sources, matching: storeWrites) == ["MailStoreCommands.swift"])
    #expect(AppSources.files(sources, matching: #"flushPendingSends\("#) == ["SyncSession.swift"])
    #expect(AppSources.files(sources, matching: #"refreshOnce\(|refreshInBackground\("#) == ["SyncSession.swift"])
    #expect(AppSources.files(sources, matching: #"\.didEnterBackground\b"#) == ["SceneSystemEvents.swift"])
    #expect(AppSources.files(everything, matching: #"flushPendingSends\("#)
        == ["OpenHumanSync/MailEngine+Background.swift", "OpenHumanSync/MailEngine.swift", "SyncSession.swift"])
    #expect(codeLines(try #require(everything["OpenHumanSync/MailEngine+Background.swift"]), containing: "flushPendingSends(")
        == ["await flushPendingSends(deadline: Self.backgroundFlushDeadline)"])
    #expect(AppSources.files(everything, matching: #"refreshOnce\("#)
        == ["OpenHumanSync/MailEngine+Background.swift", "SyncSession.swift"])
    let repoSwift = repo.filter { $0.key.hasSuffix(".swift") }
    let engineDir = "/Packages/OpenHumanSync/Sources/OpenHumanSync/Engine/"
    let liveDir = "/Packages/OpenHumanMailLive/Sources/OpenHumanMailLive/Live/"
    #expect(AppSources.files(repoSwift, matching: #"refreshPass\("#) == [engineDir + "MailEngine+Background.swift"])
    #expect(codeLines(try #require(everything["OpenHumanSync/MailEngine+Background.swift"]), containing: "refreshPass(") == [
        "let pass = refreshPass(deadline: deadline, maxOperations: maxOperations)",
        "func refreshPass(deadline: Date, maxOperations: Int) -> Task<RefreshReport, Never> {",
    ])
    #expect(AppSources.files(repoSwift, matching: #"refreshOnce\(|refreshInBackground\("#)
        == [engineDir + "MailEngine+Background.swift", liveDir + "SyncSession.swift"])
    #expect(AppSources.files(repoSwift, matching: #"flushPendingSends\("#)
        == [engineDir + "MailEngine+Background.swift", engineDir + "MailEngine.swift", liveDir + "SyncSession.swift"])
    #expect(AppSources.files(repoSwift, matching: #"\.didEnterBackground\b"#)
        == [engineDir + "MailEngine.swift", liveDir + "SceneSystemEvents.swift"])
    #expect(codeLines(try #require(everything["OpenHumanSync/MailEngine.swift"]), containing: ".didEnterBackground")
        == ["case .didEnterBackground:"])

    let session = try text("SyncSession.swift")
    #expect(AppSources.files(sources, matching: #"MailStoreCommands\("#) == ["SyncSession.swift"])
    #expect(session.contains("MailStoreCommands(engine: { try slot.engine() }, oneClick: oneClick)"))
    #expect(session.contains("OneClickUnsubscribe(store: store, transport: transport)"))
    #expect(session.contains("isFake: isFake, isLiveAccount: !isFake,"), "a real account is live, FakeGmail is not")
    #expect(AppSources.files(sources, matching: #"MailEngine\("#) == ["SyncSession.swift"])

    let model = AppSources.app.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Packages/OpenHumanMailCore/Sources/MailModel")
    let requirements = try ["Commands.swift", "UndoToken.swift"].flatMap { file -> [String] in
        let protocolText = try String(contentsOf: model.appendingPathComponent(file), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"(?m)^\s+func (\w+)\("#)
        return regex.matches(in: protocolText, range: NSRange(protocolText.startIndex..., in: protocolText)).compactMap {
            Range($0.range(at: 1), in: protocolText).map { String(protocolText[$0]) }
        }
    }
    #expect(Set(requirements) == Set(portCalls.map(\.name)), "the call table covers the whole port")

    #expect(AppSources.files(sources, matching: #"GoogleCalendarSession\("#) == ["LiveBackend.swift"])
    #expect(AppSources.files(sources, matching: #"GoogleCalendarClient\("#) == ["GoogleCalendarSession.swift"])
    #expect(AppSources.files(sources, matching: #"GoogleCalendarProvider\("#) == ["GoogleCalendarSession.swift"])
    #expect(AppSources.files(sources, matching: #"CalendarGuardTransport|CalendarScope\.|include_granted"#).isEmpty)
    #expect(!(try text("FakeGmailLaunch.swift")).contains("calendar"))
    #expect(try text("CompositionRoot.swift").contains("guard !arguments.contains(\"-UseFakeCalendar\") else { return nil }"))
    #expect(AppSources.files(sources, matching: #"= liveCalendarTokenStore\("#) == ["CompositionRoot.swift"])
    let manager = try text("LiveAccountManager.swift")
    #expect(AppSources.files(sources, matching: #"OAuthFlow\("#) == ["LiveAccountManager.swift"])
    #expect(codeLines(manager, containing: "OAuthFlow(") == [
        "OAuthFlow(client: client, scopes: OAuthScopes.mailRequest, transport: dependencies.transport,",
    ])
    #expect(codeLines(manager, containing: "makeFlow(").allSatisfy {
        $0.contains("makeFlow(client)") || $0.hasPrefix("private func makeFlow(_ client: OAuthClientConfig) -> OAuthFlow {")
    })
}
