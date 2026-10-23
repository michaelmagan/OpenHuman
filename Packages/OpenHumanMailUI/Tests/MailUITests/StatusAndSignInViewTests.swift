#if os(macOS)
import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI

private struct OnlineFake: MailDataSource {
    let base = FakeMailStore(corpus: .make(threadCount: 1))
    func accounts() -> AsyncThrowingStream<[Account], Error> { base.accounts() }
    func threadWindow(_ location: MailLocation, account: AccountID, limit: Int) -> AsyncThrowingStream<ThreadListWindow, Error> {
        base.threadWindow(location, account: account, limit: limit)
    }
    func threadDetail(_ key: ThreadKey) -> AsyncThrowingStream<ConversationDetail?, Error> { base.threadDetail(key) }
    func body(_ key: MessageKey) -> AsyncThrowingStream<BodyLoadState, Error> { base.body(key) }
    func connectivity() -> AsyncStream<[AccountID: ConnectivityState]> {
        AsyncStream { continuation in
            continuation.yield([AccountID(1): .online(syncing: false, lastSyncAt: Date().addingTimeInterval(-120))])
            continuation.finish()
        }
    }
}

private struct NoClient: AccountManaging {
    func oauthClientStatus() -> AsyncStream<OAuthClientStatus> {
        AsyncStream { $0.yield(.missing); $0.finish() }
    }
    func importOAuthClient(json: Data) async throws {}
    func addAccount(loginHint: String?) async throws -> AccountID { AccountID(1) }
}

private struct RemoteReady: AccountManaging {
    func oauthClientStatus() -> AsyncStream<OAuthClientStatus> {
        AsyncStream { $0.yield(.configured(source: .environment)); $0.finish() }
    }
    func importOAuthClient(json: Data) async throws {}
    func addAccount(loginHint: String?) async throws -> AccountID { AccountID(1) }
    func beginRemoteSignIn(loginHint: String?) async throws -> RemoteSignInChallenge {
        RemoteSignInChallenge(url: URL(string: "https://accounts.example.invalid/auth?state=s")!, expiresAt: Date())
    }
}

private struct NoSecret: AccountManaging {
    func oauthClientStatus() -> AsyncStream<OAuthClientStatus> {
        AsyncStream { $0.yield(.configuredWithoutSecret(source: .file)); $0.finish() }
    }
    func importOAuthClient(json: Data) async throws {}
    func addAccount(loginHint: String?) async throws -> AccountID { AccountID(1) }
}

private struct LongAddress: AccountManaging {
    func oauthClientStatus() -> AsyncStream<OAuthClientStatus> {
        AsyncStream { $0.yield(.configured(source: .environment)); $0.finish() }
    }
    func importOAuthClient(json: Data) async throws {}
    func addAccount(loginHint: String?) async throws -> AccountID { AccountID(1) }
    func beginRemoteSignIn(loginHint: String?) async throws -> RemoteSignInChallenge {
        let url = "https://accounts.example.invalid/o/oauth2/v2/auth?client_id=synthetic-client-id.apps.example.invalid"
            + "&redirect_uri=http%3A%2F%2F127.0.0.1%3A50000%2Foauth2callback&response_type=code"
            + "&scope=https%3A%2F%2Fwww.example.invalid%2Fauth%2Fgmail.modify&code_challenge=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abc"
            + "&code_challenge_method=S256&state=synthetic-random-state-value&access_type=offline"
        return RemoteSignInChallenge(url: URL(string: url)!, expiresAt: Date())
    }
}

@MainActor
private func host<V: View>(_ view: V, size: NSSize, name: String) throws -> NSHostingView<V> {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(origin: .zero, size: size)
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
@Test func statusBarShowsSyncWithinTheFooterHeight() async throws {
    let model = StatusModel(data: OnlineFake())
    await model.run()
    #expect(model.isVisible)
    #expect(FooterView.isVisible(status: model, hints: nil))
    let height = NativeMetrics.HintLine.height
    #expect(FooterView.height == height)
    let view = FooterView(status: model, hints: nil, theme: .light)
    let hosting = try host(view, size: NSSize(width: 1360, height: height), name: "status-bar")
    #expect(hosting.fittingSize.height == height)
}

@MainActor
@Test func signInScreenLaysOutWithoutAClient() async throws {
    let model = SignInModel(accounts: NoClient(), loginHint: "robin@example.com")
    await model.run()
    #expect(model.phase == .needsClient)
    let hosting = try host(SignInView(model: model, theme: .light), size: NSSize(width: 960, height: 640),
                           name: "sign-in-needs-client")
    #expect(hosting.fittingSize.width >= 440)
}

@MainActor
@Test func signInFromAnotherDeviceScreenLaysOut() async throws {
    let model = SignInModel(accounts: RemoteReady())
    await model.run()
    #expect(model.canSignInFromAnotherDevice)
    _ = try host(SignInView(model: model, theme: .light), size: NSSize(width: 960, height: 640), name: "sign-in-ready")
    model.beginRemote()
    while model.phase != .remotePaste { await Task.yield() }
    let hosting = try host(SignInView(model: model, theme: .light), size: NSSize(width: 960, height: 640),
                           name: "sign-in-from-another-device")
    #expect(hosting.fittingSize.width >= 440)
}

@MainActor
@Test func signInScreenWithoutASecretShowsImportAtBothSizes() async throws {
    let model = SignInModel(accounts: NoSecret())
    await model.run()
    #expect(!model.canSignIn)
    #expect(model.canImportClient)
    for (w, h, name) in [(680, 780, "default"), (480, 600, "narrow")] {
        _ = try host(SignInView(model: model, theme: .light), size: NSSize(width: w, height: h),
                     name: "sign-in-no-secret-\(name)")
    }
}

@MainActor
@Test func signInWordsAreTheUsersAndCodesGoOnADetailsLine() {
    #expect(!SignInView.accessText.contains("gmail.") && !SignInView.accessText.lowercased().contains("mode"))
    #expect(SignInView.accessText.hasSuffix("never asks to delete mail permanently or to change Gmail settings or filters."))
    let split = SignInView.splitDetails("Google refused the sign-in. Try again.\nDetails: while refreshing, HTTP 400")
    #expect(split.message == "Google refused the sign-in. Try again." && split.details == "while refreshing, HTTP 400")
    let plain = SignInView.splitDetails("Sign-in was cancelled.")
    #expect(plain.message == "Sign-in was cancelled." && plain.details == nil)
}

@MainActor
@Test func longAddressScreenLaysOutAtDefaultAndNarrowSizes() async throws {
    let model = SignInModel(accounts: LongAddress())
    await model.run()
    model.beginRemote()
    while model.phase != .remotePaste { await Task.yield() }
    for (w, h, name) in [(680, 780, "default"), (480, 600, "narrow")] {
        _ = try host(SignInView(model: model, theme: .light), size: NSSize(width: w, height: h),
                     name: "sign-in-address-\(name)")
    }
}
#endif
