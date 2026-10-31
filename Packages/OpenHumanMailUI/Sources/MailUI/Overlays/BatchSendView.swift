import MailFeatures
import SwiftUI

/// The confirmation for sending checked drafts: the count and recipients, each draft that goes, the drafts that stay
/// and why, and the "remind me if no reply" switch for this batch. ↵ sends, R flips the switch, Esc cancels. When
/// nothing can go it only explains why, with a single OK.
struct BatchSendView: View {
    static let width: CGFloat = 480
    static let lineHeight: CGFloat = 40
    static let sectionHeight: CGFloat = OverlayMetrics.sectionHeaderHeight
    /// The panel's own rows around the list (header, switch, buttons and footer) until the first layout measures them.
    static let estimatedChromeHeight: CGFloat = 210
    /// Space kept between the panel and the bottom of the window.
    static let bottomMargin: CGFloat = 24
    static let minListHeight: CGFloat = 2 * lineHeight

    let model: BatchSendModel
    let dismiss: () -> Void
    @FocusState private var focused: Bool
    @State private var chromeHeight = Self.estimatedChromeHeight

    var body: some View {
        OverlayPanel(width: Self.width, label: "Send drafts", dismiss: dismiss) { size in
            let full = Self.listHeight(lines: model.lines.count, skipped: model.skippedLines.count)
            let shown = min(full, Self.listLimit(available: size.height, chrome: chromeHeight))
            VStack(spacing: 0) {
                header
                Divider()
                list(height: shown, scrolls: shown < full)
                Divider()
                if model.count > 0 {
                    reminderRow
                    Divider()
                }
                confirmRow
                Divider()
                OverlayFooter {
                    if model.count > 0 {
                        footerKey("↵", "Send")
                        footerKey("R", "Reminders")
                        footerKey("esc", "Cancel")
                    } else {
                        footerKey("↵", "OK")
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { total in
                let measured = (total - shown).rounded(.up)
                if abs(measured - chromeHeight) > 0.5 { chromeHeight = measured }
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

    /// The tallest the list may be: what the window leaves below the panel's top once the rest of the panel and the
    /// bottom margin fit, in whole rows so no row is cut through its subject.
    static func listLimit(available height: CGFloat, chrome: CGFloat) -> CGFloat {
        let room = height - OverlayMetrics.pickerTop - chrome - bottomMargin - 2 * OverlayMetrics.listPaddingY
        let rows = (room / lineHeight).rounded(.down)
        return max(minListHeight, rows * lineHeight + 2 * OverlayMetrics.listPaddingY)
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
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OverlayMetrics.panelInsetX)
        .padding(.vertical, OverlayMetrics.listPaddingY)
        .frame(minHeight: OverlayMetrics.pickerInputHeight)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func list(height: CGFloat, scrolls: Bool) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(model.lines) { line in
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
                    ForEach(model.skippedLines) { line in
                        row(line, symbol: "minus.circle")
                            .accessibilityLabel("Not sent: \(line.subject), \(line.detail)")
                    }
                }
            }
            .padding(.vertical, OverlayMetrics.listPaddingY)
        }
        .scrollIndicators(scrolls ? .visible : .never)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .frame(height: height)
        .clipped()
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

    /// The title and what it does on the left, the system switch on the right, as in Settings.
    private var reminderRow: some View {
        HStack(alignment: .top, spacing: OverlayMetrics.rowSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.reminderTitle)
                    .font(.system(size: NativeMetrics.Text.body))
                    .foregroundStyle(.primary)
                Text(model.reminderDetail)
                    .font(.system(size: NativeMetrics.Text.secondary))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityHidden(true)
            Spacer(minLength: OverlayMetrics.rowSpacing)
            Toggle(model.reminderTitle, isOn: Binding(get: { model.remindersOn }, set: { model.remindersOn = $0 }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityHint("\(model.reminderDetail) Press R to switch.")
                .accessibilityIdentifier("batchSend.reminders")
                .disabled(!model.canConfirm)
        }
        .padding(.horizontal, OverlayMetrics.panelInsetX)
        .padding(.vertical, OverlayMetrics.listPaddingY + 2)
        .frame(maxWidth: .infinity, minHeight: OverlayMetrics.rowHeight, alignment: .leading)
    }

    private var confirmRow: some View {
        HStack(spacing: OverlayMetrics.rowSpacing) {
            if model.count > 0 {
                Text(model.undoNote)
                    .font(.system(size: NativeMetrics.Text.secondary))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: OverlayMetrics.rowSpacing)
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("batchSend.cancel")
                Button(model.confirmTitle) { model.confirm() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canConfirm)
                    .accessibilityLabel(model.confirmTitle)
                    .accessibilityIdentifier("batchSend.confirm")
            } else {
                Spacer(minLength: 0)
                Button("OK", action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("batchSend.ok")
            }
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
