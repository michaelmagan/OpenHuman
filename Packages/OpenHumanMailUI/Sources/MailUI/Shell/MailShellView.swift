#if os(macOS)
import MailFeatures
import MailModel
import AppKit
import MailTheme
import SwiftUI

/// The main window: the sidebar column, the mail column under the unified toolbar, and an optional inspector
/// (calendar or contact) at the trailing edge. Banners and toasts float over the mail column; only the hint line
/// at its foot takes space.
public struct MailShellView<Content: View, Inspector: View>: View {
    let router: AppRouter
    let content: Content
    let inspector: Inspector
    let inspectorShown: Binding<Bool>
    let inspectorWidth: CGFloat?
    @State private var hints: HintBarModel

    public init(router: AppRouter, inspectorShown: Binding<Bool>, inspectorWidth: CGFloat? = nil,
                @ViewBuilder content: () -> Content, @ViewBuilder inspector: () -> Inspector) {
        self.router = router
        self.content = content()
        self.inspector = inspector()
        self.inspectorShown = inspectorShown
        self.inspectorWidth = inspectorWidth
        _hints = State(initialValue: HintBarModel(router: router))
    }

    public var body: some View {
        let environment = router.environment
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            MailSidebar(router: router)
        } detail: {
            // The toolbar belongs to the mail column, inside the inspector modifier, so its items stay over the mail
            // column instead of moving over an open calendar or contact panel
            ShellDetailColumn(router: router, hints: hints) { content }
                .toolbar { ShellToolbar(router: router) }
                .navigationTitle(ShellTitles.title(router))
                .navigationSubtitle(ShellTitles.subtitle(router))
                .inspector(isPresented: inspectorShown) {
                    inspector
                        .inspectorColumnWidth(min: inspectorWidth, ideal: inspectorWidth ?? NativeMetrics.Sidebar.idealWidth,
                                              max: inspectorWidth)
                }
        }
        .navigationSplitViewStyle(.balanced)
        .shortcutTipRoot()
        .environment(\.actionDescriptors, environment.actions.descriptors)
        .task { hints.start() }
        .overlay { OverlayHostView(center: environment.overlays) }
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { Self.visibility(sidebarShown: router.isLabelSidebarVisible) },
                set: { visibility in
                    let shown = Self.sidebarShown(visibility)
                    if router.isLabelSidebarVisible != shown { router.isLabelSidebarVisible = shown }
                })
    }

    static func visibility(sidebarShown: Bool) -> NavigationSplitViewVisibility {
        sidebarShown ? .all : .detailOnly
    }

    static func sidebarShown(_ visibility: NavigationSplitViewVisibility) -> Bool {
        visibility != .detailOnly
    }
}

extension MailShellView where Inspector == EmptyView {
    public init(router: AppRouter, @ViewBuilder content: () -> Content) {
        self.init(router: router, inspectorShown: .constant(false), content: content, inspector: { EmptyView() })
    }
}

/// The mail column: the search header, the list or reader, and the hint line. Banners, the select-before hint,
/// toasts and the key-sequence hint float over it.
struct ShellDetailColumn<Content: View>: View {
    let router: AppRouter
    let hints: HintBarModel?
    let content: Content
    @Environment(\.theme) private var theme

    init(router: AppRouter, hints: HintBarModel?, @ViewBuilder content: () -> Content) {
        self.router = router
        self.hints = hints
        self.content = content()
    }

    /// All Inboxes while it is the shown place: the Calendar, drawn over the mail column, wins.
    @MainActor
    static func shownAllInboxes(_ router: AppRouter) -> AllInboxesModel? {
        router.environment.calendarWindowIfStarted?.isOpen == true ? nil : router.unifiedInbox
    }

    var body: some View {
        let environment = router.environment
        VStack(spacing: 0) {
            if router.showsSearchResultsHeader, let summary = environment.overlays.search.resultsSummary {
                HStack(spacing: 0) {
                    SearchResultsHeader(text: summary, search: environment.overlays.search)
                    if let query = environment.overlays.search.shownQuery,
                       router.list?.searchStatus?.canSortByRelevance == true {
                        SearchSortSwitch(query: query, model: environment.searchRanking)
                            .padding(.trailing, theme.space5)
                    }
                }
                .transaction { $0.disablesAnimations = true }
            }
            ZStack {
                content
                if let unified = Self.shownAllInboxes(router) {
                    UnifiedInboxView(model: unified) { router.leaveAllInboxes() }
                        .id(ObjectIdentifier(unified))
                }
            }
            .transaction { $0.disablesAnimations = true }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { ShellFloatingBanners(router: router) }
            .overlay(alignment: .bottom) {
                VStack(spacing: theme.space3) {
                    if let hint = CheckBeforeHint.shows(router: router) { hint }
                    ToastHostView(notices: environment.notices)
                }
                .padding(.bottom, theme.component.toast.bottom)
            }
            .overlay(alignment: .bottomLeading) {
                if let hint = router.sequenceHint {
                    SequenceHintView(text: hint)
                        .padding(theme.space5)
                }
            }
            if FooterView.isVisible(status: environment.status, hints: hints) {
                FooterView(status: environment.status, hints: hints, theme: theme.tokens)
                    .transaction { $0.disablesAnimations = true }
            }
        }
        .background(theme.bgWindow.color)
    }
}

struct SequenceHintView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: NativeMetrics.Keycap.textSize, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, NativeMetrics.Banner.paddingX)
            .frame(height: NativeMetrics.Banner.height)
            .nativeGlassCapsule()
            .accessibilityLabel("Waiting for the second key of \(text.dropLast())")
    }
}
#endif
