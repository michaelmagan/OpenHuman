import AppKit
import MailFeatures

@MainActor
final class OverlayFocusKeeper: OverlayFocusKeeping {
    private enum Phase { case idle, showing, closing }

    private let windowProvider: () -> NSWindow?
    private weak var window: NSWindow?
    private var observation: NSKeyValueObservation?
    private var phase = Phase.idle
    private var checkScheduled = false
    private weak var lastSeen: NSView?
    private var fieldsGoneSeen = false

    private weak var saved: NSView?
    private var savedSelection: NSRange?
    private let existingFields = NSHashTable<NSTextField>.weakObjects()
    private let overlayFields = NSHashTable<NSTextField>.weakObjects()
    private weak var holder: NSView?
    private var holderSelection: NSRange?

    init(window: @escaping () -> NSWindow?) {
        self.windowProvider = window
    }

    func overlayChanged(showing: Bool) {
        guard let window = attach() else { return }
        if showing {
            if phase != .showing {
                keep(window.firstResponder)
                phase = .showing
                fieldsGoneSeen = false
            }
            existingFields.removeAllObjects()
            for field in Self.editableFields(in: window) { existingFields.add(field) }
            scheduleCheck()
        } else if phase == .showing {
            phase = .closing
            fieldsGoneSeen = false
            giveBack(in: window)
            lastSeen = Self.control(of: window.firstResponder)
            scheduleCheck()
        }
    }

    func overlayAppeared() { scheduleCheck() }

    func overlayDisappeared() { scheduleCheck() }

    private func attach() -> NSWindow? {
        guard let window = windowProvider() else { return nil }
        if self.window !== window || observation == nil {
            self.window = window
            observation = window.observe(\.firstResponder, options: []) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleCheck() }
            }
        }
        return window
    }

    private func scheduleCheck() {
        guard phase != .idle, !checkScheduled else { return }
        checkScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.checkScheduled = false
            self.check()
        }
    }

    private func check() {
        guard let window else { return }
        let current = Self.control(of: window.firstResponder)
        switch phase {
        case .idle:
            return
        case .showing:
            if let field = current as? NSTextField, !existingFields.contains(field) {
                overlayFields.add(field)
                OverlayInputLineKeeper.watch(field)
                return
            }
            guard let input = input(in: window) else { return }
            overlayFields.add(input)
            OverlayInputLineKeeper.watch(input)
            focus(input, in: window)
        case .closing:
            let changed = current !== lastSeen
            lastSeen = current
            if isNobody(current, in: window) {
                if let holder, holder.window === window, !holder.isHiddenOrHasHiddenAncestor {
                    focus(holder, in: window)
                    select(holderSelection, in: holder)
                }
                return
            }
            if current !== holder {
                holder = current
                holderSelection = nil
            }
            if changed, fieldsGoneSeen {
                end()
            } else if !overlayFields.allObjects.contains(where: { $0.window === window }) {
                fieldsGoneSeen = true
            }
        }
    }

    private func end() {
        phase = .idle
        holder = nil
        holderSelection = nil
        fieldsGoneSeen = false
    }

    private func keep(_ responder: NSResponder?) {
        let control = Self.control(of: responder)
        if let field = control as? NSTextField, overlayFields.contains(field) {
            saved = holder ?? saved
            savedSelection = holderSelection
            return
        }
        saved = control
        if let editor = responder as? NSTextView, editor.isFieldEditor, control is NSTextField {
            savedSelection = editor.selectedRange()
        } else {
            savedSelection = nil
        }
    }

    private func input(in window: NSWindow) -> NSTextField? {
        Self.editableFields(in: window).first {
            !existingFields.contains($0) && !$0.isHiddenOrHasHiddenAncestor
        }
    }

    private func giveBack(in window: NSWindow) {
        for field in Self.editableFields(in: window) where !existingFields.contains(field) {
            overlayFields.add(field)
        }
        let target = saved
        holder = target
        holderSelection = savedSelection
        saved = nil
        savedSelection = nil
        guard let target, target.window === window, !target.isHiddenOrHasHiddenAncestor else {
            holder = nil
            return
        }
        let current = Self.control(of: window.firstResponder)
        if current === target { return }
        guard isNobody(current, in: window) else {
            holder = current
            holderSelection = nil
            return
        }
        focus(target, in: window)
        select(holderSelection, in: target)
    }

    private func isNobody(_ current: NSView?, in window: NSWindow) -> Bool {
        guard let current, current.window === window else { return true }
        if let field = current as? NSTextField, overlayFields.contains(field) { return true }
        if let holder, holder !== current, holder.isDescendant(of: current) { return true }
        return false
    }

    private func focus(_ view: NSView, in window: NSWindow) {
        if window.makeFirstResponder(view), Self.control(of: window.firstResponder) === view { return }
        window.endEditing(for: nil)
        window.makeFirstResponder(view)
    }

    private func select(_ range: NSRange?, in view: NSView) {
        guard let field = view as? NSTextField, let range, let editor = field.currentEditor() else { return }
        let length = (editor.string as NSString).length
        let location = min(range.location, length)
        editor.selectedRange = NSRange(location: location, length: min(range.length, length - location))
    }

    static func control(of responder: NSResponder?) -> NSView? {
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSTextField {
            return field
        }
        return responder as? NSView
    }

    /// The window's editable fields: those in the content view, then those in the toolbar (the search field).
    static func editableFields(in window: NSWindow) -> [NSTextField] {
        var result: [NSTextField] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, field.isEditable { result.append(field) }
            for child in view.subviews { walk(child) }
        }
        if let root = window.contentView { walk(root) }
        for field in MainContentViewController.toolbarFields(of: window) where !result.contains(where: { $0 === field }) {
            result.append(field)
        }
        return result
    }
}
