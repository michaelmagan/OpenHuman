import MailFeatures
import MailModel
import MailTheme
import MailUI
import SwiftUI

struct PhoneShell: View {
    @State private var phone: PhoneMail
    @Environment(\.touch) private var theme
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(environment: AppEnvironment) {
        _phone = State(initialValue: PhoneMail(environment: environment))
    }

    var body: some View {
        @Bindable var phone = phone
        ZStack(alignment: .bottom) {
            theme.window.ignoresSafeArea()
            NavigationStack(path: $phone.path) {
                InboxScreen(phone: phone)
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: PhoneMail.Route.self) { _ in
                        ConversationScreen(phone: phone)
                            .toolbar(.hidden, for: .navigationBar)
                    }
            }
            if phone.reader == nil {
                BottomChrome(phone: phone)
                    .transition(reduceMotion ? AnyTransition.opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            ToastHost(phone: phone)
        }
        .animation(.snappy(duration: 0.25), value: phone.reader == nil)
        .sheet(item: composerBinding) { session in
            ComposeSheet(phone: phone, session: session)
        }
        .sheet(item: $phone.remindTarget) { target in
            RemindSheet(phone: phone, target: target)
                .presentationDetents([.medium, .large])
                .presentationBackground(theme.window)
        }
        .sheet(isPresented: $phone.showsSearch) {
            SearchSheet(phone: phone)
                .presentationBackground(theme.window)
        }
        .sheet(isPresented: $phone.showsMailboxes) {
            MailboxesSheet(phone: phone)
                .presentationDetents([.medium, .large])
                .presentationBackground(theme.sidebar)
        }
        .sheet(isPresented: $phone.showsSettings) {
            SettingsSheet(phone: phone)
        }
        .confirmationDialog("This link may not go where it says", isPresented: linkWarningShown,
                            titleVisibility: .visible, presenting: phone.linkWarning) { warning in
            Button("Open \(warning.actual)") { phone.followNow(warning.url) }
            Button("Cancel", role: .cancel) { phone.linkWarning = nil }
        } message: { warning in
            Text("It shows \(warning.shown) but opens \(warning.actual).")
        }
        .task {
            phone.openExternal = { url in openURL(url) }
            phone.start()
            #if DEBUG || OH_DEV_TOOLS
            if let screen = PhoneLaunchScreen.current() { await phone.show(screen) }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { phone.router.persist() }
        }
        .onChange(of: theme.resolved, initial: true) { _, resolved in
            phone.useTheme(resolved.tokens, appearance: resolved.appearance)
        }
    }

    private var composerBinding: Binding<ComposeSession?> {
        Binding(get: { phone.composer }, set: { value in
            if value == nil, let session = phone.composer { phone.closeComposer(session) }
        })
    }

    private var linkWarningShown: Binding<Bool> {
        Binding(get: { phone.linkWarning != nil }, set: { if !$0 { phone.linkWarning = nil } })
    }
}

struct ToastHost: View {
    let phone: PhoneMail
    @Environment(\.touch) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: theme.tokens.component.toast.gap) {
            ForEach(phone.notices.toasts) { toast in
                ToastPill(toast: toast) { phone.activate(toast) }
                    .transition(reduceMotion ? AnyTransition.opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, theme.tokens.space4)
        .padding(.bottom, phone.reader == nil ? phone.chromeHeight + theme.tokens.space3 : phone.readerBarHeight + theme.tokens.space3)
        .animation(.snappy(duration: 0.25), value: phone.notices.toasts.map(\.id))
        .onAppear { phone.notices.timing = ToastTiming(theme: theme.tokens) }
        .onChange(of: phone.notices.toasts.map(\.id)) { old, new in
            let added = Set(new).subtracting(old)
            for toast in phone.notices.toasts where added.contains(toast.id) {
                AccessibilityNotification.Announcement(Self.spoken(toast)).post()
            }
        }
    }

    static func spoken(_ toast: Toast) -> String {
        toast.actionTitle.map { "\(toast.message). \($0) is available." } ?? toast.message
    }
}

struct ToastPill: View {
    let toast: Toast
    let action: () -> Void
    @Environment(\.touch) private var theme

    var body: some View {
        HStack(spacing: theme.tokens.space4) {
            Text(toast.message)
                .font(theme.bodyStrong)
                .foregroundStyle(toast.style == .error ? theme.toastDanger : theme.toastText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let title = toast.actionTitle {
                Button(title, action: action)
                    .font(theme.bodyStrong)
                    .foregroundStyle(theme.toastAction)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("toast.action")
            }
        }
        .padding(.horizontal, theme.tokens.space5)
        .padding(.vertical, theme.tokens.space2)
        .frame(minHeight: 48)
        .background(Capsule().fill(theme.toastBackground))
        .themeShadow(theme.tokens.shadow2)
        .accessibilityElement(children: .contain)
    }
}
