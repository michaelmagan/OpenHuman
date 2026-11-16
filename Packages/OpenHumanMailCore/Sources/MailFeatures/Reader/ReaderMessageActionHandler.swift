import Foundation
import MailActions
import MailModel

@MainActor
final class ReaderMessageActionHandler: ActionHandler {
    static let ids: [ActionID] = [.nextMessage, .previousMessage, .toggleMessage, .expandAllMessages, .toggleQuotedText,
                                  .showImages, .showNewMessages, .findInConversation, .openMessageOrReply]

    /// The reply ↵ makes once the message the keys selected is open.
    static let returnReply: ActionID = ActionCatalog.returnRepliesAll ? .replyAll : .reply

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        if id == .openMessageOrReply {
            if Self.closedFocus(host, context) != nil { return .enabled }
            return (host as? AppRouter)?.environment.actions.availability(Self.returnReply, host: host, context: context)
                ?? .hidden
        }
        guard let reader = Self.reader(host, context) else { return .hidden }
        if id == .findInConversation { return .enabled }
        guard reader.focusedMessage != nil else { return .hidden }
        switch id {
        case .nextMessage: return reader.canFocusNext ? .enabled : .disabled(.other("This is the newest message"))
        case .previousMessage: return reader.canFocusPrevious ? .enabled : .disabled(.other("This is the oldest message"))
        case .showImages: return reader.canShowImages ? .enabled : .disabled(.other("No images are hidden"))
        case .showNewMessages: return reader.pendingMessages.isEmpty ? .disabled(.other("No new messages")) : .enabled
        default: return .enabled
        }
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        if request.id == .openMessageOrReply {
            if let reader = Self.closedFocus(request.host, request.context) {
                reader.toggleFocused()
                return .done
            }
            let replied = request.router?.environment.actions.perform(Self.returnReply, source: request.source,
                                                                     host: request.host, context: request.context)
            return replied == true ? .done : .notHandled
        }
        guard let reader = Self.reader(request.host, request.context) else { return .notHandled }
        switch request.id {
        case .nextMessage: return reader.focusNext() ? .done : .notHandled
        case .previousMessage: return reader.focusPrevious() ? .done : .notHandled
        case .toggleMessage: reader.toggleFocused()
        case .expandAllMessages: reader.expandAll()
        case .toggleQuotedText: reader.toggleQuotedText()
        case .showImages: reader.showImages()
        case .showNewMessages: reader.showNewMessages()
        case .findInConversation: reader.requestFind()
        default: return .notHandled
        }
        return .done
    }

    /// The open conversation when the message the keys selected is closed: ↵ opens it before it replies.
    private static func closedFocus(_ host: (any ActionHost)?, _ context: ActionContext) -> ReaderModel? {
        guard let reader = reader(host, context), let key = reader.focusedMessage,
              reader.message(key)?.isExpanded == false else { return nil }
        return reader
    }

    private static func reader(_ host: (any ActionHost)?, _ context: ActionContext) -> ReaderModel? {
        guard let router = host as? AppRouter, router.mode == .reader, let reader = router.reader,
              reader.thread == context.focusedThread, reader.state == .loaded else { return nil }
        return reader
    }
}
