import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI

public struct SendingCard: View {
    let message: SendingMessage
    let manager: ComposeManager
    @Environment(\.theme) private var theme

    public init(message: SendingMessage, manager: ComposeManager) {
        self.message = message
        self.manager = manager
    }

    public var body: some View {
        let compose = theme.component.compose
        VStack(alignment: .leading, spacing: theme.space4) {
            header
            progress
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(manager.sendingStatus(message, now: context.date))
                    .font(theme.typeBody.swiftUIFont)
                    .foregroundStyle((message.state == .failed ? theme.textDanger : theme.textSecondary).color)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityIdentifier("sending.status")
            }
            Divider().overlay(theme.borderHairline.color)
            VStack(alignment: .leading, spacing: theme.space2) {
                field("From", [message.from])
                field("To", message.to)
                if !message.cc.isEmpty { field("Cc", message.cc) }
                if !message.bcc.isEmpty { field("Bcc", message.bcc) }
                if !message.subject.isEmpty { row("Subject", message.subject) }
            }
            Divider().overlay(theme.borderHairline.color)
            Text(message.text.isEmpty ? String(localized: "(No text)") : message.text)
                .font(theme.typeBody.swiftUIFont)
                .foregroundStyle((message.text.isEmpty ? theme.textTertiary : theme.textPrimary).color)
                .lineLimit(SendingCardMetrics.bodyLines)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !message.attachmentNames.isEmpty {
                Label(message.attachmentNames.joined(separator: ", "), systemImage: "paperclip")
                    .font(theme.typeMeta.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
            }
            Divider().overlay(theme.borderHairline.color)
            actions
        }
        .padding(compose.padding)
        .frame(maxWidth: compose.maxWidth, alignment: .leading)
        .composerSurface(true)
        .onKeyPress(.escape) {
            manager.closeSendingView()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title(message.state))
        .accessibilityIdentifier("sending.card")
    }

    public static func title(_ state: SendingMessage.State) -> String {
        switch state {
        case .queued, .sending, .waitingForConnection: String(localized: "Sending")
        case .sent: String(localized: "Sent")
        case .failed: String(localized: "Not sent")
        case .scheduled: String(localized: "Scheduled")
        }
    }

    private var header: some View {
        HStack(spacing: theme.space3) {
            Image(systemName: Self.symbol(message.state))
                .font(.system(size: SendingCardMetrics.titleGlyph, weight: .regular))
                .foregroundStyle(symbolColor.color)
                .accessibilityHidden(true)
            Text(Self.title(message.state))
                .font(theme.typeSubject.swiftUIFont)
                .foregroundStyle(theme.textPrimary.color)
            Spacer(minLength: theme.space5)
            IconButton(symbol: "xmark", help: "Close  Esc") { manager.closeSendingView() }
        }
    }

    nonisolated static func symbol(_ state: SendingMessage.State) -> String {
        switch state {
        case .queued, .sending, .waitingForConnection: "paperplane"
        case .sent: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .scheduled: "calendar.badge.clock"
        }
    }

    private var symbolColor: ThemeColor {
        switch message.state {
        case .sent: theme.textSuccess
        case .failed: theme.textDanger
        default: theme.textSecondary
        }
    }

    @ViewBuilder private var progress: some View {
        if let current = message.step {
            HStack(spacing: theme.space3) {
                ForEach(SendingMessage.Step.allCases, id: \.self) { step in
                    if step != .queued {
                        Rectangle()
                            .fill((step.rawValue <= current.rawValue ? theme.textSuccess : theme.borderHairline).color)
                            .frame(width: SendingCardMetrics.connector, height: theme.borderWidthHairline * 2)
                    }
                    stepLabel(step, current: current)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func stepLabel(_ step: SendingMessage.Step, current: SendingMessage.Step) -> some View {
        let done = step.rawValue < current.rawValue || (step == .sent && current == .sent)
        let isCurrent = step == current && !done
        let color = done ? theme.textSuccess : (isCurrent ? theme.textPrimary : theme.textTertiary)
        return HStack(spacing: theme.space2) {
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: SendingCardMetrics.stepGlyph))
                    .foregroundStyle(theme.textSuccess.color)
            } else {
                Circle()
                    .fill((isCurrent ? theme.accentFill : theme.borderHairline).color)
                    .frame(width: SendingCardMetrics.stepDot, height: SendingCardMetrics.stepDot)
            }
            Text(Self.stepTitle(step))
                .font((isCurrent ? theme.typeBodyStrong : theme.typeBody).swiftUIFont)
                .foregroundStyle(color.color)
        }
    }

    nonisolated static func stepTitle(_ step: SendingMessage.Step) -> String {
        switch step {
        case .queued: String(localized: "Queued")
        case .sending: String(localized: "Sending")
        case .sent: String(localized: "Sent")
        }
    }

    private func field(_ label: String, _ addresses: [EmailAddress]) -> some View {
        row(label, addresses.map { address in
            address.name.map { "\($0) <\(address.email)>" } ?? address.email
        }.joined(separator: ", "))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space3) {
            Text(label)
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: SendingCardMetrics.labelWidth, alignment: .leading)
            Text(value)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(2)
                .truncationMode(.tail)
                .textSelection(.enabled)
        }
        .font(theme.typeBody.swiftUIFont)
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: theme.space2) {
            if message.offersUndo {
                TextButton(title: String(localized: "Undo"), help: "Undo  ⌘Z", strong: true) {
                    let id = message.id
                    Task { await manager.undoSending(id) }
                }
            }
            if message.offersRetry {
                TextButton(title: String(localized: "Retry"), help: "Send it again", strong: true) {
                    manager.retrySending(message.id)
                }
            }
            if message.offersEdit {
                TextButton(title: String(localized: "Edit"), help: "Open the draft") { manager.editSending(message.id) }
            }
            if message.offersShowInSent {
                TextButton(title: String(localized: "Show in Sent"), help: "Open it in Sent") {
                    manager.showSendingInSent(message.id)
                }
            }
            Spacer(minLength: theme.space5)
            Button { manager.closeSendingView() } label: {
                Text("Close")
                    .font(theme.typeBody.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close  Esc")
            .accessibilityIdentifier("sending.close")
        }
    }
}

enum SendingCardMetrics {
    static let titleGlyph: CGFloat = 15
    static let stepGlyph: CGFloat = 12
    static let stepDot: CGFloat = 8
    static let connector: CGFloat = 24
    static let labelWidth: CGFloat = 56
    static let bodyLines = 12
}
