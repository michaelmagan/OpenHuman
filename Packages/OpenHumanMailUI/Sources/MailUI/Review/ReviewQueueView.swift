import MailActions
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI

public struct ReviewQueueView: View {
    let model: ReviewQueueModel
    let router: AppRouter
    @Environment(\.theme) private var theme
    @State private var showsChanges = false

    public init(model: ReviewQueueModel, router: AppRouter) {
        self.model = model
        self.router = router
    }

    public var body: some View {
        HStack(spacing: 0) {
            queueList
                .frame(width: 280)
                .background(theme.bgSidebar.color)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(theme.borderHairline.color).frame(width: theme.borderWidthHairline)
                }
            detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bgWindow.color)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review queue")
    }

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.rows.isEmpty ? String(localized: "Review queue") : String(localized: "Review · \(model.cursor + 1) of \(model.rows.count)"))
                .font(theme.typeLabel.swiftUIFont)
                .foregroundStyle(theme.textTertiary.color)
                .padding(.horizontal, theme.space5)
                .frame(height: 40, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        listRow(row, selected: index == model.cursor)
                    }
                }
            }
        }
    }

    private func listRow(_ row: ReviewQueueModel.Row, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: theme.space1) {
            Text(title(row))
                .font((selected ? theme.typeBodyStrong : theme.typeBody).swiftUIFont)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
            Text(subtitle(row))
                .font(theme.typeMeta.swiftUIFont)
                .foregroundStyle(theme.textTertiary.color)
                .lineLimit(1)
        }
        .padding(.horizontal, theme.space5)
        .padding(.vertical, theme.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? theme.bgRowSelected.color : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func title(_ row: ReviewQueueModel.Row) -> String {
        if let draft = row.draft { return draft.fields.subject.isEmpty ? String(localized: "(no subject)") : draft.fields.subject }
        switch row.state {
        case .accountNotSetUp: return String(localized: "Account not set up")
        case .notFound: return String(localized: "Not found")
        case .loading: return String(localized: "Loading…")
        default: return String(localized: "No longer a draft")
        }
    }

    private func subtitle(_ row: ReviewQueueModel.Row) -> String {
        if let outcome = row.outcome {
            switch outcome {
            case .sent: return String(localized: "Sending")
            case .kept: return String(localized: "Kept")
            case .discarded: return String(localized: "Discarded")
            }
        }
        guard let draft = row.draft else { return row.state == .noLongerDraft ? String(localized: "Skipped") : "" }
        return draft.fields.to.first.map { "→ \($0.name ?? $0.email)" } ?? ""
    }

    @ViewBuilder
    private var detail: some View {
        if model.isFinished {
            finished
        } else if let row = model.current {
            if let draft = row.draft, row.outcome == nil {
                draftDetail(draft)
            } else {
                message(row.outcome == nil ? title(row) : subtitle(row))
            }
        } else {
            message(String(localized: "No agent drafts are waiting for review."))
        }
    }

    private var finished: some View {
        VStack(spacing: theme.space4) {
            Text(model.summary).font(theme.typeTitle.swiftUIFont).foregroundStyle(theme.textPrimary.color)
            TextButton(title: String(localized: "Back to Inbox"), help: "G I", shortcut: .goInbox,
                       tipTitle: String(localized: "Back to Inbox")) { router.perform(.goInbox, source: .toolbar) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ text: String) -> some View {
        Text(text).font(theme.typeBody.swiftUIFont).foregroundStyle(theme.textSecondary.color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func draftDetail(_ draft: DraftSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space5) {
                if let context = model.context { contextBlock(context) }
                if let note = draft.agentNote, !note.isEmpty {
                    Text(note)
                        .font(theme.typeMeta.swiftUIFont)
                        .foregroundStyle(theme.textSecondary.color)
                        .textSelection(.enabled)
                        .accessibilityLabel("Agent note: \(note)")
                }
                if draft.hasRemoteConflict { conflictCard }
                draftBlock(draft)
                if let changes = model.changes { changesBlock(changes) }
                actions
            }
            .padding(theme.space7)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func contextBlock(_ context: ReviewContext) -> some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            if context.olderCount > 0 {
                Text("\(context.olderCount) earlier messages").font(theme.typeMeta.swiftUIFont)
                    .foregroundStyle(theme.textTertiary.color)
            }
            ForEach(context.recent) { message in
                VStack(alignment: .leading, spacing: theme.space1) {
                    Text(message.from.map { $0.name ?? $0.email } ?? "").font(theme.typeBodyStrong.swiftUIFont)
                    Text(message.snippet).font(theme.typeBody.swiftUIFont).lineLimit(3)
                }
                .foregroundStyle(theme.textSecondary.color)
            }
        }
        .padding(theme.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgSidebar.color))
    }

    private func draftBlock(_ draft: DraftSummary) -> some View {
        let flags = model.recipientFlags ?? ReviewRecipientFlags()
        return VStack(alignment: .leading, spacing: theme.space3) {
            recipientLine("To", draft.fields.to, flags: flags)
            if !draft.fields.cc.isEmpty { recipientLine("Cc", draft.fields.cc, flags: flags) }
            Text(draft.fields.subject).font(theme.typeBodyStrong.swiftUIFont).foregroundStyle(theme.textPrimary.color)
            Text(ReviewDiff.plainText(draft.fields))
                .font(theme.typeReader.swiftUIFont)
                .foregroundStyle(theme.textPrimary.color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(theme.space5)
        .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgWindow.color))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusMD)
            .strokeBorder(theme.borderHairline.color, lineWidth: theme.borderWidthHairline))
    }

    private func recipientLine(_ label: String, _ people: [EmailAddress], flags: ReviewRecipientFlags) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space3) {
            Text(label).font(theme.typeMeta.swiftUIFont).foregroundStyle(theme.textTertiary.color).frame(width: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: theme.space1) {
                ForEach(people, id: \.email) { person in
                    let lower = person.email.lowercased()
                    HStack(spacing: theme.space3) {
                        Text(person.name.map { "\($0) <\(person.email)>" } ?? person.email)
                            .font(theme.typeBody.swiftUIFont).foregroundStyle(theme.textPrimary.color)
                        if flags.newRecipients.contains(lower) {
                            Text("New recipient").font(theme.typeCaption.swiftUIFont).foregroundStyle(theme.textWarning.color)
                        }
                        if flags.externalRecipients.contains(lower) {
                            Text("External").font(theme.typeCaption.swiftUIFont).foregroundStyle(theme.textTertiary.color)
                        }
                    }
                }
            }
        }
    }

    private func changesBlock(_ changes: ReviewChanges) -> some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            Toggle(isOn: $showsChanges) {
                Text(changes.isEmpty ? "Changes since agent draft: none" : "Changes since agent draft")
                    .font(theme.typeBody.swiftUIFont)
            }
            .ohCheckboxToggleStyle()
            .disabled(changes.isEmpty)
            if showsChanges, !changes.isEmpty { diffText(changes) }
        }
    }

    private func diffText(_ changes: ReviewChanges) -> some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            if !changes.changedFields.isEmpty {
                Text("Changed: \(changes.changedFields.joined(separator: ", "))")
                    .font(theme.typeMeta.swiftUIFont).foregroundStyle(theme.textSecondary.color)
            }
            changes.body.reduce(Text("")) { text, run in
                let piece = Text(run.text + " ")
                switch run.op {
                case .same: return text + piece
                case .added: return text + piece.foregroundColor(theme.textSuccess.color).bold()
                case .removed: return text + piece.foregroundColor(theme.textDanger.color).strikethrough()
                }
            }
            .font(theme.typeBody.swiftUIFont)
            .textSelection(.enabled)
        }
    }

    private var conflictCard: some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            Text("The agent changed this draft after you edited it.")
                .font(theme.typeBodyStrong.swiftUIFont).foregroundStyle(theme.textWarning.color)
            if let conflict = model.conflictChanges { diffText(conflict) }
            HStack(spacing: theme.space3) {
                TextButton(title: String(localized: "Keep my version"), help: "Keeps what you wrote") {
                    model.resolveConflict(.keepLocal)
                }
                TextButton(title: String(localized: "Use the agent's version"), help: "Replaces your edits") {
                    model.resolveConflict(.takeRemote)
                }
            }
        }
        .padding(theme.space4)
        .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgWarningSubtle.color))
    }

    private var actions: some View {
        HStack(spacing: theme.space2) {
            TextButton(title: String(localized: "Send"), help: "Send it", strong: true, shortcut: .reviewSend,
                       tipTitle: String(localized: "Send it")) { router.perform(.reviewSend, source: .toolbar) }
            TextButton(title: String(localized: "Edit"), help: "Edit in the composer", shortcut: .reviewEdit,
                       tipTitle: String(localized: "Edit in the composer")) { router.perform(.reviewEdit, source: .toolbar) }
            TextButton(title: String(localized: "Keep"), help: "Keep as a draft", shortcut: .reviewKeep,
                       tipTitle: String(localized: "Keep as a draft")) { router.perform(.reviewKeep, source: .toolbar) }
            TextButton(title: String(localized: "Skip"), help: "Next draft", shortcut: .reviewSkip,
                       tipTitle: String(localized: "Next draft")) { router.perform(.reviewSkip, source: .toolbar) }
            Spacer(minLength: 0)
            TextButton(title: String(localized: "Discard"), help: "Discard, with undo", shortcut: .reviewDiscard,
                       tipTitle: String(localized: "Discard, with undo")) { router.perform(.reviewDiscard, source: .toolbar) }
        }
    }
}
