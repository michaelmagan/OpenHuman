import MailFeatures
import MailTheme
import SwiftUI

struct HintBarView: View {
    let model: HintBarModel
    let theme: ThemeTokens

    var body: some View {
        let hints = model.hints.filter(\.isEnabled)
        ViewThatFits(in: .horizontal) {
            row(hints)
            row(Array(hints.prefix(ShellMetrics.narrowHintCount)))
        }
        .help("Shortcut hints for where you are. Turn them off in Settings › General, or right-click here.")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shortcut hints")
    }

    private func row(_ hints: [ShortcutHint]) -> some View {
        HStack(spacing: NativeMetrics.HintLine.itemGap) {
            ForEach(hints) { hint in
                HStack(spacing: NativeMetrics.HintLine.keyGap) {
                    HStack(spacing: NativeMetrics.HintLine.keyGap) {
                        ForEach(Array(hint.keycaps.enumerated()), id: \.offset) { _, key in NativeKeycap(key) }
                    }
                    .accessibilityHidden(true)
                    Text(hint.title)
                        .font(.system(size: NativeMetrics.HintLine.textSize))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(hint.title), \(hint.keycaps.joined(separator: " "))")
            }
        }
        .fixedSize()
    }
}
