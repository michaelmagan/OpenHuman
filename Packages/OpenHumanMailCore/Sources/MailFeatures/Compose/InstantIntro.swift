import Foundation
import MailActions
import MailModel
import MailRender
import OpenHumanCore

public struct InstantIntroPlan: Equatable, Sendable {
    public let introducer: EmailAddress
    public let introduced: [EmailAddress]

    public init?(original: MessageSummary, myAddresses: Set<String>) {
        guard let introducer = original.from, !myAddresses.contains(introducer.email.lowercased()) else { return nil }
        var seen = myAddresses.union([introducer.email.lowercased()])
        let introduced = (original.to + original.cc).filter { seen.insert($0.email.lowercased()).inserted }
        guard !introduced.isEmpty else { return nil }
        self.introducer = introducer
        self.introduced = introduced
    }

    public var greeting: String {
        String(localized: "Thanks \(ReaderFormatting.firstName(introducer)), moving you to Bcc.")
    }
}

extension ComposeSession {
    func applyInstantIntro(_ plan: InstantIntroPlan) {
        let onScreen = editor.flatMap { $0.isOnScreen ? $0 : nil }
        let undo = onScreen?.editorUndoManager
        undo?.beginUndoGrouping()
        defer { undo?.endUndoGrouping() }
        for kind in [RecipientFieldModel.Kind.to, .cc] {
            moveRecipient(plan.introducer, from: kind, to: .bcc, undoManager: undo)
        }
        addIntroRecipient(plan.introducer, to: .bcc, undoManager: undo)
        for person in plan.introduced {
            for kind in [RecipientFieldModel.Kind.cc, .bcc] {
                moveRecipient(person, from: kind, to: .to, undoManager: undo)
            }
            addIntroRecipient(person, to: .to, undoManager: undo)
        }
        insertIntroGreeting(plan.greeting, editor: onScreen)
        undo?.setActionName(String(localized: "Instant Intro"))
    }

    private func addIntroRecipient(_ address: EmailAddress, to kind: RecipientFieldModel.Kind, undoManager: UndoManager?) {
        var layout = recipientLayout
        guard !layout.tokens(kind).contains(where: { RecipientMove.same($0, address) }) else { return }
        layout.set(kind, layout.tokens(kind) + [address])
        if kind == .bcc { layout.showsBcc = true }
        applyRecipientLayout(layout)
        registerIntroUndo(address, in: kind, added: true, undoManager: undoManager)
    }

    private func registerIntroUndo(_ address: EmailAddress, in kind: RecipientFieldModel.Kind, added: Bool,
                                   undoManager: UndoManager?) {
        guard let undoManager else { return }
        let box = recipientUndoBox
        box.session = self
        undoManager.registerUndo(withTarget: box) { [box, weak undoManager] _ in
            MainActor.assumeIsolated {
                guard let session = box.session else { return }
                var layout = session.recipientLayout
                var tokens = layout.tokens(kind)
                if added {
                    tokens.removeAll { RecipientMove.same($0, address) }
                } else if !tokens.contains(where: { RecipientMove.same($0, address) }) {
                    tokens.append(address)
                }
                layout.set(kind, tokens)
                session.applyRecipientLayout(layout)
                session.registerIntroUndo(address, in: kind, added: !added, undoManager: undoManager)
            }
        }
        undoManager.setActionName(String(localized: "Instant Intro"))
    }

    private func insertIntroGreeting(_ greeting: String, editor: (any ComposeTextEditing)?) {
        if let editor {
            guard !editor.editorText.hasPrefix(greeting) else { return }
            let inserted = greeting + "\n\n"
            if editor.replaceText(in: 0..<0, with: inserted) {
                editor.placeCaret(at: (inserted as NSString).length)
                editor.focusEditor()
                return
            }
        }
        guard !plainText.hasPrefix(greeting) else { return }
        let isBlank = plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var blocks: [RichTextDocument.Block] = [.paragraph([.text(greeting, [])]), .paragraph([])]
        blocks += isBlank ? [.paragraph([])] : document.blocks
        updateBody(RichTextDocument(blocks: blocks))
        reloadEditor()
    }
}

@MainActor
final class InstantIntroActionHandler: ActionHandler {
    static let ids: [ActionID] = [.instantIntro]

    private weak var environment: AppEnvironment?
    private var notice: Toast.ID?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    private func session(_ context: ActionContext) -> ComposeSession? {
        guard let session = environment?.composeIfStarted?.session(id: context.composer), session.isOpen,
              session.mode == .reply || session.mode == .replyAll, session.thread != nil else { return nil }
        return session
    }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        session(context) == nil ? .disabled(.instantIntroNeedsReply) : .enabled
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let environment, let session = session(request.context), let thread = session.thread else {
            return .notHandled
        }
        let data = environment.data
        return .started(Task { [weak self, weak session] in
            await session?.preparation?.value
            let detail = await ComposeManager.first(data.threadDetail(thread)) ?? nil
            guard let self, let session, session.isOpen else { return }
            let mine = session.account.myAddresses.union(session.fromChoices.map(\.email))
            guard let original = detail?.messages.first(where: { $0.id == session.replyTo }),
                  let plan = InstantIntroPlan(original: original, myAddresses: mine) else {
                return self.sayNoOne()
            }
            session.applyInstantIntro(plan)
        })
    }

    private func sayNoOne() {
        guard let notices = environment?.notices else { return }
        if let notice { notices.dismiss(notice) }
        notice = notices.post(String(localized: "No one to introduce"), style: .info, duration: NoticeCenter.infoDuration)
    }
}
