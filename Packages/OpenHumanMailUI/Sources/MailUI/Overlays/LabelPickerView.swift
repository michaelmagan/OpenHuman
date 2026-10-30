import MailFeatures
import MailModel
import MailTheme
import SwiftUI

struct LabelPickerView: View {
    let model: LabelPickerModel
    let dismiss: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        OverlayPanel(width: OverlayMetrics.labelPickerWidth, dismiss: dismiss) { _ in
            VStack(spacing: 0) {
                OverlayFieldRow(symbol: model.mode == .move ? "folder" : "tag") {
                    TextField(model.title, text: Binding(get: { model.query }, set: { model.query = $0 }),
                              prompt: Text(model.placeholder))
                        .overlayField()
                        .focused($focused)
                        .onSubmit { model.confirm() }
                        .overlayKeys(up: { model.moveCursor(by: -1) }, down: { model.moveCursor(by: 1) }, escape: dismiss)
                        .onKeyPress(.space) {
                            guard model.query.isEmpty, model.mode == .label else { return .ignored }
                            model.toggleCursor()
                            return .handled
                        }
                        .accessibilityLabel(model.title)
                }
                Divider()
                if model.rows.isEmpty {
                    Text("No labels")
                        .font(.system(size: NativeMetrics.Text.body))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: Self.emptyHeight)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                                if let header = model.header(before: index) {
                                    OverlaySectionHeader(title: header)
                                }
                                if row.isEnabled {
                                    rowView(row, isCursor: index == model.cursor)
                                } else {
                                    disabledRowView(row)
                                }
                            }
                        }
                        .padding(.vertical, OverlayMetrics.listPaddingY)
                    }
                    .frame(minHeight: min(listHeight, OverlayMetrics.rowHeight * 2), maxHeight: listHeight)
                }
            }
        }
        .task { focused = true }
    }

    static let emptyHeight: CGFloat = 64

    private var listHeight: CGFloat {
        min(CGFloat(model.rows.count) * OverlayMetrics.rowHeight
            + CGFloat(Self.headerCount(model)) * OverlayMetrics.sectionHeaderHeight + OverlayMetrics.listPaddingY * 2,
            OverlayMetrics.paletteListMaxHeight)
    }

    static func headerCount(_ model: LabelPickerModel) -> Int {
        model.rows.indices.filter { model.header(before: $0) != nil }.count
    }

    private func disabledRowView(_ row: LabelPickerModel.Row) -> some View {
        HStack(spacing: OverlayMetrics.rowSpacing) {
            leading(row)
            OverlayMatchText(text: row.title, matched: row.matched)
                .layoutPriority(1)
            if let tag = row.tag { tagView(tag) }
            if let reason = row.disabledReason {
                Text(reason)
                    .font(.system(size: NativeMetrics.Text.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.tertiary)
        .overlayRowLayout(isSelected: false, height: OverlayMetrics.rowHeight)
        .padding(.horizontal, OverlayMetrics.plateInsetX)
        .help(row.disabledReason ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), unavailable, \(row.disabledReason ?? "")")
    }

    @ViewBuilder
    private func leading(_ row: LabelPickerModel.Row) -> some View {
        switch row.kind {
        case .create:
            OverlayRowSymbol(symbol: "plus")
        case .label(let label):
            if let check = row.check { checkbox(check) }
            Image(systemName: "circle.fill")
                .font(.system(size: OverlayMetrics.labelDotSize))
                .foregroundStyle(color(of: label))
                .frame(width: row.check == nil ? OverlayMetrics.symbolColumn : nil)
                .accessibilityHidden(true)
        case .place(let place):
            OverlayRowSymbol(symbol: Self.symbol(of: place))
        case .split:
            OverlayRowSymbol(symbol: "rectangle.split.3x1")
        case .addSender:
            OverlayRowSymbol(symbol: "person.crop.circle.badge.plus")
        }
    }

    static func symbol(of place: MovePlace) -> String {
        switch place {
        case .inbox: "tray.and.arrow.down"
        case .important: "exclamationmark.circle"
        case .other: "tray"
        }
    }

    private func tagView(_ tag: String) -> some View {
        Text(tag)
            .font(.system(size: NativeMetrics.Text.caption, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private func rowView(_ row: LabelPickerModel.Row, isCursor: Bool) -> some View {
        OverlayRow(isSelected: isCursor) { model.choose(row) } label: {
            HStack(spacing: OverlayMetrics.rowSpacing) {
                leading(row)
                HStack(spacing: 0) {
                    if let path = row.parentPath {
                        Text(path)
                            .font(.system(size: NativeMetrics.Text.body))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    OverlayMatchText(text: row.title, matched: row.matched)
                        .foregroundStyle(.primary)
                }
                if let tag = row.tag { tagView(tag) }
                Spacer(minLength: 0)
            }
        }
        .accessibilityLabel(row.title)
        .accessibilityValue(accessibilityValue(row.check))
    }

    private func accessibilityValue(_ check: LabelPickerModel.CheckState?) -> String {
        switch check {
        case .on?: "applied"
        case .mixed?: "applied to some"
        default: ""
        }
    }

    /// The check state as the system checkbox's symbols: ticked, mixed (some of the selection) or empty.
    static func checkSymbol(_ state: LabelPickerModel.CheckState) -> String {
        switch state {
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        case .off: "square"
        }
    }

    private func checkbox(_ state: LabelPickerModel.CheckState) -> some View {
        Image(systemName: Self.checkSymbol(state))
            .font(.system(size: OverlayMetrics.rowSymbolSize))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(state == .off ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(TintShapeStyle.tint))
            .frame(width: OverlayMetrics.symbolColumn, height: OverlayMetrics.symbolColumn)
            .accessibilityHidden(true)
    }

    private func color(of label: LabelInfo) -> Color {
        guard let hex = label.colorBackground, hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else {
            return Color.secondary
        }
        return Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255, opacity: 1)
    }
}
