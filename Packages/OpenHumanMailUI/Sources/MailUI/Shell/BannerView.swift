import MailFeatures
import MailTheme
import SwiftUI

/// A status banner (offline, sign-in needed) as a glass capsule that floats under the toolbar.
public struct BannerView: View {
    let banner: StatusBanner
    let action: (() -> Void)?

    public init(banner: StatusBanner, action: (() -> Void)? = nil) {
        self.banner = banner
        self.action = action
    }

    public var body: some View {
        HStack(spacing: NativeMetrics.HintLine.keyGap * 2) {
            Image(systemName: banner.symbol)
                .font(.system(size: NativeMetrics.Text.body, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Self.tint(banner.tone))
                .accessibilityHidden(true)
            Text(banner.message)
                .font(.system(size: NativeMetrics.Text.body))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(banner.detail.map { "Details: \($0)" } ?? "")
            if let title = banner.actionTitle, let action {
                Button(title, action: action)
                    .buttonStyle(.borderless)
                    .font(.system(size: NativeMetrics.Text.body, weight: .medium))
            }
        }
        .padding(.horizontal, NativeMetrics.Banner.paddingX)
        .frame(height: NativeMetrics.Banner.height)
        .nativeGlassCapsule()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear { AccessibilityNotification.Announcement(banner.message).post() }
    }

    static func tint(_ tone: StatusBanner.Tone) -> Color {
        switch tone {
        case .danger: .red
        case .warning: .orange
        case .neutral: .secondary
        }
    }
}

/// Everything that floats under the toolbar over the mail column: the status banner, the search coverage notice
/// and the cleanup or learned suggestion. None of them moves the list.
struct ShellFloatingBanners: View {
    let router: AppRouter

    var body: some View {
        let environment = router.environment
        VStack(spacing: NativeMetrics.Banner.topGap) {
            if let banner = router.banner() {
                BannerView(banner: banner, action: bannerAction(banner))
            }
            if router.showsSearchResultsHeader, let notice = environment.overlays.search.coverageNotice {
                ViewThatFits(in: .horizontal) {
                    coverage(notice).fixedSize()
                    coverage(notice)
                }
            }
            if let cleanup = environment.archiveSuggestion, let suggestion = cleanup.suggestion,
               router.active?.id == suggestion.account, router.mode == .list {
                ArchiveSuggestionBanner(model: cleanup, suggestion: suggestion)
            } else if router.mode == .list, let account = router.active?.id,
                      let learned = environment.learning.bannerSuggestion(account: account) {
                LearnedSuggestionBanner(center: environment.learning, suggestion: learned)
            }
        }
        .padding(.top, NativeMetrics.Banner.topGap)
        .padding(.horizontal, NativeMetrics.Banner.paddingX)
        .transaction { $0.disablesAnimations = true }
    }

    private func coverage(_ notice: SearchCoverageNotice) -> some View {
        SearchCoverageRow(notice: notice, search: router.environment.overlays.search)
            .padding(.top, NativeMetrics.HintLine.keyGap)
            .frame(minHeight: NativeMetrics.Banner.height)
            .nativeGlassCapsule()
    }

    private func bannerAction(_ banner: StatusBanner) -> (() -> Void)? {
        guard banner.kind == .auth, let account = banner.account, let accounts = router.environment.accounts else { return nil }
        return {
            Task {
                do { try await accounts.reauthorize(account) } catch {
                    router.environment.notices.post("Couldn't start sign-in", style: .error)
                }
            }
        }
    }
}
