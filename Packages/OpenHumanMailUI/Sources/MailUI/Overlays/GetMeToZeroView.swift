import MailFeatures
import SwiftUI

struct GetMeToZeroView: View {
    let model: GetMeToZeroModel
    let dismiss: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        OverlayPanel(width: OverlayMetrics.timePickerWidth, dismiss: dismiss) { _ in
            VStack(spacing: 0) {
                header
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(GetMeToZeroModel.Age.allCases.enumerated()), id: \.element.id) { index, age in
                        ageRow(age, number: index + 1)
                    }
                }
                .padding(.vertical, OverlayMetrics.listPaddingY)
                Divider()
                VStack(spacing: 0) {
                    toggle("Keep unread", key: "U", isOn: Binding(get: { model.keepUnread }, set: { model.keepUnread = $0 }))
                    toggle("Keep starred", key: "S", isOn: Binding(get: { model.keepStarred }, set: { model.keepStarred = $0 }))
                }
                .padding(.vertical, OverlayMetrics.listPaddingY)
                Divider()
                confirmRow
                Divider()
                OverlayFooter { Text(model.footer).fixedSize(horizontal: false, vertical: true) }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.escape) { dismiss(); return .handled }
            .onKeyPress(.return, phases: .down) { _ in model.confirm(); return .handled }
            .onKeyPress(characters: .alphanumerics, phases: .down) { press in
                switch press.characters.lowercased() {
                case "u": model.keepUnread.toggle()
                case "s": model.keepStarred.toggle()
                default:
                    guard let digit = Int(press.characters) else { return .ignored }
                    return model.chooseNumber(digit) ? .handled : .ignored
                }
                return .handled
            }
        }
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(spacing: OverlayMetrics.fieldSpacing) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: NativeMetrics.Overlay.paletteFieldTextSize))
                .foregroundStyle(.secondary)
                .frame(width: OverlayMetrics.symbolColumn)
                .accessibilityHidden(true)
            Text(model.title)
                .font(.system(size: NativeMetrics.Overlay.paletteFieldTextSize))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, OverlayMetrics.panelInsetX)
        .frame(height: OverlayMetrics.pickerInputHeight)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func ageRow(_ age: GetMeToZeroModel.Age, number: Int) -> some View {
        let isChosen = model.age == age
        return OverlayRow(isSelected: isChosen) { model.age = age } label: {
            HStack(spacing: OverlayMetrics.rowSpacing) {
                Image(systemName: "checkmark")
                    .font(.system(size: OverlayMetrics.rowSymbolSize, weight: .semibold))
                    .foregroundStyle(.tint)
                    .opacity(isChosen ? 1 : 0)
                    .frame(width: OverlayMetrics.symbolColumn)
                    .accessibilityHidden(true)
                Text(age.title)
                    .font(.system(size: NativeMetrics.Text.body, weight: isChosen ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: OverlayMetrics.rowSpacing)
                OverlayShortcutHint("\(number)")
                    .frame(width: OverlayMetrics.hintColumn, alignment: .trailing)
            }
        }
        .accessibilityLabel(age.title)
        .accessibilityValue("shortcut \(number)")
    }

    private func toggle(_ title: String, key: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Toggle(title, isOn: isOn)
                .ohCheckboxToggleStyle()
                .font(.system(size: NativeMetrics.Text.body))
            Spacer()
            OverlayShortcutHint(key)
                .frame(width: OverlayMetrics.hintColumn, alignment: .trailing)
        }
        .padding(.horizontal, OverlayMetrics.panelInsetX)
        .frame(maxWidth: .infinity, minHeight: OverlayMetrics.rowHeight, alignment: .leading)
    }

    private var confirmRow: some View {
        HStack(spacing: OverlayMetrics.rowSpacing) {
            Group {
                if model.isLoading {
                    Text("Counting…").foregroundStyle(.secondary)
                } else if let error = model.loadError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if model.matchCount == 0 {
                    Text("Nothing to archive with these choices").foregroundStyle(.secondary)
                } else if model.isPartial {
                    Text("The newest part of a large inbox").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: NativeMetrics.Text.secondary))
            .lineLimit(2)
            Spacer(minLength: OverlayMetrics.rowSpacing)
            Button(model.confirmTitle) { model.confirm() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isLoading || model.matchCount == 0)
                .accessibilityLabel(model.isLoading ? "Counting" : model.confirmTitle)
        }
        .padding(.horizontal, OverlayMetrics.panelInsetX)
        .frame(maxWidth: .infinity, minHeight: OverlayMetrics.pickerInputHeight)
    }
}
