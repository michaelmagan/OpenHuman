import MailFeatures
import MailTheme
import SwiftUI

/// The hint line at the foot of the mail column: shortcut hints with stroked keycaps on the left, sync and send
/// status on the right.
public struct FooterView: View {
    let status: StatusModel?
    let hints: HintBarModel?
    let theme: ThemeTokens

    public init(status: StatusModel?, hints: HintBarModel?, theme: ThemeTokens) {
        self.status = status
        self.hints = hints
        self.theme = theme
    }

    public static var height: CGFloat { NativeMetrics.HintLine.height }

    public static func isVisible(status: StatusModel?, hints: HintBarModel?) -> Bool {
        hints?.isVisible == true || status?.isVisible == true
    }

    public var body: some View {
        let showsHints = hints?.isVisible == true
        HStack(spacing: NativeMetrics.HintLine.itemGap) {
            if let hints, showsHints {
                HStack(spacing: NativeMetrics.HintLine.keyGap) {
                    HintBarView(model: hints, theme: theme)
                    closeButton(hints)
                }
            }
            Spacer(minLength: 0)
            if let status { StatusBarView(model: status, theme: theme) }
        }
        .padding(.horizontal, NativeMetrics.HintLine.paddingX)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(.background)
        .overlay(alignment: .top) { Divider() }
        .contextMenu {
            if let hints, showsHints {
                Button("Hide Shortcut Hints") { Task { await hints.dismiss() } }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func closeButton(_ hints: HintBarModel) -> some View {
        Button {
            Task { await hints.dismiss() }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: NativeMetrics.HintLine.textSize, weight: .regular))
                .foregroundStyle(.tertiary)
                .frame(width: Self.height, height: Self.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Hide shortcut hints (Settings > General brings them back)")
        .accessibilityLabel("Hide shortcut hints")
    }
}
