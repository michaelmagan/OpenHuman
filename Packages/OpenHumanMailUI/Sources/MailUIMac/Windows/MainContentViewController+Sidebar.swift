import AppKit
import MailActions
import MailFeatures
import MailUI

/// The sidebar takes the keys with ← in the list. Its list is the system's: ↑ ↓ move its selection, which only
/// highlights a row (see `MailSidebarModel.choose`), and VoiceOver reads the row it moves to. The sidebar scope's keys
/// (Return, Esc, J and K) arrive through the key router.
extension MainContentViewController {
    static let sidebarFocusAttempts = 50

    /// The window's sidebar list: the table in the first column of the split view that holds the mail column.
    func sidebarTable() -> NSTableView? {
        var outer: NSSplitView?
        var ancestor = view.superview
        while let current = ancestor {
            if let split = current as? NSSplitView { outer = split }
            ancestor = current.superview
        }
        guard let column = outer?.arrangedSubviews.first, !view.isDescendant(of: column) else { return nil }
        return Self.firstTable(in: column)
    }

    private static func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = firstTable(in: child) { return table }
        }
        return nil
    }

    func sidebarHasTheKeys() -> Bool {
        guard let responder = view.window?.firstResponder as? NSView, let table = sidebarTable() else { return false }
        return responder === table || responder.isDescendant(of: table)
    }

    /// Keeps `AppRouter.sidebarHasKeys` current, whichever way the keys moved (a click, ←, Esc, the sidebar hiding).
    func observeSidebarKeys() {
        guard firstResponderObservation == nil, let window = view.window else { return }
        firstResponderObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncSidebarKeys() }
        }
    }

    func syncSidebarKeys() {
        let hadKeys = router.sidebarHasKeys
        let hasKeys = sidebarHasTheKeys()
        if hadKeys != hasKeys { router.sidebarHasKeys = hasKeys }
        // Why: hiding the sidebar (⌃⌘S, the toolbar button) hands its keys to the window itself, where no key acts
        guard hadKeys, !hasKeys, let window = view.window, window.firstResponder == nil || window.firstResponder === window
        else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.returnKeysFromSidebar() }
        }
    }

    func renderSidebarFocus() {
        let visible = router.isLabelSidebarVisible
        let hidden = shownSidebarVisible && !visible
        shownSidebarVisible = visible
        if router.sidebarFocusRequest != seenSidebarFocus {
            seenSidebarFocus = router.sidebarFocusRequest
            focusSidebar(request: seenSidebarFocus)
        }
        if router.sidebarReturnRequest != seenSidebarReturn {
            seenSidebarReturn = router.sidebarReturnRequest
            returnKeysFromSidebar()
        } else if hidden, router.sidebarHasKeys {
            // Why: a hidden first responder would leave the keys nowhere; ⌃⌘S gives them back to the list
            router.leaveSidebar()
        }
    }

    /// Gives the sidebar's list the keys, waiting a few frames for it to appear when ← has just shown the sidebar.
    func focusSidebar(request: Int, attempt: Int = 0) {
        guard router.sidebarFocusRequest == request, router.isLabelSidebarVisible, let window = view.window else { return }
        if let table = sidebarTable(), !table.isHiddenOrHasHiddenAncestor, table.numberOfRows > 0,
           window.makeFirstResponder(table) {
            if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
            syncSidebarKeys()
            return
        }
        guard attempt < Self.sidebarFocusAttempts else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
            MainActor.assumeIsolated { self?.focusSidebar(request: request, attempt: attempt + 1) }
        }
    }

    /// The list (or the open conversation) takes the keys back. All Inboxes and the Calendar take them themselves
    /// when they appear, so for those the sidebar only lets go.
    func returnKeysFromSidebar() {
        guard let window = view.window, sidebarHasTheKeys() || window.firstResponder === window else { return }
        let ownPlace = router.unifiedInbox == nil && router.environment.calendarWindowIfStarted?.isOpen != true
        if ownPlace {
            window.makeFirstResponder(router.mode == .reader ? reader.focusView : tableView)
        } else if sidebarHasTheKeys() {
            window.makeFirstResponder(nil)
        }
        syncSidebarKeys()
    }

    /// The sidebar scope's actions. Nil passes the action on to the router.
    func performInSidebar(_ action: ActionID) -> Bool? {
        switch action {
        case .sidebarOpen:
            MailSidebarModel.openHighlight(router: router)
            return true
        case .sidebarLeave:
            router.leaveSidebar()
            return true
        case .calendarOpen where router.environment.calendarWindowIfStarted?.isOpen == true:
            // 2 is the sidebar's own while the Calendar shows, so it goes back to the mail as in the Calendar
            return router.perform(.calendarBackToMail)
        case .sidebarNext: return moveSidebarSelection(down: true)
        case .sidebarPrevious: return moveSidebarSelection(down: false)
        default: return nil
        }
    }

    /// J and K are the list's ↓ and ↑, so the sidebar's own arrow handling moves the selection.
    private func moveSidebarSelection(down: Bool) -> Bool {
        guard let table = sidebarTable(), let window = view.window else { return false }
        let arrow = down ? "\u{F701}" : "\u{F700}"
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: arrow,
                                           charactersIgnoringModifiers: arrow, isARepeat: false,
                                           keyCode: down ? 125 : 126) else { return false }
        table.keyDown(with: event)
        return true
    }
}
