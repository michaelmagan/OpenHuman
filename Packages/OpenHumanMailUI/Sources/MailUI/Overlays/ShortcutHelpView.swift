import MailActions
import MailFeatures
import MailTheme
import SwiftUI

struct ShortcutHelpView: View {
    let model: ShortcutHelpModel
    let dismiss: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        OverlayPanel(width: OverlayMetrics.shortcutHelpWidth, top: Self.top, dismiss: dismiss) { _ in
            VStack(spacing: 0) {
                OverlayFieldRow(symbol: "keyboard") {
                    TextField("Filter shortcuts", text: Binding(get: { model.filter }, set: { model.filter = $0 }),
                              prompt: Text("Filter shortcuts"))
                        .overlayField()
                        .focused($focused)
                        .onKeyPress(.escape) { dismiss(); return .handled }
                        .accessibilityLabel("Filter shortcuts")
                } trailing: {
                    OverlayShortcutHint("esc")
                }
                Divider()
                ScrollView {
                    HStack(alignment: .top, spacing: Self.columnSpacing) {
                        ForEach(model.sections) { section in
                            VStack(alignment: .leading, spacing: Self.lineSpacing) {
                                Text(section.title)
                                    .font(.system(size: NativeMetrics.Text.caption, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.bottom, OverlayMetrics.sectionHeaderBottom)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(section.lines) { line in
                                    lineView(line)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    .padding(OverlayMetrics.panelInsetX)
                }
                .frame(maxHeight: OverlayMetrics.paletteListMaxHeight + 120)
            }
        }
        .onAppear { focused = true }
    }

    static let top: CGFloat = 64
    static let columnSpacing: CGFloat = 24
    static let lineSpacing: CGFloat = 4

    private func lineView(_ line: ShortcutLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: OverlayMetrics.rowSpacing) {
            VStack(alignment: .leading, spacing: 0) {
                Text(line.title)
                    .font(.system(size: NativeMetrics.Text.body))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let place = line.place {
                    Text(place)
                        .font(.system(size: NativeMetrics.Text.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: OverlayMetrics.rowSpacing)
            if let first = line.keys.first { OverlayShortcutHint(first) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityText(line))
    }

    static func accessibilityText(_ line: ShortcutLine) -> String {
        let keys = line.keys.enumerated().map { index, key in
            line.places.indices.contains(index) ? "\(key) in \(line.places[index].lowercased())" : key
        }
        return "\(line.title), \(keys.joined(separator: ", "))"
    }
}
