import MailFeatures
import MailTheme
import SwiftUI

struct PaletteView: View {
    let palette: PaletteController
    @FocusState private var focused: Bool

    var body: some View {
        OverlayPanel(width: NativeMetrics.Overlay.paletteWidth, top: OverlayMetrics.paletteTop,
                     topRatio: OverlayMetrics.paletteTopRatio, dismiss: close) { _ in
            VStack(spacing: 0) {
                input
                Divider()
                results
                Divider()
                footer
            }
        }
        .task(id: palette.query) { await palette.loadMail() }
        .task { focused = true }
    }

    private func close() { palette.close() }

    private var input: some View {
        let scope = palette.scopeSummary
        return OverlayFieldRow(symbol: "command") {
            TextField("Command palette", text: Binding(get: { palette.query }, set: { palette.query = $0 }),
                      prompt: Text("Type a command or search…"))
                .overlayField()
                .focused($focused)
                .onSubmit { palette.performSelected() }
                .overlayKeys(up: { palette.moveCursor(by: -1) }, down: { palette.moveCursor(by: 1) }, escape: close)
                .accessibilityLabel(scope.map { "Command palette, acts on \($0)" } ?? "Command palette")
        } trailing: {
            if let scope { OverlayScopeChip(text: scope) }
        }
    }

    @ViewBuilder
    private var results: some View {
        let sections = PaletteSections(palette.entries)
        if palette.isEmptyResult {
            VStack(spacing: OverlayMetrics.rowSpacing) {
                Text("Nothing matches “\(palette.query)”")
                    .font(.system(size: NativeMetrics.Text.body))
                    .foregroundStyle(.secondary)
                    .padding(.top, OverlayMetrics.sectionHeaderHeight)
                if let first = sections.rows.first {
                    row(first, cursor: palette.cursor)
                }
            }
            .frame(height: Self.emptyResultHeight, alignment: .top)
        } else if sections.rows.isEmpty {
            Color.clear.frame(height: OverlayMetrics.listPaddingY)
        } else {
            let cursor = palette.cursor
            let height = Self.listHeight(sections)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sections.groups) { section in
                            OverlaySectionHeader(title: section.group.rawValue)
                            ForEach(section.rows) { item in
                                row(item, cursor: cursor)
                            }
                        }
                    }
                    .padding(.vertical, OverlayMetrics.listPaddingY)
                }
                .frame(minHeight: min(height, OverlayMetrics.paletteRowHeight * 2 + OverlayMetrics.sectionHeaderHeight),
                       maxHeight: height)
                .onChange(of: sections.id(at: cursor)) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    static let emptyResultHeight: CGFloat = 120

    static func listHeight(_ sections: PaletteSections) -> CGFloat {
        let content = CGFloat(sections.rows.count) * OverlayMetrics.paletteRowHeight
            + CGFloat(sections.groups.count) * OverlayMetrics.sectionHeaderHeight + OverlayMetrics.listPaddingY * 2
        return min(content, OverlayMetrics.paletteListMaxHeight)
    }

    @ViewBuilder
    private func row(_ item: PaletteSections.Row, cursor: Int) -> some View {
        if let reason = item.entry.unavailableReason {
            unavailableRow(item.entry, reason: reason)
        } else {
            availableRow(item.entry, index: item.index, isCursor: item.index == cursor)
        }
    }

    private func unavailableRow(_ entry: PaletteEntry, reason: String) -> some View {
        HStack(spacing: OverlayMetrics.rowSpacing) {
            OverlayRowSymbol(symbol: entry.symbol)
            OverlayMatchText(text: entry.title, matched: entry.matched)
            Text(reason)
                .font(.system(size: NativeMetrics.Text.secondary))
                .lineLimit(1)
            Spacer(minLength: OverlayMetrics.rowSpacing)
        }
        .foregroundStyle(.tertiary)
        .overlayRowLayout(isSelected: false, height: OverlayMetrics.paletteRowHeight)
        .padding(.horizontal, OverlayMetrics.plateInsetX)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.title), unavailable, \(reason)")
    }

    private func availableRow(_ entry: PaletteEntry, index: Int, isCursor: Bool) -> some View {
        OverlayRow(isSelected: isCursor, height: OverlayMetrics.paletteRowHeight) {
            palette.moveCursor(to: index)
            palette.perform(entry)
        } label: {
            HStack(spacing: OverlayMetrics.rowSpacing) {
                OverlayRowSymbol(symbol: entry.symbol, isDestructive: entry.isDestructive)
                OverlayMatchText(text: entry.title, matched: entry.matched)
                    .foregroundStyle(.primary)
                if let detail = entry.detail {
                    Text(detail)
                        .font(.system(size: NativeMetrics.Text.body))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: OverlayMetrics.rowSpacing)
                if !entry.keycaps.isEmpty { OverlayShortcutHint(entry.keycaps) }
            }
        }
        .accessibilityLabel(entry.title)
        .accessibilityValue(entry.keycaps.joined(separator: " then "))
    }

    private var footer: some View {
        OverlayFooter {
            OverlayFooterHint("↑↓", "Move")
            OverlayFooterHint("↵", palette.selectionCount > 1 ? "Run on \(palette.selectionCount) selected" : "Run")
            OverlayFooterHint("esc", "Close")
        }
        .accessibilityHidden(true)
    }
}

struct PaletteSections {
    struct Row: Identifiable {
        let index: Int
        let entry: PaletteEntry
        var id: String { entry.id }
    }

    struct Group: Identifiable {
        let group: PaletteGroup
        let id: String
        var rows: [Row]
    }

    let rows: [Row]
    let groups: [Group]

    init(_ entries: [PaletteEntry]) {
        let rows = entries.enumerated().map { Row(index: $0.offset, entry: $0.element) }
        var groups: [Group] = []
        var runs: [PaletteGroup: Int] = [:]
        for row in rows {
            if let last = groups.indices.last, groups[last].group == row.entry.group {
                groups[last].rows.append(row)
            } else {
                let run = runs[row.entry.group, default: 0]
                runs[row.entry.group] = run + 1
                groups.append(Group(group: row.entry.group, id: row.entry.group.rawValue + (run > 0 ? "#\(run)" : ""),
                                    rows: [row]))
            }
        }
        self.rows = rows
        self.groups = groups
    }

    func id(at index: Int) -> String? {
        rows.indices.contains(index) ? rows[index].id : nil
    }
}
