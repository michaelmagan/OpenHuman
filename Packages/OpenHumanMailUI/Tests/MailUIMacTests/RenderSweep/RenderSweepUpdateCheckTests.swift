import AppKit
import MailFeatures
import MailTheme
import SwiftUI
import Testing
@testable import MailUI
@testable import MailUIMac

private let sweepUpdateNow = Date(timeIntervalSince1970: 1_791_000_000)
private let sweepEarlyBuild = BuildLabel(version: "0.1.0", build: "1001", channel: "early-development")
private let sweepNewerRelease = Data(#"""
[{"tag_name":"v0.2.0","draft":false,"prerelease":true,
  "body":"Early development build — expect rough edges. Please send feedback.\n\n## Changes\n- Faster search on large mailboxes\n- Fixed sync after waking from sleep",
  "html_url":"https://github.com/michaelmagan/OpenHuman/releases/tag/v0.2.0"}]
"""#.utf8)

@MainActor
private func sweepCenter(_ reply: UpdateFeedReply?) async -> UpdateCheckCenter {
    let center = UpdateCheckCenter(current: sweepEarlyBuild, fetch: { _ in
        guard let reply else { throw UpdateFeedFailure.offline }
        return reply
    }, openURL: { _ in }, now: { sweepUpdateNow })
    await center.check()
    return center
}

@MainActor
private final class SweepUpdater: SoftwareUpdater {
    var automaticallyChecksForUpdates = true
    var lastUpdateCheckDate: Date? = sweepUpdateNow.addingTimeInterval(-3 * 3600)
    func checkForUpdates() {}
}

extension RenderSweepTests {
    @Test(arguments: SweepTheme.lightAndDark)
    func updateCheckSheetAndSettingsRow(_ theme: SweepTheme) async throws {
        let store = theme.makeStore()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let checking = UpdateCheckCenter(current: sweepEarlyBuild, fetch: { _ in
            for await _ in gate {}
            throw UpdateFeedFailure.offline
        }, openURL: { _ in }, now: { sweepUpdateNow })
        checking.start()
        let states: [(String, UpdateCheckCenter)] = [
            ("checking", checking),
            ("available", await sweepCenter(UpdateFeedReply(status: 200, body: sweepNewerRelease))),
            ("up-to-date", await sweepCenter(UpdateFeedReply(status: 200, body: Data(#"[{"tag_name":"v0.1.0"}]"#.utf8)))),
            ("not-published", await sweepCenter(UpdateFeedReply(status: 404))),
            ("offline", await sweepCenter(nil)),
            ("rate-limited", await sweepCenter(UpdateFeedReply(status: 429, headers: ["retry-after": "720"]))),
        ]
        for (name, center) in states {
            let sheet = sweepStandaloneWindow(UpdateCheckSheet(center: center), store: store,
                                              size: NSSize(width: UpdateCheckSheet.width, height: 400))
            defer { sheet.orderOut(nil) }
            try await sweepShoot(sheet, screen: "update-sheet-\(name)", theme: theme)
        }
        for (name, center) in states where ["checking", "available", "not-published", "offline"].contains(name) {
            let row = sweepStandaloneWindow(SettingsPageScaffold(title: "General") { UpdateCheckSettingsSection(center: center) },
                                            store: store, size: NSSize(width: Self.settingsPageWidth, height: 300))
            defer { row.orderOut(nil) }
            try await sweepShoot(row, screen: "settings-updates-\(name)", theme: theme)
        }
        let updating = UpdateCheckCenter(current: sweepEarlyBuild, fetch: { _ in UpdateFeedReply(status: 404) },
                                         openURL: { _ in }, updater: SweepUpdater(), now: { sweepUpdateNow })
        let unsigned = UpdateCheckCenter(current: sweepEarlyBuild, fetch: { _ in UpdateFeedReply(status: 404) },
                                         openURL: { _ in }, updatesUnavailable: .notDeveloperIDSigned, now: { sweepUpdateNow })
        for (name, center) in [("updater", updating), ("not-available", unsigned)] {
            let row = sweepStandaloneWindow(SettingsPageScaffold(title: "General") { UpdateCheckSettingsSection(center: center) },
                                            store: store, size: NSSize(width: Self.settingsPageWidth, height: 300))
            defer { row.orderOut(nil) }
            try await sweepShoot(row, screen: "settings-updates-\(name)", theme: theme)
        }
        open.finish()
        await checking.settle()
    }
}
