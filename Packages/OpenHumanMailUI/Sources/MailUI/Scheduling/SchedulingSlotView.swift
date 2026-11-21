import MailFeatures
import MailModel
import MailTheme
import SwiftUI

public struct SchedulingSlotView: View {
    let assistant: SchedulingAssistant
    let thread: ThreadKey
    let showsChips: Bool
    @Environment(\.theme) private var theme

    public init(assistant: SchedulingAssistant, thread: ThreadKey, showsChips: Bool = true) {
        self.assistant = assistant
        self.thread = thread
        self.showsChips = showsChips
    }

    public var body: some View {
        let chips = showsChips ? assistant.suggestions(for: thread) : []
        let followUp = assistant.followUp.flatMap { $0.context.thread == thread ? $0 : nil }
        let checking = showsChips && assistant.status[thread] == .checking
        let failure: String? = if case .failed(let why)? = assistant.status[thread] { why } else { nil }
        let panel = assistant.conflictThread == thread || assistant.pickerThread == thread
        let shows = !chips.isEmpty || followUp != nil || checking || panel || assistant.isDrafting || failure != nil
        VStack(alignment: .leading, spacing: theme.space3) {
            if shows {
                if showsChips || followUp != nil {
                    Rectangle().fill(theme.borderHairline.color).frame(height: theme.borderWidthHairline)
                        .accessibilityHidden(true)
                }
                if let followUp {
                    SchedulingFollowUpCard(assistant: assistant, card: followUp)
                } else if checking {
                    Text("Checking your calendar…").font(theme.typeMeta.swiftUIFont)
                        .foregroundStyle(theme.textTertiary.color)
                } else {
                    if !chips.isEmpty { chipRow(chips) }
                    if let failure {
                        Text(failure).font(theme.typeMeta.swiftUIFont).foregroundStyle(theme.textSecondary.color)
                    }
                    if assistant.conflictThread == thread { conflictDetail }
                    if assistant.pickerThread == thread { SchedulingOptionsPicker(assistant: assistant, thread: thread) }
                    if assistant.isDrafting {
                        Text("Writing the reply on this Mac…").font(theme.typeMeta.swiftUIFont)
                            .foregroundStyle(theme.textTertiary.color)
                    }
                }
            }
        }
        .padding(.top, shows && (showsChips || followUp != nil) ? theme.space4 : (shows ? theme.space2 : 0))
        .padding(.bottom, shows && !showsChips ? theme.space2 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: thread) { await assistant.analyze(thread) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.scheduling")
    }

    private func chipRow(_ chips: [ReplySuggestion]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: theme.space2) { ForEach(chips) { chipButton($0) } }
            VStack(alignment: .leading, spacing: theme.space2) { ForEach(chips) { chipButton($0) } }
        }
        .accessibilityIdentifier("scheduling.chips")
    }

    private func chipButton(_ chip: ReplySuggestion) -> some View {
        SchedulingChip(title: chip.label, help: chip.help, isConflict: chip.isWarning) {
            Task { await assistant.use(chip, in: thread) }
        }
        .accessibilityIdentifier("scheduling.chip.\(chip.id)")
    }

    @ViewBuilder
    private var conflictDetail: some View {
        if let analysis = assistant.analyses[thread], let event = analysis.conflicts.first {
            VStack(alignment: .leading, spacing: theme.space2) {
                Text(event.title).font(theme.typeBodyStrong.swiftUIFont).foregroundStyle(theme.textPrimary.color)
                Text(assistant.slotText(SchedulingSlot(start: event.start, end: event.end)))
                    .font(theme.typeMeta.swiftUIFont).foregroundStyle(theme.textSecondary.color)
                if !event.attendees.isEmpty {
                    Text("With \(event.attendees.map { $0.name ?? $0.email }.joined(separator: ", "))")
                        .font(theme.typeMeta.swiftUIFont).foregroundStyle(theme.textSecondary.color).lineLimit(2)
                }
                if analysis.moves == nil {
                    Text("Mail can't move this one (someone else organizes it, or there's no free slot).")
                        .font(theme.typeCaption.swiftUIFont).foregroundStyle(theme.textTertiary.color)
                }
                HStack(spacing: theme.space3) {
                    if let moves = analysis.moves {
                        Button(String(localized: "Accept \(assistant.clockText(analysis.proposal.start)) and move \(SchedulingAssistantText.title(event.title))")) {
                            Task { await assistant.draft(.acceptAndMove(moves), in: thread) }
                        }
                        .help("Reply that their time works; Mail offers to move this meeting after you send it.")
                    }
                    Button("Keep") { assistant.conflictThread = nil }
                        .help("Keep this meeting where it is.")
                }
            }
            .padding(theme.space4)
            .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgSunken.color))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("scheduling.conflict")
        }
    }
}

struct SchedulingChip: View {
    let title: String
    let help: String
    var isConflict = false
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.typeLabel.swiftUIFont)
                .foregroundStyle((isConflict ? theme.textWarning : theme.textPrimary).color)
                .lineLimit(1)
                .padding(.horizontal, theme.space3)
                .padding(.vertical, theme.space1)
                .background(Capsule().fill((hovered ? theme.bgSunken : theme.bgWindow).color))
                .overlay(Capsule().strokeBorder(theme.borderControl.color, lineWidth: theme.borderWidthHairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
    }
}

public struct SchedulingOptionsPicker: View {
    let assistant: SchedulingAssistant
    let thread: ThreadKey
    @Environment(\.theme) private var theme

    public init(assistant: SchedulingAssistant, thread: ThreadKey) {
        self.assistant = assistant
        self.thread = thread
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            Text("Reply with").font(theme.typeLabel.swiftUIFont).foregroundStyle(theme.textTertiary.color)
            ForEach(Array(assistant.options(for: thread).enumerated()), id: \.offset) { index, option in
                Button {
                    Task { await assistant.draft(option, in: thread) }
                } label: {
                    HStack(spacing: theme.space3) {
                        Text("\(index + 1)").font(theme.typeMeta.swiftUIFont).foregroundStyle(theme.textTertiary.color)
                            .frame(width: 14, alignment: .trailing)
                        Text(assistant.title(of: option, in: thread)).font(theme.typeBody.swiftUIFont)
                            .foregroundStyle(theme.textPrimary.color).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Text("The reply opens as a draft. Nothing is sent.").font(theme.typeCaption.swiftUIFont)
                    .foregroundStyle(theme.textTertiary.color)
                Spacer(minLength: 0)
                Button("Cancel") { assistant.pickerThread = nil }
            }
        }
        .padding(theme.space4)
        .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgSunken.color))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scheduling.options")
    }
}

public struct SchedulingFollowUpCard: View {
    let assistant: SchedulingAssistant
    let card: SchedulingAssistant.FollowUp
    @Environment(\.theme) private var theme

    public init(assistant: SchedulingAssistant, card: SchedulingAssistant.FollowUp) {
        self.assistant = assistant
        self.card = card
    }

    public var body: some View {
        let context = card.context
        VStack(alignment: .leading, spacing: theme.space3) {
            Text(context.conflicts.isEmpty
                 ? "Reply sent. Add \(assistant.clockText(context.proposal.start)) to your calendar?"
                 : "Reply sent. What about \(SchedulingAssistantText.title(context.conflicts[0].title))?")
                .font(theme.typeBodyStrong.swiftUIFont).foregroundStyle(theme.textPrimary.color)
            if let notify = assistant.notifyLine(card.moves) {
                Text(notify).font(theme.typeMeta.swiftUIFont).foregroundStyle(theme.textSecondary.color)
            }
            if let note = card.note {
                Text(note).font(theme.typeMeta.swiftUIFont).foregroundStyle(theme.textSecondary.color)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: theme.space3) { actions(context) }
                VStack(alignment: .leading, spacing: theme.space2) { actions(context) }
            }
        }
        .padding(theme.space4)
        .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgSunken.color))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scheduling.followUp")
    }

    @ViewBuilder
    private func actions(_ context: SchedulingReplyContext) -> some View {
        if let move = card.moves.first {
            Button("Move \(SchedulingAssistantText.title(move.event.title)) to \(assistant.clockText(move.to.start))") {
                Task { await assistant.moveConflicts() }
            }
            .help("Sent after a few seconds, so Undo (⌘Z) can stop it.")
            .accessibilityIdentifier("scheduling.followUp.move")
        }
        if context.conflicts.isEmpty {
            Button("Add to calendar") { Task { await assistant.acceptConflict() } }
                .accessibilityIdentifier("scheduling.followUp.add")
        } else {
            Button("Accept the conflict") { Task { await assistant.acceptConflict() } }
                .help("Add their time anyway; both stay on your calendar.")
                .accessibilityIdentifier("scheduling.followUp.accept")
            Button("Ask for other times") { Task { await assistant.followUpAskForOtherTimes() } }
                .accessibilityIdentifier("scheduling.followUp.ask")
        }
        Button("Dismiss") { assistant.dismissFollowUp() }
            .accessibilityIdentifier("scheduling.followUp.dismiss")
    }
}

enum SchedulingAssistantText {
    static func title(_ text: String) -> String {
        text.count <= 24 ? text : String(text.prefix(23)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
