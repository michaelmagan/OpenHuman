import MailFeatures
import MailModel
import MailTheme
import SwiftUI

public struct StatusBarView: View {
    let model: StatusModel
    let theme: ThemeTokens

    public init(model: StatusModel, theme: ThemeTokens) {
        self.model = model
        self.theme = theme
    }

    public var body: some View {
        HStack(spacing: NativeMetrics.HintLine.itemGap) {
            if let sending = model.sendingLine { sendingButton(sending) }
            if let focus = model.focusLine {
                Text(focus)
                    .font(Self.font)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            if let smart = model.smartSearchLine {
                Text(smart)
                    .font(Self.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
                    .help("Smart search is indexing your mail on this Mac. Nothing leaves this Mac.")
            }
            if let preparing = model.preparingLine {
                Text(preparing)
                    .font(Self.font)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
                    .help("Mail is preparing replies and summaries on this Mac. Nothing leaves this Mac.")
                    .accessibilityIdentifier("status.aiPreparing")
            }
            if let pending = model.pendingLine {
                Text(pending)
                    .font(Self.font)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
                    .help(model.pendingHelp)
                    .accessibilityIdentifier("status.pendingSync")
            }
            TimelineView(.periodic(from: .now, by: 20)) { context in
                if let sync = model.syncText(now: context.date) {
                    SyncLine(text: sync, color: syncColor)
                        .help(model.syncFailureCode.map { "Details: \($0)" } ?? "")
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status")
    }

    private func sendingButton(_ text: String) -> some View {
        Button {
            model.showSending?()
        } label: {
            HStack(spacing: NativeMetrics.HintLine.keyGap) {
                Image(systemName: "paperplane")
                    .font(Self.font)
                Text(text)
                    .font(Self.font)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the message on its way")
        .accessibilityLabel(text)
        .accessibilityHint("Shows the message on its way, with Undo while it can still be undone.")
        .accessibilityIdentifier("status.sending")
    }

    static let font = Font.system(size: NativeMetrics.HintLine.textSize)

    private var syncColor: AnyShapeStyle {
        guard let state = model.shownSync?.state else { return AnyShapeStyle(.tertiary) }
        switch state {
        case .online: return AnyShapeStyle(.tertiary)
        case .offline, .rateLimited, .syncFailing: return AnyShapeStyle(Color.orange)
        case .needsReauth: return AnyShapeStyle(Color.red)
        }
    }
}

struct SyncLine: View {
    let text: String
    let color: AnyShapeStyle
    @Environment(\.theme) private var theme
    @State private var shown: String?
    @State private var pollingSince: Date?

    var body: some View {
        Text(shown ?? text)
            .font(StatusBarView.font)
            .foregroundStyle(color)
            .lineLimit(1)
            .task(id: text) { await follow(text) }
    }

    private func follow(_ text: String) async {
        if text == StatusModel.pollingText, shown != nil {
            try? await Task.sleep(for: .milliseconds(Int(theme.motionSpinnerDelay)))
            guard !Task.isCancelled else { return }
            shown = text
            pollingSince = Date()
            return
        }
        if let since = pollingSince {
            let left = theme.motionSpinnerMinVisible / 1000 - Date().timeIntervalSince(since)
            if left > 0 {
                try? await Task.sleep(for: .milliseconds(Int(left * 1000)))
                guard !Task.isCancelled else { return }
            }
        }
        pollingSince = nil
        shown = text
    }
}
