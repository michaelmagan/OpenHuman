import MailFeatures
import MailModel
import SwiftUI

/// The split inbox in the toolbar's centre as a native picker: the tabs role on macOS 27, a segmented control before
/// it. Up to `NativeMetrics.Toolbar.maxSplitSegments` splits are segments ("Name 12"); the rest are in a More
/// pull-down that takes the name of a split chosen from it.
public struct SplitInboxPicker: View {
    let router: AppRouter
    let state: AccountState
    let features: NativeFeatures?

    public init(router: AppRouter, state: AccountState, features: NativeFeatures? = nil) {
        self.router = router
        self.state = state
        self.features = features
    }

    public static func shows(_ state: AccountState) -> Bool {
        state.mode == .list && !state.searchOpen && state.isOnTab && state.tabs.count > 1
    }

    public enum Style: Equatable, Sendable {
        case tabs
        case segmented
    }

    public static func style(for features: NativeFeatures) -> Style {
        if features.splitPickerTabs, #available(macOS 27, iOS 27, *) { return .tabs }
        return .segmented
    }

    public struct Layout: Equatable, Sendable {
        public var segments: [MailTab]
        public var overflow: [MailTab]
        public var activeInOverflow: MailTab?

        public var overflowTitle: String { activeInOverflow?.title ?? SplitInboxPicker.moreTitle }
    }

    nonisolated public static let moreTitle = "More"

    // The order never changes with the selection, so picking a split in More does not move the segments
    nonisolated public static func layout(_ tabs: [MailTab], active: MailLocation? = nil,
                              maximum: Int = NativeMetrics.Toolbar.maxSplitSegments) -> Layout {
        let count = max(0, maximum)
        let overflow = Array(tabs.dropFirst(count))
        return Layout(segments: Array(tabs.prefix(count)), overflow: overflow,
                      activeInOverflow: active.flatMap { active in overflow.first { $0.location == active } })
    }

    nonisolated public static func segmentTitle(_ tab: MailTab, count: Int) -> String {
        guard let text = SplitTabBar.countText(count) else { return tab.title }
        return "\(tab.title) \(text)"
    }

    public var body: some View {
        let layout = Self.layout(state.tabs, active: state.location)
        HStack {
            if !layout.segments.isEmpty { picker(layout.segments) }
            if !layout.overflow.isEmpty { more(layout) }
        }
        .fixedSize()
        .contextMenu { hideWhenEmpty(state.tabs) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split inbox")
    }

    private var selection: Binding<MailLocation?> {
        Binding(
            get: { [state] in
                let segments = Self.layout(state.tabs).segments
                return state.location.flatMap { location in segments.contains { $0.location == location } ? location : nil }
            },
            set: { [router, state] location in
                if let location, location != state.location { router.go(to: location) }
            })
    }

    @ViewBuilder
    private func picker(_ tabs: [MailTab]) -> some View {
        let picker = Picker("Split inbox", selection: selection) {
            ForEach(tabs) { tab in
                Text(Self.segmentTitle(tab, count: state.tabCount(tab)))
                    .help(SplitTabBar.tooltip(tab))
                    .accessibilityLabel(tab.title)
                    .accessibilityValue(SplitTabBar.spokenCount(tab))
                    .tag(Optional(tab.location))
            }
        }
        .labelsHidden()
        let style = Self.style(for: features ?? NativeFeatures.current)
        if #available(macOS 27, iOS 27, *) {
            if style == .tabs { picker.pickerStyle(.tabs) } else { picker.pickerStyle(.segmented) }
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    private func more(_ layout: Layout) -> some View {
        Menu {
            ForEach(layout.overflow) { tab in
                Toggle(Self.segmentTitle(tab, count: state.tabCount(tab)), isOn: Binding(
                    get: { [state] in state.location == tab.location },
                    set: { [router] on in if on { router.go(to: tab.location) } }))
                    .help(SplitTabBar.tooltip(tab))
                    .accessibilityValue(SplitTabBar.spokenCount(tab))
            }
        } label: {
            Text(layout.overflowTitle)
        }
        .menuStyle(.button)
        .fixedSize()
        .help(layout.activeInOverflow.map(SplitTabBar.tooltip) ?? "More splits")
        .accessibilityLabel(layout.activeInOverflow.map { "More splits, \($0.title) selected" } ?? "More splits")
    }

    @ViewBuilder
    private func hideWhenEmpty(_ tabs: [MailTab]) -> some View {
        ForEach(tabs) { tab in
            if let hidden = state.hidesWhenEmpty(tab.location) {
                Toggle("Hide “\(tab.title)” when empty", isOn: Binding(get: { hidden }, set: { [state] on in
                    Task { await state.setHidesWhenEmpty(tab.location, on) }
                }))
            }
        }
    }
}
