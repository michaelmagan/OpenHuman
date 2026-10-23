import AppKit
import MailFeatures
import MailTheme
import MailUI
import SwiftUI

public struct MainWindowRoot: View {
    let environment: AppEnvironment
    let themes: ThemeStore
    let onAttach: ((MainContentViewController) -> Void)?

    public init(environment: AppEnvironment, themes: ThemeStore, onAttach: ((MainContentViewController) -> Void)? = nil) {
        self.environment = environment
        self.themes = themes
        self.onAttach = onAttach
        ThemeActionHandler.install(in: environment.actions, store: themes)
    }

    public var body: some View {
        let router = environment.router
        let resolved = themes.resolved
        let calendarWindowOpen = environment.calendarWindow?.isOpen == true
        MailShellView(router: router, inspectorShown: inspectorShown(hidden: calendarWindowOpen),
                      inspectorWidth: CGFloat(resolved.tokens.component.sidebar.width)) {
            MainContentRepresentable(router: router, theme: resolved.tokens, hidesMail: calendarWindowOpen, onMake: onAttach)
                .overlay { ReviewHostView(environment: environment) }
                .overlay { ComposerHostView(manager: environment.compose) }
                .overlay {
                    if let window = environment.calendarWindow, window.isOpen {
                        CalendarWindowView(model: window, router: router)
                            .transaction { $0.disablesAnimations = true }
                    }
                }
        } inspector: {
            if let calendar = environment.calendarSidebar, calendar.isVisible {
                CalendarSidebarView(model: calendar, router: router)
            } else if let contact = environment.actions.superhumanCore?.contextSidebar, contact.isVisible {
                ContextSidebarView(model: contact, router: router)
            }
        }
        .floatsSearchDropdown()
        .themed(by: themes)
        .background(WindowHooks(theme: resolved, router: router))
        .task { await environment.status.run() }
        .task { await environment.failedOperationNotices.run() }
    }

    private func inspectorShown(hidden: Bool) -> Binding<Bool> {
        let calendar = environment.calendarSidebar
        let contact = environment.actions.superhumanCore?.contextSidebar
        return Binding(get: { !hidden && (calendar?.isVisible == true || contact?.isVisible == true) },
                       set: { shown in
                           guard !shown else { return }
                           if calendar?.isVisible == true { calendar?.setVisible(false) }
                           if contact?.isVisible == true { contact?.setVisible(false) }
                       })
    }
}

struct MainContentRepresentable: NSViewControllerRepresentable {
    let router: AppRouter
    let theme: ThemeTokens
    var hidesMail = false
    let onMake: ((MainContentViewController) -> Void)?

    func makeNSViewController(context: Context) -> MainContentViewController {
        let controller = MainContentViewController(router: router, theme: theme)
        controller.showsDateGroups = true
        controller.view.isHidden = hidesMail
        onMake?(controller)
        return controller
    }

    func updateNSViewController(_ controller: MainContentViewController, context: Context) {
        controller.apply(theme: theme)
        guard controller.view.isHidden != hidesMail else { return }
        // Why: AppKit would pass a hidden first responder's place to the next key view (the Calendar's Meet field)
        if hidesMail, let window = controller.view.window, let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: controller.view) {
            window.makeFirstResponder(nil)
        }
        controller.view.isHidden = hidesMail
    }
}

struct WindowHooks: NSViewRepresentable {
    let theme: ResolvedTheme
    let router: AppRouter

    func makeNSView(context: Context) -> WindowHookView {
        WindowHookView(theme: theme, router: router)
    }

    func updateNSView(_ view: WindowHookView, context: Context) {
        view.theme = theme
        view.applyToWindow()
    }
}

final class WindowHookView: NSView {
    var theme: ResolvedTheme
    let router: AppRouter
    private var tracker: WindowPlaceTracker?
    private var chromeObservers: [any NSObjectProtocol] = []

    init(theme: ResolvedTheme, router: AppRouter) {
        self.theme = theme
        self.router = router
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyToWindow()
    }

    func applyToWindow() {
        guard let window else { return }
        // Claim the frame name once, when the view reaches a window; re-claiming would steal it from a window whose name was cleared
        let reachedWindow = tracker?.window !== window
        MainWindowHooks.configure(window, theme: theme, restoreFrame: reachedWindow)
        if reachedWindow {
            tracker = WindowPlaceTracker(window: window, router: router)
            observeZoomState(of: window)
        }
        WindowZoomMenuState.shared.refresh(from: window)
    }

    private func observeZoomState(of window: NSWindow) {
        for observer in chromeObservers { NotificationCenter.default.removeObserver(observer) }
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
        ]
        chromeObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { WindowZoomMenuState.shared.refresh(from: self?.window) }
            }
        }
    }

    isolated deinit {
        for observer in chromeObservers { NotificationCenter.default.removeObserver(observer) }
    }
}

@MainActor
public enum MainWindowHooks {
    public static let frameAutosaveName = "dev.openhuman.mail.main"

    /// Follows the theme's light or dark appearance and remembers the frame. The title bar, toolbar and window
    /// background stay the system's.
    public static func configure(_ window: NSWindow, theme: ResolvedTheme, restoreFrame: Bool = true) {
        window.applyThemeAppearance(theme)
        if restoreFrame, window.frameAutosaveName.isEmpty {
            window.setFrameUsingName(frameAutosaveName)
            window.setFrameAutosaveName(frameAutosaveName)
        }
    }
}
