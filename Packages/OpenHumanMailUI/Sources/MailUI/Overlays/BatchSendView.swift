import MailFeatures
import SwiftUI

/// The confirmation for sending checked drafts: the count and recipients, each draft that goes, the drafts that stay
/// and why, and the "remind me if no reply" switch for this batch. ↵ sends, R flips the switch, Esc cancels.
struct BatchSendView: View {
    static let width: CGFloat = 480
    static let lineHeight: CGFloat = 40
    static let sectionHeight: CGFloat = OverlayMetrics.sectionHeaderHeight
    /// The panel's own rows around the list: header, switch, buttons and footer.
    static let chromeHeight: CGFloat = 250
    static let minListHeight: CGFloat = 2 * lineHeight

    let model: BatchSendModel
    let dismiss: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        OverlayPanel(width: Self.width, label: "Send drafts", dismiss: dismiss) { size in
            VStack(spacing: 0) {
                header
                Divider()
                list(maxHeight: Self.listLimit(available: size.height))
                Divider()
                reminderRow
                Divider()
                confirmRow
                Divider()
                OverlayFooter {
                    footerKey("↵", model.canConfirm ? "Send" : "Close")
                    footerKey("R", "Reminders")
                    footerKey("esc", "Cancel")
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.escape) { dismiss(); return .handled }
            .onKeyPress(.return, phases: .down) { _ in
                if model.canConfirm { model.confirm() } else { dismiss() }
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "rR"), phases: .down) { _ in
                model.toggleReminders()
                return .handled
            }
            .accessibilityIdentifier("batchSend.panel")
        }
        .onAppear {
            focused = true
            let spoken: String = model.title + " " + model.summary
            AccessibilityNotification.Announcement(spoken).post()
        }
    }

    static func listLimit(available height: CGFloat) -> CGFloat {
        max(minListHeight, height - OverlayMetrics.pickerTop - chromeHeight)
    }

    static func listHeight(lines: Int, skipped: Int) -> CGFloat {
        CGFloat(lines + skipped) * lineHeight + (skipped > 0 ? sectionHeight : 0) + 2 * OverlayMetrics.listPaddingY
    }

    private var header: some View {
        HStack(alignment: .center, spacing: OverlayMetrics.fieldSpacing) {
            Image(systemName: "paperplane")
                .font(.system(size: NativeMetrics.Overlay.paletteFieldTextSize))
                .foregroundStyle(.secondary)
                .frame(width: OverlayMetrics.symbolColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.system(size: NativeMetrics.Overlay.paletteFieldTextSize))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(model.summary)
                    .font(.system(size: NativeMetrics.Text.secondary))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OverlayMetrics.panelInsetX)
        .padding(.vertical, OverlayMetrics.listPaddingY)
        .frame(minHeight: OverlayMetrics.pickerInputHeight)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func list(maxHeight: CGFloat) -> some View {
        let lines = model.lines
        let skipped = model.skippedLines
        let height = min(Self.listHeight(lines: lines.count, skipped: skipped.count), maxHeight)
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(lines) { line in
                    row(line, symbol: line.isWarning ? "exclamationmark.circle" : "envelope")
                        .accessibilityLabel("\(line.subject), \(line.detail)")
                }
                if let title = model.skippedTitle {
                    HStack {
                        Text(title)
                            .font(.system(size: NativeMetrics.Text.secondary, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, OverlayMetrics.panelInsetX)
                    .frame(height: Self.sectionHeight)
                    .accessibilityAddTraits(.isHeader)
                    ForEach(skipped) { line in
                        row(line, symbol: "minus.circle")
                            .accessibilityLabel("Not sent: \(line.subject), \(line.detail)")
                    }
                }
            }
            .padding(.vertical, OverlayMetrics.listPaddingY)
        }
        .scrollIndicators(height < Self.listHeight(lines: lines.count, skipped: skipped.count) ? .visible : .never)
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("batchSend.list")
    }

    private func row(_ line: BatchSendModel.Line, symbol: String) -> some View {
        HStack(spacing: OverlayMetrics.rowSpacing) {
            Image(systemName: symbol)
                .font(.system(size: OverlayMetrics.rowSymbolSize))
                .foregroundStyle(line.isWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .frame(width: OverlayMetrics.symbolColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.subject)
                    .font(.system(size: NativeMetrics.Text.body))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(line.detail)
                    .font(.system(size: NativeMetrics.Text.secondary))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OverlayMetrics.panelInsetX)
        .frame(height: Self.lineHeight)
        .accessibilityElement(children: .ignore)
    }

    private var reminderRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle(model.reminderTitle, isOn: Binding(get: { model.remindersOn }, set: { model.remindersOn = $0 }))
                    .ohCheckboxToggleStyle()
                    .font(.system(size: NativeMetrics.Text.body))
                    .accessibilityHint("For these drafts only. Press R to switch.")
                    .accessibilityIdentifier("batchSend.reminders")
                Spacer()
                OverlayShortcutHint("R")
                    .frame(width: OverlayMetrics.hintColumn, alignment: .trailing)
            }
            Text(model.reminderDetail)
                .font(.system(size: NativeMetrics.Text.secondary))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, OverlayMetrics.panelInsetX)
        .padding(.vertical, OverlayMetrics.listPaddingY)
        .frame(maxWidth: .infinity, minHeight: OverlayMetrics.rowHeight, alignment: .leading)
        .disabled(!model.canConfirm)
    }

    private var confirmRow: some View {
        HStack(spacing: OverlayMetrics.rowSpacing) {
            Text(model.canConfirm ? model.undoNote : "")
                .font(.system(size: NativeMetrics.Text.secondary))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: OverlayMetrics.rowSpacing)
            Button("Cancel", action: dismiss)
                .accessibilityIdentifier("batchSend.cancel")
            Button(model.confirmTitle) { model.confirm() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canConfirm)
                .accessibilityLabel(model.confirmTitle)
                .accessibilityIdentifier("batchSend.confirm")
        }
        .padding(.horizontal, OverlayMetrics.panelInsetX)
        .frame(maxWidth: .infinity, minHeight: OverlayMetrics.pickerInputHeight)
    }

    private func footerKey(_ key: String, _ title: String) -> some View {
        HStack(spacing: OverlayMetrics.footerKeyGap) {
            OverlayShortcutHint(key)
            Text(title)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(key == "↵" ? "Return" : key == "esc" ? "Escape" : key)")
    }
}
