import Foundation
import MailActions
import Synchronization
import Testing
@testable import MailFeatures

private let updateNow = Date(timeIntervalSince1970: 1_791_000_000)
private let earlyBuild = BuildLabel(version: "0.1.0", build: "1001", channel: "early-development")
private let stableBuild = BuildLabel(version: "0.1.0", build: "1001", channel: "")

private func releaseJSON(_ tag: String, draft: Bool = false, prerelease: Bool = true, body: String? = nil,
                         page: String? = nil) -> [String: Any] {
    var object: [String: Any] = [
        "tag_name": tag, "name": "OpenHuman Mail \(tag)", "draft": draft, "prerelease": prerelease,
        "html_url": page ?? "https://github.com/michaelmagan/OpenHuman/releases/tag/\(tag)",
    ]
    if let body { object["body"] = body }
    return object
}

private func feedReply(_ status: Int, _ object: Any, headers: [String: String] = [:]) -> UpdateFeedReply {
    UpdateFeedReply(status: status, headers: headers, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
}

private func sampleRelease(_ version: String, preRelease: Bool = false) throws -> UpdateRelease {
    UpdateRelease(version: try #require(AppVersion(version)), page: UpdateFeed.openHuman.releasesPage, isPreRelease: preRelease)
}

final class FakeUpdateFeed: Sendable {
    private let state: Mutex<(requests: [URL], answers: [Result<UpdateFeedReply, UpdateFeedFailure>])>

    init(_ answers: Result<UpdateFeedReply, UpdateFeedFailure>...) {
        state = Mutex((requests: [], answers: answers))
    }

    var requests: [URL] { state.withLock { $0.requests } }

    var fetch: UpdateFeedFetch {
        { [self] url in try answer(url) }
    }

    private func answer(_ url: URL) throws -> UpdateFeedReply {
        let next: Result<UpdateFeedReply, UpdateFeedFailure> = state.withLock { s in
            s.requests.append(url)
            return s.answers.isEmpty ? .failure(.unreachable) : s.answers.removeFirst()
        }
        return try next.get()
    }
}

@Suite struct UpdateCheckTests {
    @Test func theFeedIsOneConstantPlaceOnGitHub() {
        let feed = UpdateFeed.openHuman
        #expect(feed.repository == "michaelmagan/OpenHuman")
        #expect(feed.releasesURL.absoluteString == "https://api.github.com/repos/michaelmagan/OpenHuman/releases?per_page=10")
        #expect(feed.releasesPage.absoluteString == "https://github.com/michaelmagan/OpenHuman/releases")
        #expect(UpdateFeed(repository: "someone/Fork.2")?.releasesURL.host() == "api.github.com")
        for bad in ["", "a", "a/b/c", "a/", "/b", "a b/c", "a/b?x=1", "a/b#x", "../x", "a/..", ".a/b", "a/-b", "a/b%2F"] {
            #expect(UpdateFeed(repository: bad) == nil, "\(bad)")
        }
    }

    @Test func downloadOpensOnlyThisRepositorysReleasePages() {
        let feed = UpdateFeed.openHuman
        let tag = "https://github.com/michaelmagan/OpenHuman/releases/tag/v0.2.0"
        #expect(feed.downloadPage(for: tag).absoluteString == tag)
        #expect(feed.downloadPage(for: "https://github.com/MichaelMagan/openhuman/releases/tag/v0.2.0").absoluteString
                == "https://github.com/MichaelMagan/openhuman/releases/tag/v0.2.0", "GitHub names are not case-sensitive")
        let hostile: [String?] = [
            nil, "", "not a url", "http://github.com/michaelmagan/OpenHuman/releases/tag/v1",
            "https://evil.example/michaelmagan/OpenHuman/releases/tag/v1",
            "https://github.com.evil.example/michaelmagan/OpenHuman/releases/tag/v1",
            "https://user@github.com/michaelmagan/OpenHuman/releases/tag/v1",
            "https://github.com:8443/michaelmagan/OpenHuman/releases/tag/v1",
            "https://github.com/someone/Other/releases/tag/v1", "https://github.com/michaelmagan/OpenHuman/archive/v1.zip",
            "https://github.com/michaelmagan/OpenHuman/releases/../../evil", "javascript:alert(1)", "file:///etc/passwd",
        ]
        for candidate in hostile {
            #expect(feed.downloadPage(for: candidate) == feed.releasesPage, "\(candidate ?? "nil")")
        }
    }

    @Test func aRedirectIsFollowedOnlyToGitHub() throws {
        let api = UpdateFeed.openHuman.releasesURL
        let allowed = [
            "https://api.github.com/repositories/123456/releases?per_page=10",
            "https://github.com/michaelmagan/OpenHuman/releases/download/v0.2.0/OpenHuman-Mail.zip",
            "HTTPS://API.GitHub.com/repositories/123456/releases",
        ]
        for target in allowed {
            let url = try #require(URL(string: target))
            #expect(UpdateFeed.allowsRedirect(from: api, to: url, count: 1), "\(target)")
        }
        let moved = try #require(URL(string: "/repositories/123456/releases", relativeTo: api))
        #expect(UpdateFeed.allowsRedirect(from: api, to: moved, count: 1), "a relative location stays on GitHub")
        let refused = [
            "http://api.github.com/repos/michaelmagan/OpenHuman/releases", "http://github.com/michaelmagan/OpenHuman/releases",
            "https://evil.test/releases", "https://api.github.com.evil.test/releases", "https://github.com.evil.test/releases",
            "https://evilgithub.com/releases", "https://github.co/releases", "https://gist.github.com/releases",
            "https://objects.githubusercontent.com/releases", "https://github.com./releases", "https://github%2Ecom/releases",
            "https://g\u{0456}thub.com/releases", "https://140.82.112.6/releases",
            "https://github.com@evil.test/releases", "https://github.com%40evil.test/releases",
            "https://github.com\\@evil.test/releases", "https://user:@github.com/releases", "https://:@api.github.com/releases",
            "https://@github.com/releases", "https://github.com:443/releases", "https://api.github.com:8443/releases",
            "//github.com/releases", "//evil.test/releases", "https:github.com/releases",
            "ftp://github.com/releases", "wss://api.github.com/releases", "file:///etc/hosts", "javascript:alert(1)",
            "data:text/plain,github.com",
        ]
        for target in refused {
            let url = try #require(URL(string: target), "\(target)")
            #expect(!UpdateFeed.allowsRedirect(from: api, to: url, count: 1), "\(target)")
        }
        let elsewhere = try #require(URL(string: "//evil.test/releases", relativeTo: api))
        #expect(!UpdateFeed.allowsRedirect(from: api, to: elsewhere, count: 1), "a scheme-relative location keeps its host")
    }

    @Test func aRedirectChainEndsAfterThreeHopsAndOnlyContinuesFromGitHub() throws {
        let api = UpdateFeed.openHuman.releasesURL
        let assets = try #require(URL(string: "https://github.com/michaelmagan/OpenHuman/releases/download/v0.2.0/Mail.zip"))
        #expect(UpdateFeed.maxRedirects == 3)
        for count in 1...3 {
            #expect(UpdateFeed.allowsRedirect(from: api, to: assets, count: count), "\(count)")
        }
        #expect(UpdateFeed.allowsRedirect(from: assets, to: api, count: 2))
        for count in [4, 5, Int.max, 0, -1, Int.min] {
            #expect(!UpdateFeed.allowsRedirect(from: api, to: assets, count: count), "\(count)")
        }
        for source in ["https://evil.test/releases", "http://api.github.com/releases", "https://user:@github.com/releases"] {
            let url = try #require(URL(string: source))
            #expect(!UpdateFeed.allowsRedirect(from: url, to: assets, count: 1), "\(source)")
        }
    }

    @Test func theNewestPublishedReleaseIsFoundInAnyOrder() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            releaseJSON("v0.1.0"), releaseJSON("v0.3.0", draft: true),
            releaseJSON("v0.2.0", body: "## Changes\n- Faster search\n\n* Fixed sync\n---\nMore\nFifth"),
            releaseJSON("not-a-version"), releaseJSON("v0.1.1", prerelease: false),
        ])
        let releases = try #require(UpdateCheck.releases(in: data, feed: .openHuman))
        #expect(releases.map(\.version.description) == ["0.1.0", "0.2.0", "0.1.1"], "drafts and unreadable tags are skipped")
        #expect(releases.map(\.isPreRelease) == [true, true, false])
        let newest = try #require(UpdateCheck.newest(releases))
        #expect(newest.version.description == "0.2.0" && newest.name == "OpenHuman Mail v0.2.0")
        #expect(newest.noteLines == ["Changes", "• Faster search", "• Fixed sync", "More"])
        #expect(newest.page.absoluteString == "https://github.com/michaelmagan/OpenHuman/releases/tag/v0.2.0")
        #expect(UpdateCheck.newest([]) == nil)
        let tie = [try sampleRelease("0.2.0"), try sampleRelease("v0.2.0", preRelease: true)]
        #expect(UpdateCheck.newest(tie)?.isPreRelease == false, "the first of two equal versions is kept")
    }

    @Test func oneReleaseObjectAndEmptyOrBrokenAnswers() throws {
        let one = try JSONSerialization.data(withJSONObject: releaseJSON("v0.4.0"))
        #expect(UpdateCheck.releases(in: one, feed: .openHuman)?.map(\.version.description) == ["0.4.0"])
        #expect(UpdateCheck.releases(in: Data("[]".utf8), feed: .openHuman) == [])
        #expect(UpdateCheck.releases(in: Data("{\"message\":\"Not Found\"}".utf8), feed: .openHuman) == [])
        for broken in ["not json", "[1, 2]", "", "<html>"] {
            #expect(UpdateCheck.releases(in: Data(broken.utf8), feed: .openHuman) == nil, "\(broken)")
        }
        let huge = Data(repeating: 0x20, count: UpdateCheck.maxReplyBytes + 1)
        #expect(UpdateCheck.releases(in: huge, feed: .openHuman) == nil)
    }

    @Test func releaseNotesShowTheirFirstLinesAsPlainText() {
        let body = "# Title\u{202E}\n\n\t- one\u{0007}\n" + String(repeating: "x", count: 200) + "\nfour\nfive"
        let lines = UpdateCheck.noteLines(body)
        #expect(lines.count == UpdateCheck.noteLineLimit)
        #expect(lines.first == "Title" && lines.dropFirst().first == "• one")
        #expect(lines[2].count == UpdateCheck.noteLineLength && lines[2].hasSuffix("…"))
        #expect(lines.last == "four")
        #expect(UpdateCheck.noteLines(nil).isEmpty && UpdateCheck.noteLines("\n\n---\n***\n").isEmpty)
    }

    @Test func everyAnswerMapsToACalmOutcome() {
        func evaluate(_ outcome: Result<UpdateFeedReply, UpdateFeedFailure>) -> UpdateCheckResult {
            UpdateCheck.evaluate(outcome, current: earlyBuild, feed: .openHuman, now: updateNow)
        }
        #expect(evaluate(.success(UpdateFeedReply(status: 404))) == .notPublishedYet,
                "a private or missing repository reads as not published yet")
        #expect(evaluate(.success(UpdateFeedReply(status: 410))) == .notPublishedYet)
        #expect(evaluate(.success(feedReply(200, [Any]()))) == .notPublishedYet)
        #expect(evaluate(.success(feedReply(200, [releaseJSON("v0.9.0", draft: true)]))) == .notPublishedYet)
        #expect(evaluate(.failure(.offline)) == .couldNotCheck(.offline))
        #expect(evaluate(.failure(.timedOut)) == .couldNotCheck(.unavailable))
        #expect(evaluate(.failure(.unreachable)) == .couldNotCheck(.unavailable))
        #expect(evaluate(.failure(.redirectRefused)) == .couldNotCheck(.unavailable))
        #expect(evaluate(.success(UpdateFeedReply(status: 500))) == .couldNotCheck(.unavailable))
        #expect(evaluate(.success(UpdateFeedReply(status: 401))) == .couldNotCheck(.unavailable))
        #expect(evaluate(.success(UpdateFeedReply(status: 403))) == .couldNotCheck(.unavailable), "a refusal that is not a limit")
        #expect(evaluate(.success(UpdateFeedReply(status: 200, body: Data("<html>".utf8)))) == .couldNotCheck(.unreadable))
        let reset = updateNow.addingTimeInterval(12 * 60)
        let limited = UpdateFeedReply(status: 403, headers: ["X-RateLimit-Remaining": "0",
                                                             "X-RateLimit-Reset": "\(Int(reset.timeIntervalSince1970))"])
        #expect(evaluate(.success(limited)) == .couldNotCheck(.rateLimited(retryAt: reset)))
        #expect(evaluate(.success(UpdateFeedReply(status: 429, headers: ["retry-after": "90"])))
                == .couldNotCheck(.rateLimited(retryAt: updateNow.addingTimeInterval(90))))
        #expect(evaluate(.success(UpdateFeedReply(status: 403, headers: ["Retry-After": "30"])))
                == .couldNotCheck(.rateLimited(retryAt: updateNow.addingTimeInterval(30))), "a secondary limit")
        #expect(evaluate(.success(UpdateFeedReply(status: 429))) == .couldNotCheck(.rateLimited(retryAt: nil)))
        #expect(evaluate(.success(UpdateFeedReply(status: 429, headers: ["retry-after": "soon"])))
                == .couldNotCheck(.rateLimited(retryAt: nil)))
    }

    @Test func theRunningVersionIsComparedWithTheNewestRelease() {
        func evaluate(_ tags: [String], _ label: BuildLabel = earlyBuild) -> UpdateCheckResult {
            UpdateCheck.evaluate(.success(feedReply(200, tags.map { releaseJSON($0) })), current: label, feed: .openHuman,
                                 now: updateNow)
        }
        func isAvailable(_ result: UpdateCheckResult, _ version: String) -> Bool {
            if case .available(let release) = result { return release.version.description == version }
            return false
        }
        func isUpToDate(_ result: UpdateCheckResult) -> Bool {
            if case .upToDate = result { return true }
            return false
        }
        #expect(isAvailable(evaluate(["v0.1.0", "v0.2.0"]), "0.2.0"))
        #expect(isAvailable(evaluate(["v0.2.0", "v0.1.1", "v0.1.0"]), "0.2.0"))
        #expect(isUpToDate(evaluate(["v0.1.0"])), "same version")
        #expect(isUpToDate(evaluate(["v0.0.9"])), "a build ahead of the newest release")
        #expect(isAvailable(evaluate(["v0.1.0+1002"]), "0.1.0"), "same version, newer build")
        #expect(isUpToDate(evaluate(["v0.1.0+1001"])), "same version, same build")
        #expect(isUpToDate(evaluate(["v0.1.0+1000"])), "same version, older build")
        #expect(isUpToDate(evaluate(["v0.1.0-early.3"])), "a pre-release of the running version is older")
        #expect(isAvailable(evaluate(["v0.1.1-early.1"]), "0.1.1-early.1"))
        #expect(isAvailable(evaluate(["v0.1.0"], BuildLabel(version: "0", build: "0", channel: "")), "0.1.0"))
    }

    @Test func theWordsAreCalmAndSayWhatHappened() throws {
        let next = try sampleRelease("0.2.0", preRelease: true), current = try sampleRelease("0.1.0")
        #expect(UpdateCheck.message(for: .available(next), current: earlyBuild, now: updateNow)
                == UpdateCheckMessage(headline: "Version 0.2.0 is available", detail: "You have version 0.1.0 (1001).", tone: .news))
        #expect(UpdateCheck.message(for: .upToDate(newest: current), current: earlyBuild, now: updateNow)
                == UpdateCheckMessage(headline: "OpenHuman Mail is up to date", detail: "You have version 0.1.0 (1001), the newest release.",
                                      tone: .good))
        let ahead = BuildLabel(version: "0.3.0", build: "5", channel: "early-development")
        #expect(UpdateCheck.message(for: .upToDate(newest: current), current: ahead, now: updateNow).detail
                == "You have version 0.3.0 (5). The newest release is 0.1.0.")
        let notYet = UpdateCheck.message(for: .notPublishedYet, current: earlyBuild, now: updateNow)
        #expect(notYet == UpdateCheckMessage(headline: "Couldn't check yet",
                                             detail: "There's no published release to compare with yet. Try again later.", tone: .neutral))
        for word in ["error", "fail", "private", "404", "denied", "not found"] {
            #expect(!(notYet.headline + " " + notYet.detail).lowercased().contains(word), "\(word)")
        }
        let limited = UpdateCheck.message(for: .couldNotCheck(.rateLimited(retryAt: updateNow.addingTimeInterval(11 * 60 + 5))),
                                          current: earlyBuild, now: updateNow)
        #expect(limited.headline == "Couldn't check for updates" && limited.tone == .attention)
        #expect(limited.detail == "GitHub is answering too many checks from this network right now. Try again in about 12 minutes.")
        #expect(UpdateCheck.wait(until: updateNow.addingTimeInterval(20), now: updateNow) == "Try again in a minute.")
        #expect(UpdateCheck.wait(until: updateNow.addingTimeInterval(-5), now: updateNow) == "Try again in a minute.")
        #expect(UpdateCheck.wait(until: nil, now: updateNow) == "Try again later.")
        #expect(UpdateCheck.message(for: .couldNotCheck(.offline), current: earlyBuild, now: updateNow).detail
                == "Mail couldn't reach GitHub. Check your internet connection, then try again.")
        #expect(UpdateCheck.summary(for: .available(next), now: updateNow) == "Version 0.2.0 is available.")
        #expect(UpdateCheck.summary(for: .upToDate(newest: current), now: updateNow) == "Up to date. The newest release is 0.1.0.")
        #expect(UpdateCheck.summary(for: .notPublishedYet, now: updateNow)
                == "Couldn't check yet. There's no published release to compare with yet. Try again later.")
        #expect(UpdateCheck.summary(for: .couldNotCheck(.unreadable), now: updateNow)
                == "Couldn't check. GitHub's answer couldn't be read. Try again later.")
    }

    @Test func earlyDevelopmentBuildsSaySo() throws {
        #expect(UpdateCheck.earlyDevelopmentNote == "This is an early-development release.")
        #expect(UpdateCheck.earlyDevelopmentLine(for: nil, current: earlyBuild) == UpdateCheck.earlyDevelopmentNote)
        #expect(UpdateCheck.earlyDevelopmentLine(for: .notPublishedYet, current: earlyBuild) == UpdateCheck.earlyDevelopmentNote)
        #expect(UpdateCheck.earlyDevelopmentLine(for: nil, current: stableBuild) == nil)
        #expect(UpdateCheck.earlyDevelopmentLine(for: .available(try sampleRelease("0.2.0", preRelease: true)), current: stableBuild)
                == "Version 0.2.0 is an early-development release.")
        #expect(UpdateCheck.earlyDevelopmentLine(for: .available(try sampleRelease("0.2.0")), current: earlyBuild)
                == UpdateCheck.earlyDevelopmentNote)
    }

    @Test func thePrivacyNoteSaysWhenAndWhatIsSent() {
        #expect(UpdateCheck.privacyNote.contains("only when you click") && UpdateCheck.privacyNote.contains("one request"))
        #expect(UpdateCheck.privacyNote.contains("never downloads or installs anything"))
    }
}

@MainActor
@Suite struct UpdateCheckCenterTests {
    private func makeCenter(_ feed: FakeUpdateFeed, label: BuildLabel = earlyBuild,
                            open: @escaping @MainActor (URL) -> Void = { _ in }) -> UpdateCheckCenter {
        UpdateCheckCenter(current: label, fetch: feed.fetch, openURL: open, now: { updateNow })
    }

    @Test func nothingIsAskedUntilAClick() async {
        let feed = FakeUpdateFeed(.success(feedReply(200, [releaseJSON("v0.2.0")])))
        let center = makeCenter(feed)
        await center.settle()
        #expect(center.phase == .idle && center.message == nil && center.summary == nil && !center.isPresented)
        #expect(feed.requests.isEmpty)
        #expect(center.versionLine == "You have version 0.1.0 (1001).")
        #expect(center.earlyDevelopmentLine == "This is an early-development release.")
    }

    @Test func theMenuOpensTheSheetAndASecondClickJoinsTheRunningCheck() async throws {
        let feed = FakeUpdateFeed(.success(feedReply(200, [releaseJSON("v0.1.0"), releaseJSON("v0.2.0", body: "Faster search")])))
        var shown = 0
        let center = makeCenter(feed)
        center.showWindow = { shown += 1 }
        center.begin()
        center.begin()
        #expect(center.isPresented && center.isChecking && shown == 2)
        #expect(center.message == UpdateCheck.checking && center.summary == "Checking…")
        await center.settle()
        #expect(feed.requests == [UpdateFeed.openHuman.releasesURL], "one request")
        let release = try #require(center.available)
        #expect(release.version.description == "0.2.0" && release.noteLines == ["Faster search"])
        #expect(center.message?.headline == "Version 0.2.0 is available" && center.summary == "Version 0.2.0 is available.")
        #expect(center.earlyDevelopmentLine == "Version 0.2.0 is an early-development release.")
    }

    @Test func downloadOpensTheReleasePageInTheBrowserAndFetchesNothing() async {
        let page = "https://github.com/michaelmagan/OpenHuman/releases/tag/v0.2.0"
        let feed = FakeUpdateFeed(.success(feedReply(200, [releaseJSON("v0.2.0", page: page)])))
        var opened: [URL] = []
        let center = makeCenter(feed, open: { opened.append($0) })
        center.begin()
        await center.settle()
        center.download()
        #expect(opened.map(\.absoluteString) == [page] && !center.isPresented)
        #expect(feed.requests.count == 1)
    }

    @Test func aReleaseLinkElsewhereOpensTheReleasesPageInstead() async {
        let feed = FakeUpdateFeed(.success(feedReply(200, [releaseJSON("v0.2.0", page: "https://evil.example/OpenHuman.dmg")])))
        var opened: [URL] = []
        let center = makeCenter(feed, open: { opened.append($0) })
        await center.check()
        center.download()
        #expect(opened == [UpdateFeed.openHuman.releasesPage])
    }

    @Test func downloadDoesNothingWithoutANewerRelease() async {
        let feed = FakeUpdateFeed(.success(feedReply(200, [releaseJSON("v0.1.0")])))
        var opened: [URL] = []
        let center = makeCenter(feed, open: { opened.append($0) })
        center.begin()
        await center.settle()
        center.download()
        #expect(opened.isEmpty && center.isPresented && center.available == nil)
        #expect(center.message?.tone == .good)
        center.close()
        #expect(!center.isPresented && center.result != nil, "closing keeps the answer for Settings")
    }

    @Test func aFailedCheckCanBeTriedAgainAndEachTryIsOneRequest() async {
        let feed = FakeUpdateFeed(.failure(.offline), .success(UpdateFeedReply(status: 404)))
        let center = makeCenter(feed)
        await center.check()
        #expect(center.result == .couldNotCheck(.offline) && center.message?.tone == .attention)
        await center.check()
        #expect(center.result == .notPublishedYet && center.message?.headline == "Couldn't check yet")
        #expect(feed.requests.count == 2)
    }

    @Test func anUnexpectedFetchErrorReadsAsUnavailable() async {
        struct Unexpected: Error {}
        let center = UpdateCheckCenter(current: earlyBuild, fetch: { _ in throw Unexpected() }, openURL: { _ in }, now: { updateNow })
        await center.check()
        #expect(center.result == .couldNotCheck(.unavailable))
    }

    @Test func thePaletteEntryAppearsOnceTheAppInstallsTheCheck() async {
        let f = ActionFixture()
        #expect(f.registry.availability(.checkForUpdates, host: f.router) == .hidden)
        let feed = FakeUpdateFeed(.success(UpdateFeedReply(status: 404)))
        let center = makeCenter(feed)
        f.env.system.updates = center
        #expect(f.registry.availability(.checkForUpdates, host: f.router) == .enabled)
        #expect(await f.run(.checkForUpdates, source: .palette))
        #expect(center.isPresented)
        await center.settle()
        #expect(center.result == .notPublishedYet && feed.requests.count == 1)
    }

    @Test func anInstalledUpdaterOwnsTheCheckAndGitHubIsNeverAsked() async {
        let feed = FakeUpdateFeed(.success(feedReply(200, [releaseJSON("v0.2.0")])))
        let updater = FakeSoftwareUpdater()
        let center = UpdateCheckCenter(current: earlyBuild, fetch: feed.fetch, openURL: { _ in }, updater: updater,
                                       now: { updateNow })
        var shown = 0
        center.showWindow = { shown += 1 }
        center.begin()
        center.begin()
        await center.settle()
        #expect(updater.checks == 2 && shown == 0)
        #expect(!center.isPresented && center.phase == .idle && feed.requests.isEmpty)
    }

    @Test func thePaletteEntryHandsTheCheckToTheUpdater() async {
        let f = ActionFixture()
        let updater = FakeSoftwareUpdater()
        let feed = FakeUpdateFeed()
        f.env.system.updates = UpdateCheckCenter(current: earlyBuild, fetch: feed.fetch, openURL: { _ in }, updater: updater)
        #expect(f.registry.availability(.checkForUpdates, host: f.router) == .enabled)
        #expect(await f.run(.checkForUpdates, source: .palette))
        #expect(updater.checks == 1 && feed.requests.isEmpty)
    }

    @Test func theLastCheckIsSaidPlainly() {
        let updater = FakeSoftwareUpdater()
        let center = UpdateCheckCenter(current: earlyBuild, fetch: FakeUpdateFeed().fetch, openURL: { _ in }, updater: updater,
                                       now: { updateNow })
        #expect(center.lastCheckedLine == "Not checked yet.")
        updater.lastUpdateCheckDate = updateNow.addingTimeInterval(-2 * 3600)
        #expect(center.lastCheckedLine == "Last checked 2 hours ago.")
        updater.lastUpdateCheckDate = updateNow.addingTimeInterval(60)
        #expect(center.lastCheckedLine == "Last checked now.", "a clock that moved back never reads as the future")
        #expect(makeCenter(FakeUpdateFeed()).lastCheckedLine == nil, "the GitHub check has no schedule to report")
    }

    @Test func theUpdaterNoteSaysWhenAndWhatIsSent() {
        #expect(UpdateCheck.updaterPrivacyNote.contains("when you click"))
        #expect(UpdateCheck.updaterPrivacyNote.contains("once a day if you allow automatic checks"))
        #expect(UpdateCheck.updaterPrivacyNote.contains("nothing about you or your mail"))
        #expect(UpdateCheckCenter.automaticTitle == "Check for updates automatically")
    }

    @Test func theCatalogEntryFollowsTheRules() throws {
        let descriptor = try #require(ActionCatalog.descriptor(.checkForUpdates))
        #expect(descriptor.id.rawValue == "updates.check" && descriptor.title == "Check for updates…")
        #expect(descriptor.category == .app && descriptor.effect == .view && !descriptor.changesMail)
        #expect(descriptor.defaultBindings.isEmpty && descriptor.cliCommand == nil && descriptor.module == nil)
        #expect(descriptor.appearsInPalette && !descriptor.appearsInMenu, "the app menu has its own item")
        #expect(descriptor.paletteKeywords.contains("update") && descriptor.paletteKeywords.contains("new version"))
        #expect(PaletteController.symbol(for: .checkForUpdates) == "arrow.down.circle")
        #expect(UpdateCheckCenter.menuTitle == "Check for Updates…" && UpdateCheckCenter.settingsTitle == "Check for updates")
    }
}

@MainActor
final class FakeSoftwareUpdater: SoftwareUpdater {
    var automaticallyChecksForUpdates = false
    var lastUpdateCheckDate: Date?
    private(set) var checks = 0

    func checkForUpdates() {
        checks += 1
    }
}
