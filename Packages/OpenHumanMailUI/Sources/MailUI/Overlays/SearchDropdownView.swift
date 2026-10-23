import MailFeatures
import MailTheme
import SwiftUI

/// What the search field asks its host to float under it.
public struct SearchDropdownRequest {
    public let search: SearchModel
    public let isPresented: Bool
    /// The highlighted suggestion, by position in `search.suggestions`.
    public let cursor: Int
    /// A highlighted person shows their preview beside the list; otherwise the tips show there.
    public let showsPreview: Bool
    public let theme: ResolvedTheme
    public let accept: @MainActor (SearchSuggestion) -> Void
    /// The host reports whether the field has the keys. A field in a window's toolbar can have them while SwiftUI's
    /// focus state still says it does not.
    public let keysChanged: (@MainActor (Bool) -> Void)?

    public init(search: SearchModel, isPresented: Bool, cursor: Int, showsPreview: Bool, theme: ResolvedTheme,
                accept: @escaping @MainActor (SearchSuggestion) -> Void,
                keysChanged: (@MainActor (Bool) -> Void)? = nil) {
        self.search = search
        self.isPresented = isPresented
        self.cursor = cursor
        self.showsPreview = showsPreview
        self.theme = theme
        self.accept = accept
        self.keysChanged = keysChanged
    }
}

/// Floats the search suggestions outside the toolbar, which cannot draw over the window's content. The Mac window
/// installs a child panel; a field without a host shows no suggestions.
public struct FloatingSearchDropdown: @unchecked Sendable {
    public let anchor: @MainActor (SearchDropdownRequest) -> AnyView

    public init(anchor: @escaping @MainActor (SearchDropdownRequest) -> AnyView) {
        self.anchor = anchor
    }
}

extension EnvironmentValues {
    @Entry public var floatingSearchDropdown: FloatingSearchDropdown? = nil
}

struct SearchDropdownState: Equatable {
    private(set) var closed = false

    func shows(focused: Bool, hasContent: Bool) -> Bool { focused && !closed && hasContent }

    mutating func escape(showing: Bool) -> Bool {
        closed = true
        return showing
    }

    mutating func open() { closed = false }
}

/// Where the suggestions panel goes: under the field, inside the window, with the side column when it fits.
public struct SearchDropdownPlacement: Equatable, Sendable {
    /// In the coordinates of the field and window passed in, y up.
    public let frame: CGRect
    public let showsSide: Bool
    public let listWidth: CGFloat
    /// The list is taller than the panel.
    public let scrolls: Bool
}

public enum SearchDropdownLayout {
    public static var rowHeight: CGFloat { NativeMetrics.Search.panelRowHeight }
    public static var headerHeight: CGFloat { NativeMetrics.Search.panelHeaderHeight }

    public static func listHeight(rows: Int, headers: Int, extraRows: Int) -> CGFloat {
        CGFloat(rows + extraRows) * rowHeight + CGFloat(headers) * headerHeight + 2 * NativeMetrics.Search.panelPadding
    }

    /// The tips column; the contact preview fits in the same height, so the panel keeps its size as the cursor moves.
    public static var sideHeight: CGFloat {
        headerHeight + CGFloat(SearchTips.all.count) * NativeMetrics.Search.panelTipRowHeight
            + 2 * NativeMetrics.Search.panelPadding
    }

    /// `field` and `window` in screen coordinates (y up). The panel starts at the field's leading edge and moves left
    /// only as far as the window needs; its top sits a small gap under the field, and it never reaches past the
    /// window's bottom margin. A window too narrow for both columns drops the side column.
    public static func place(field: CGRect, window: CGRect, listHeight: CGFloat,
                             sideHeight: CGFloat = SearchDropdownLayout.sideHeight) -> SearchDropdownPlacement {
        let metrics = NativeMetrics.Search.self
        let margin = metrics.panelWindowMargin
        let room = max(0, window.width - 2 * margin)
        let wantedList = max(field.width, metrics.panelListWidth)
        let showsSide = room >= wantedList + metrics.panelSideWidth
        let listWidth = showsSide ? wantedList : min(wantedList, room)
        let width = listWidth + (showsSide ? metrics.panelSideWidth : 0)
        let x = max(window.minX + margin, min(field.minX, window.maxX - margin - width))
        let top = field.minY - metrics.panelGap
        let content = max(listHeight, showsSide ? sideHeight : 0)
        let height = min(content, max(rowHeight, top - (window.minY + margin)))
        return SearchDropdownPlacement(frame: CGRect(x: x.rounded(), y: (top - height).rounded(), width: width, height: height),
                                       showsSide: showsSide, listWidth: listWidth, scrolls: listHeight > height)
    }
}

/// The search operators with an example each, beside the suggestions while no person is highlighted.
public enum SearchTips {
    public struct Tip: Hashable, Sendable {
        public let example: String
        public let meaning: String
    }

    public static let all: [Tip] = [
        Tip(example: "from:dana", meaning: "From Dana"),
        Tip(example: "to:sam", meaning: "To Sam"),
        Tip(example: "\"budget review\"", meaning: "These exact words"),
        Tip(example: "subject:lunch", meaning: "Subject contains “lunch”"),
        Tip(example: "has:attachment", meaning: "With attachments"),
        Tip(example: "is:unread", meaning: "Unread conversations"),
        Tip(example: "is:starred", meaning: "Starred conversations"),
        Tip(example: "in:sent", meaning: "In Sent"),
        Tip(example: "-in:inbox", meaning: "Not in the Inbox"),
        Tip(example: "label:receipts", meaning: "With this label"),
        Tip(example: "after:2026/01/31", meaning: "On or after a date"),
        Tip(example: "before:2026/10/01", meaning: "Before a date"),
    ]
}

/// The suggestions under the search field: an Ask AI row, the interpretation, then people, recent searches,
/// labels and operators under section headers; beside them the tips or the highlighted person.
public struct SearchDropdownView: View {
    let request: SearchDropdownRequest
    let placement: SearchDropdownPlacement

    public init(request: SearchDropdownRequest, placement: SearchDropdownPlacement) {
        self.request = request
        self.placement = placement
    }

    nonisolated public static func headerCount(_ suggestions: [SearchSuggestion]) -> Int {
        suggestions.indices.filter { $0 == 0 || suggestions[$0 - 1].group != suggestions[$0].group }.count
    }

    /// The rows above the suggestions: Ask AI and the interpretation.
    public static func extraRows(_ search: SearchModel) -> Int {
        (search.canAskAI ? 1 : 0) + (search.interpretation.state == .hidden ? 0 : 1)
    }

    nonisolated public static func title(_ group: SearchSuggestion.Group) -> String {
        switch group {
        case .saved: String(localized: "Saved searches")
        case .recent: String(localized: "Recent searches")
        case .people: String(localized: "People")
        case .labels: String(localized: "Labels")
        case .operators: String(localized: "Operators")
        }
    }

    public var body: some View {
        let search = request.search
        let suggestions = search.suggestions
        HStack(spacing: 0) {
            SearchSuggestionList(search: search, suggestions: suggestions, cursor: request.cursor,
                                 showsLastMail: !placement.showsSide, scrolls: placement.scrolls, accept: request.accept)
                .frame(width: placement.listWidth)
            if placement.showsSide {
                Divider()
                Group {
                    if request.showsPreview, let contact = search.contactPreview.contact {
                        SearchContactPreviewView(contact: contact)
                    } else {
                        SearchTipsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: placement.frame.width, height: placement.frame.height, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search suggestions")
        .accessibilityIdentifier("search.suggestions")
    }
}

struct SearchSuggestionList: View {
    let search: SearchModel
    let suggestions: [SearchSuggestion]
    let cursor: Int
    let showsLastMail: Bool
    let scrolls: Bool
    let accept: @MainActor (SearchSuggestion) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                rows
                    .padding(.vertical, NativeMetrics.Search.panelPadding)
            }
            .scrollDisabled(!scrolls)
            .scrollIndicators(scrolls ? .automatic : .hidden)
            .onChange(of: cursor) { _, cursor in
                guard scrolls, suggestions.indices.contains(cursor) else { return }
                proxy.scrollTo(suggestions[cursor].id)
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            if search.canAskAI {
                SearchAskAIRow(question: search.text.trimmingCharacters(in: .whitespacesAndNewlines)) { _ = search.askAI() }
            }
            switch search.interpretation.state {
            case .hidden:
                EmptyView()
            case .waiting:
                InterpretationWaitingRow()
            case .ready(let plan):
                InterpretationRow(plan: plan) { _ = search.acceptInterpretation() }
            }
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                if index == 0 || suggestions[index - 1].group != suggestion.group {
                    SearchSectionHeader(title: SearchDropdownView.title(suggestion.group))
                }
                let isCursor = index == cursor
                SearchSuggestionRow(suggestion: suggestion, isSelected: isCursor,
                                    lastMail: isCursor && showsLastMail ? search.personDetail(suggestion) : nil) {
                    accept(suggestion)
                }
                .id(suggestion.id)
                .accessibilityIdentifier("search.suggestion.\(index)")
            }
        }
    }
}

struct SearchSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: NativeMetrics.Text.caption, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, NativeMetrics.Search.panelPlateInsetX + 8)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, minHeight: SearchDropdownLayout.headerHeight,
                   maxHeight: SearchDropdownLayout.headerHeight, alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The highlighted row: the system selection, in the accent colour with white text, as in a list with the keys.
/// The keys stay in the search field.
struct SearchSelectionPlate: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: NativeMetrics.Search.panelPlateRadius, style: .continuous)
            .fill(isSelected ? AnyShapeStyle(TintShapeStyle.tint) : AnyShapeStyle(Color.clear))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct SearchSuggestionRow: View {
    let suggestion: SearchSuggestion
    let isSelected: Bool
    let lastMail: String?
    let accept: @MainActor () -> Void

    var body: some View {
        Button(action: accept) {
            HStack(spacing: 8) {
                Image(systemName: Self.symbol(suggestion.kind))
                    .font(.system(size: NativeMetrics.Text.body))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(suggestion.title)
                    .font(.system(size: NativeMetrics.Text.body))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                    .lineLimit(1)
                if let detail = suggestion.detail {
                    Text(detail)
                        .font(.system(size: NativeMetrics.Text.secondary))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if let lastMail {
                    Text(lastMail)
                        .font(.system(size: NativeMetrics.Text.caption))
                        .monospacedDigit()
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: SearchDropdownLayout.rowHeight, maxHeight: SearchDropdownLayout.rowHeight,
                   alignment: .leading)
            .background(SearchSelectionPlate(isSelected: isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, NativeMetrics.Search.panelPlateInsetX)
        .accessibilityLabel(suggestion.title)
        .accessibilityValue([suggestion.detail, lastMail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var secondary: AnyShapeStyle {
        isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(HierarchicalShapeStyle.secondary)
    }

    static func symbol(_ kind: SearchSuggestion.Kind) -> String {
        switch kind {
        case .recent: "clock.arrow.circlepath"
        case .saved: "bookmark"
        case .person: "person.crop.circle"
        case .label: "tag"
        case .operator: "line.3.horizontal.decrease.circle"
        }
    }
}

/// Asks AI about the typed text (⌘J). Not part of the arrow keys' rows: Return still searches.
struct SearchAskAIRow: View {
    let question: String
    let ask: @MainActor () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: ask) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: NativeMetrics.Text.body))
                    .foregroundStyle(theme.textAI.color)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text("Ask AI")
                    .font(.system(size: NativeMetrics.Text.body, weight: .medium))
                    .foregroundStyle(theme.textAI.color)
                    .fixedSize()
                Text(question)
                    .font(.system(size: NativeMetrics.Text.body))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text("⌘J")
                    .font(.system(size: NativeMetrics.Text.secondary))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: SearchDropdownLayout.rowHeight, maxHeight: SearchDropdownLayout.rowHeight,
                   alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, NativeMetrics.Search.panelPlateInsetX)
        .accessibilityLabel("Ask AI about \(question)")
        .accessibilityHint("Command-J")
        .accessibilityIdentifier("search.askAI")
    }
}

/// The operators, one example a line. The examples keep their full width; a meaning that does not fit beside its
/// example wraps to a second line. A tip that no longer fits whole under the ones above it is left out, so the column
/// never ends in a cut-off line and needs no scroll bar.
struct SearchTipsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SideHeader(title: String(localized: "Search tips"))
            SearchTipsLayout(minRowHeight: NativeMetrics.Search.panelTipRowHeight) {
                ForEach(SearchTips.all, id: \.self) { tip in
                    Self.example(tip)
                    Self.meaning(tip)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .padding(.horizontal, Self.insetX)
        .padding(.vertical, NativeMetrics.Search.panelPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search tips")
        .accessibilityIdentifier("search.tips")
    }

    static let insetX: CGFloat = 14

    static func example(_ tip: SearchTips.Tip) -> some View {
        Text(tip.example)
            .font(.system(size: NativeMetrics.Text.secondary, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel(Text(verbatim: "\(tip.example), \(tip.meaning)"))
    }

    static func meaning(_ tip: SearchTips.Tip) -> some View {
        Text(tip.meaning)
            .font(.system(size: NativeMetrics.Text.secondary))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .accessibilityHidden(true)
    }
}

// The tips' cells in pairs, example then meaning: the examples in one column as wide as the widest, each meaning
// beside its example at the width left. The height is the one the panel gives the column; every row height comes from
// the cells at the column's width within one layout pass. Nothing is measured, stored and given back to a later pass.
// A row that does not fit whole, and every row after it, is placed outside the column, which clips.
struct SearchTipsLayout: Layout {
    static let columnSpacing: CGFloat = 10

    var minRowHeight: CGFloat

    struct Row: Equatable {
        let example: CGRect
        let meaning: CGRect
        let shown: Bool
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let examples = Self.examples(subviews)
        let exampleWidth = examples.map(\.width).max() ?? 0
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? exampleWidth + Self.columnSpacing + (Self.meanings(subviews, width: nil).map(\.width).max() ?? 0)
        if let height = proposal.height, height.isFinite { return CGSize(width: width, height: height) }
        let natural = layoutRows(subviews, width: width, height: .infinity)
        return CGSize(width: width, height: natural.map { max($0.example.maxY, $0.meaning.maxY) }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, row) in layoutRows(subviews, width: bounds.width, height: bounds.height).enumerated() {
            // Below the column, out of sight once it clips
            let offset = row.shown ? CGPoint(x: bounds.minX, y: bounds.minY) : CGPoint(x: bounds.minX, y: bounds.maxY + 1000)
            for (subview, frame) in [(subviews[2 * index], row.example), (subviews[2 * index + 1], row.meaning)] {
                subview.place(at: CGPoint(x: offset.x + frame.minX, y: offset.y + frame.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(frame.size))
            }
        }
    }

    private func layoutRows(_ subviews: Subviews, width: CGFloat, height: CGFloat) -> [Row] {
        let examples = Self.examples(subviews)
        let exampleWidth = min(examples.map(\.width).max() ?? 0, width)
        let meaningWidth = max(width - exampleWidth - Self.columnSpacing, 0)
        return Self.rows(examples: examples, meanings: Self.meanings(subviews, width: meaningWidth),
                         exampleWidth: exampleWidth, meaningWidth: meaningWidth, height: height, minRowHeight: minRowHeight)
    }

    private static func examples(_ subviews: Subviews) -> [CGSize] {
        stride(from: 0, to: subviews.count - 1, by: 2).map { subviews[$0].sizeThatFits(.unspecified) }
    }

    private static func meanings(_ subviews: Subviews, width: CGFloat?) -> [CGSize] {
        stride(from: 1, to: subviews.count, by: 2).map { subviews[$0].sizeThatFits(ProposedViewSize(width: width, height: nil)) }
    }

    /// The rows top to bottom from the cells' sizes, in the column's coordinates. A single line sits in the middle of
    /// `minRowHeight`; a meaning on two lines makes its row taller. Rows from the first that ends below `height` on
    /// are not shown.
    static func rows(examples: [CGSize], meanings: [CGSize], exampleWidth: CGFloat, meaningWidth: CGFloat,
                     height: CGFloat, minRowHeight: CGFloat) -> [Row] {
        var y: CGFloat = 0
        var fits = true
        return zip(examples, meanings).map { example, meaning in
            let inset = max((minRowHeight - example.height) / 2, 0)
            let rowHeight = max(minRowHeight, inset + max(example.height, meaning.height) + inset)
            fits = fits && y + rowHeight <= height + 0.5
            let row = Row(example: CGRect(x: 0, y: y + inset, width: min(example.width, exampleWidth), height: example.height),
                          meaning: CGRect(x: exampleWidth + columnSpacing, y: y + inset, width: meaningWidth,
                                          height: meaning.height),
                          shown: fits)
            y += rowHeight
            return row
        }
    }
}

/// The highlighted person: name, address, their newest conversations and their domain.
struct SearchContactPreviewView: View {
    let contact: SearchContactPreview.Contact

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                Text(contact.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .padding(.top, 10)
                    .accessibilityAddTraits(.isHeader)
                if contact.name != nil {
                    Text(contact.email)
                        .font(.system(size: NativeMetrics.Text.secondary))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, 2)
                }
                conversations
                if let domain = contact.domain {
                    Label(domain, systemImage: "globe")
                        .font(.system(size: NativeMetrics.Text.secondary))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 10)
                        .accessibilityLabel("Domain \(domain)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, NativeMetrics.Search.panelPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(contact.title)
        .accessibilityIdentifier("search.contactPreview")
    }

    @ViewBuilder
    private var conversations: some View {
        switch contact.conversations {
        case nil:
            SideHeader(title: String(localized: "Recent mail"))
            ProgressView()
                .controlSize(.small)
                .frame(height: NativeMetrics.Search.panelTipRowHeight)
        case let found? where !found.isEmpty:
            SideHeader(title: String(localized: "Recent mail"))
            ForEach(Array(found.enumerated()), id: \.offset) { _, conversation in
                HStack(spacing: 8) {
                    Text(conversation.subject)
                        .font(.system(size: NativeMetrics.Text.secondary))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(conversation.date, format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: NativeMetrics.Text.caption))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .frame(height: NativeMetrics.Search.panelTipRowHeight)
                .accessibilityElement(children: .combine)
            }
        default:
            EmptyView()
        }
    }
}

private struct SideHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: NativeMetrics.Text.caption, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, minHeight: SearchDropdownLayout.headerHeight,
                   maxHeight: SearchDropdownLayout.headerHeight, alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// The suggestions panel's surface, the same as the other overlay panels': Liquid Glass, or the system material
    /// with a hairline and a shadow when Reduce Transparency is on or a capture cannot draw glass.
    @MainActor
    public func searchPanelSurface(material: Bool) -> some View {
        overlaySurface(material ? .material : .glass)
    }
}
