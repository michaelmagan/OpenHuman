import Foundation
import MailModel
import OpenHumanCore

public struct RecipientDrag: Equatable, Sendable {
    public let address: EmailAddress
    public let from: RecipientFieldModel.Kind

    public init(address: EmailAddress, from: RecipientFieldModel.Kind) {
        self.address = address
        self.from = from
    }
}

public enum RecipientMove {
    public static func moving(_ address: EmailAddress, from source: [EmailAddress], to target: [EmailAddress])
        -> (source: [EmailAddress], target: [EmailAddress])? {
        guard let index = source.firstIndex(of: address) ?? source.firstIndex(where: { same($0, address) }) else {
            return nil
        }
        var remaining = source
        let moved = remaining.remove(at: index)
        guard !target.contains(where: { same($0, moved) }) else { return (remaining, target) }
        return (remaining, target + [moved])
    }

    static func same(_ a: EmailAddress, _ b: EmailAddress) -> Bool {
        a.email.caseInsensitiveCompare(b.email) == .orderedSame
    }

    public static func title(movingTo kind: RecipientFieldModel.Kind) -> String {
        switch kind {
        case .to: String(localized: "Move to To")
        case .cc: String(localized: "Move to Cc")
        case .bcc: String(localized: "Move to Bcc")
        }
    }

    public static func dragText(_ address: EmailAddress) -> String {
        guard let name = address.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return address.email }
        let needsQuotes = name.contains { ",;<>\"@".contains($0) }
        let shown = needsQuotes ? "\"" + name.replacingOccurrences(of: "\"", with: "") + "\"" : name
        return shown + " <" + address.email + ">"
    }
}

@MainActor
final class RecipientUndoBox {
    weak var session: ComposeSession?
}

struct RecipientMoveRecord: Equatable, Sendable {
    var address: EmailAddress
    var source: RecipientFieldModel.Kind
    var target: RecipientFieldModel.Kind
    var sourceIndex: Int
    var addedToTarget: Bool
    var showedCc: Bool
    var showedBcc: Bool
}

struct RecipientLayout: Equatable, Sendable {
    var to: [EmailAddress]
    var cc: [EmailAddress]
    var bcc: [EmailAddress]
    var showsCc: Bool
    var showsBcc: Bool
}

extension ComposeSession {
    public func field(_ kind: RecipientFieldModel.Kind) -> RecipientFieldModel {
        switch kind {
        case .to: to
        case .cc: cc
        case .bcc: bcc
        }
    }

    public func moveTargets(from kind: RecipientFieldModel.Kind) -> [RecipientFieldModel.Kind] {
        [RecipientFieldModel.Kind.to, .cc, .bcc].filter { $0 != kind }
    }

    public func isRecipientRowShown(_ kind: RecipientFieldModel.Kind) -> Bool {
        switch kind {
        case .to: true
        case .cc: showsCc || recipientDrag != nil
        case .bcc: showsBcc || recipientDrag != nil
        }
    }

    public func beginRecipientDrag(_ address: EmailAddress, from kind: RecipientFieldModel.Kind) {
        let drag = RecipientDrag(address: address, from: kind)
        if recipientDrag != drag { recipientDrag = drag }
    }

    public func endRecipientDrag() {
        if recipientDrag != nil { recipientDrag = nil }
    }

    @discardableResult
    public func dropRecipient(on kind: RecipientFieldModel.Kind, undoManager: UndoManager?) -> Bool {
        guard let drag = recipientDrag else { return false }
        recipientDrag = nil
        return moveRecipient(drag.address, from: drag.from, to: kind, undoManager: undoManager)
    }

    @discardableResult
    public func moveRecipient(_ address: EmailAddress, from source: RecipientFieldModel.Kind,
                              to target: RecipientFieldModel.Kind, undoManager: UndoManager?) -> Bool {
        guard source != target,
              let moved = RecipientMove.moving(address, from: field(source).tokens, to: field(target).tokens) else {
            return false
        }
        let before = recipientLayout
        let sourceTokens = before.tokens(source)
        let index = sourceTokens.firstIndex(of: address)
            ?? sourceTokens.firstIndex { RecipientMove.same($0, address) } ?? 0
        let record = RecipientMoveRecord(address: sourceTokens[index], source: source, target: target, sourceIndex: index,
                                         addedToTarget: moved.target.count > before.tokens(target).count,
                                         showedCc: before.showsCc, showedBcc: before.showsBcc)
        var after = before
        after.set(source, moved.source)
        after.set(target, moved.target)
        if target == .cc { after.showsCc = true }
        if target == .bcc { after.showsBcc = true }
        applyRecipientLayout(after)
        registerRecipientUndo(record, undoManager: undoManager)
        return true
    }

    var recipientLayout: RecipientLayout {
        RecipientLayout(to: to.tokens, cc: cc.tokens, bcc: bcc.tokens, showsCc: showsCc, showsBcc: showsBcc)
    }

    func applyRecipientLayout(_ layout: RecipientLayout) {
        showsCc = layout.showsCc
        showsBcc = layout.showsBcc
        to.setTokens(layout.to, notify: true)
        cc.setTokens(layout.cc, notify: true)
        bcc.setTokens(layout.bcc, notify: true)
    }

    // Why: recipients added or removed after the move are not undo steps, so undo puts back one address, not a snapshot
    @discardableResult
    func undoRecipientMove(_ record: RecipientMoveRecord, undoManager: UndoManager?) -> Bool {
        var layout = recipientLayout
        var target = layout.tokens(record.target)
        if record.addedToTarget {
            guard let index = target.firstIndex(where: { RecipientMove.same($0, record.address) }) else { return false }
            target.remove(at: index)
        }
        var source = layout.tokens(record.source)
        if !source.contains(where: { RecipientMove.same($0, record.address) }) {
            source.insert(record.address, at: min(record.sourceIndex, source.count))
        }
        layout.set(record.target, target)
        layout.set(record.source, source)
        if !record.showedCc, layout.cc.isEmpty { layout.showsCc = false }
        if !record.showedBcc, layout.bcc.isEmpty { layout.showsBcc = false }
        applyRecipientLayout(layout)
        guard let undoManager else { return true }
        let box = recipientUndoBox
        box.session = self
        undoManager.registerUndo(withTarget: box) { [box, weak undoManager] _ in
            MainActor.assumeIsolated {
                _ = box.session?.moveRecipient(record.address, from: record.source, to: record.target,
                                               undoManager: undoManager)
            }
        }
        undoManager.setActionName(String(localized: "Move Recipient"))
        return true
    }

    private func registerRecipientUndo(_ record: RecipientMoveRecord, undoManager: UndoManager?) {
        guard let undoManager else { return }
        let box = recipientUndoBox
        box.session = self
        undoManager.registerUndo(withTarget: box) { [box, weak undoManager] _ in
            MainActor.assumeIsolated {
                _ = box.session?.undoRecipientMove(record, undoManager: undoManager)
            }
        }
        undoManager.setActionName(String(localized: "Move Recipient"))
    }
}

extension RecipientLayout {
    func tokens(_ kind: RecipientFieldModel.Kind) -> [EmailAddress] {
        switch kind {
        case .to: to
        case .cc: cc
        case .bcc: bcc
        }
    }

    mutating func set(_ kind: RecipientFieldModel.Kind, _ tokens: [EmailAddress]) {
        switch kind {
        case .to: to = tokens
        case .cc: cc = tokens
        case .bcc: bcc = tokens
        }
    }
}
