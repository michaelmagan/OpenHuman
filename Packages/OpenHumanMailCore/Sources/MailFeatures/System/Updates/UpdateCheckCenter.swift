import Foundation
import Observation

@MainActor @Observable
public final class UpdateCheckCenter {
    public enum Phase: Sendable, Equatable {
        case idle
        case checking
        case finished(UpdateCheckResult)
    }

    public static let menuTitle = "Check for Updates…"
    public static let settingsTitle = "Check for updates"
    public static let automaticTitle = "Check for updates automatically"

    public private(set) var phase: Phase = .idle
    public var isPresented = false
    public let current: BuildLabel
    public let feed: UpdateFeed
    public let updater: (any SoftwareUpdater)?
    public let updatesUnavailable: UpdatesUnavailableReason?

    @ObservationIgnored public var showWindow: (@MainActor () -> Void)?
    @ObservationIgnored private let fetch: UpdateFeedFetch
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var running: Task<Void, Never>?

    public init(current: BuildLabel, feed: UpdateFeed = .openHuman, fetch: @escaping UpdateFeedFetch,
                openURL: @escaping @MainActor (URL) -> Void, updater: (any SoftwareUpdater)? = nil,
                updatesUnavailable: UpdatesUnavailableReason? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.current = current
        self.feed = feed
        self.updater = updater
        self.updatesUnavailable = updater == nil ? updatesUnavailable : nil
        self.fetch = fetch
        self.openURL = openURL
        self.now = now
    }

    public var isChecking: Bool { phase == .checking }

    public var result: UpdateCheckResult? {
        if case .finished(let result) = phase { return result }
        return nil
    }

    public var available: UpdateRelease? {
        if case .available(let release) = result { return release }
        return nil
    }

    public var message: UpdateCheckMessage? {
        switch phase {
        case .idle: nil
        case .checking: UpdateCheck.checking
        case .finished(let result): UpdateCheck.message(for: result, current: current, now: now())
        }
    }

    public var summary: String? {
        switch phase {
        case .idle: nil
        case .checking: "Checking…"
        case .finished(let result): UpdateCheck.summary(for: result, now: now())
        }
    }

    public var versionLine: String { "You have version \(current.version) (\(current.build))." }

    public var earlyDevelopmentLine: String? { UpdateCheck.earlyDevelopmentLine(for: result, current: current) }

    public var lastCheckedLine: String? {
        guard let updater else { return nil }
        return UpdateCheck.lastCheckedLine(updater.lastUpdateCheckDate, now: now())
    }

    // Why: with an updater installed it owns the check, the download and the install, so GitHub is never asked as well
    public func begin() {
        if let updater {
            updater.checkForUpdates()
            return
        }
        showWindow?()
        isPresented = true
        if !isChecking { start() }
    }

    // Why: a click while a check is running joins it, so a person never sends more than one request at a time
    @discardableResult
    public func start() -> Task<Void, Never> {
        if let updater {
            updater.checkForUpdates()
            return Task {}
        }
        if let running { return running }
        phase = .checking
        let fetch = fetch, current = current, feed = feed, now = now
        let url = feed.releasesURL
        let task = Task { @MainActor [weak self] in
            let outcome: Result<UpdateFeedReply, UpdateFeedFailure>
            do {
                outcome = .success(try await fetch(url))
            } catch let failure as UpdateFeedFailure {
                outcome = .failure(failure)
            } catch {
                outcome = .failure(.unreachable)
            }
            let result = UpdateCheck.evaluate(outcome, current: current, feed: feed, now: now())
            self?.finish(result)
        }
        running = task
        return task
    }

    public func check() async {
        await start().value
    }

    public func settle() async {
        await running?.value
    }

    public func download() {
        guard let release = available else { return }
        openURL(release.page)
        isPresented = false
    }

    public func close() {
        isPresented = false
    }

    private func finish(_ result: UpdateCheckResult) {
        phase = .finished(result)
        running = nil
    }
}
