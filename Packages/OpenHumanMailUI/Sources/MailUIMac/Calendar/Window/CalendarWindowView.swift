import AppKit
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI

public struct CalendarWindowView: View {
    @Bindable var model: CalendarWindowModel
    let router: AppRouter
    @Environment(\.theme) private var theme

    static let tickInterval: Duration = .seconds(15)

    public init(model: CalendarWindowModel, router: AppRouter) {
        self.model = model
        self.router = router
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                CalendarWindowHeader(model: model)
                Group {
                    if model.kind == .month {
                        CalendarMonthView(model: model)
                    } else {
                        CalendarTimeGridView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlayPreferenceValue(CalendarPopoverAnchorKey.self) { anchor in
                    GeometryReader { proxy in
                        CalendarPopoverLayer(model: model, target: anchor.map { proxy[$0] }, bounds: proxy.size)
                    }
                }
            }
            CalendarRightPanel(model: model, router: router)
        }
        .background(theme.bgWindow.color)
        .overlay { if let question = model.scopeQuestion { scopeQuestion(question) } }
        .overlay { if let question = model.removeQuestion { removeQuestion(question) } }
        .environment(\.timeZone, model.timeZone)
        .onAppear {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .task(id: model.isOpen) {
            guard model.isOpen else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard !Task.isCancelled else { return }
                await model.tick()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await model.windowDidBecomeKey() }
        }
        .onChange(of: modalComposerOpen) {
            if modalComposerOpen { Task { await model.close() } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar")
        .accessibilityIdentifier("calendar.window")
    }

    private var modalComposerOpen: Bool {
        guard let session = router.environment.composeIfStarted?.windowSession else { return false }
        return session.isOpen && session.placement == .modal
    }

    private func removeQuestion(_ question: CalendarRemoveQuestion) -> some View {
        CalendarRemovalQuestionView(model: model, question: question)
    }

    private func scopeQuestion(_ question: CalendarScopeQuestion) -> some View {
        editScopeQuestion(question)
    }

    private func editScopeQuestion(_ question: CalendarScopeQuestion) -> some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
                .onTapGesture { Task { await model.escape() } }
            VStack(alignment: .leading, spacing: theme.space4) {
                Text(question.text).themeFont(theme.typeBody).foregroundStyle(theme.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: theme.space3) {
                    Spacer(minLength: 0)
                    Button("Cancel") { Task { await model.escape() } }
                        .keyboardShortcut(.cancelAction)
                    if question.action == .save, model.card?.form != nil {
                        ForEach(question.scopes, id: \.self) { scope in
                            Button(scope.title) { Task { await model.answerRecurrenceScope(scope) } }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("calendar.scope.\(scope.rawValue)")
                        }
                    } else {
                        Button("All events") { Task { await model.answerScope(.allEvents) } }
                            .accessibilityIdentifier("calendar.scope.all")
                        Button("This event") { Task { await model.answerScope(.thisEvent) } }
                            .buttonStyle(.borderedProminent).tint(theme.accentFill.color)
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("calendar.scope.this")
                    }
                }
            }
            .padding(theme.space5)
            .frame(width: 460)
            .calendarDialogChrome()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("calendar.scopeQuestion")
        }
    }
}

struct CalendarRemovalQuestionView: View {
    @Bindable var model: CalendarWindowModel
    let question: CalendarRemoveQuestion
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
                .onTapGesture { Task { await model.escape() } }
            VStack(alignment: .leading, spacing: theme.space4) {
                Text(question.text).themeFont(theme.typeBody).foregroundStyle(theme.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = question.note {
                    Text(note).themeFont(theme.typeBody).foregroundStyle(theme.textDanger.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("calendar.remove.note")
                }
                if question.isRecurring {
                    VStack(alignment: .leading, spacing: theme.space3) {
                        ForEach(CalendarRecurrenceScope.removalOptions, id: \.self) { scope in
                            Button(scope.removalTitle, role: .destructive) {
                                Task { await model.confirmRemove(scope, questionID: question.id) }
                            }
                            .buttonStyle(.bordered)
                            .disabled(!question.availableScopes.contains(scope))
                            .accessibilityIdentifier(Self.identifier(scope))
                        }
                    }
                }
                HStack(spacing: theme.space3) {
                    Spacer(minLength: 0)
                    Button("Cancel") { Task { await model.escape() } }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("calendar.remove.cancel")
                    if !question.isRecurring {
                        Button(question.confirmTitle, role: .destructive) {
                            Task { await model.confirmRemove(.thisEvent, questionID: question.id) }
                        }
                            .buttonStyle(.borderedProminent).tint(theme.textDanger.color)
                            .accessibilityIdentifier("calendar.remove.confirm")
                    }
                }
            }
            .padding(theme.space5)
            .frame(maxWidth: 420)
            .calendarDialogChrome()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("calendar.removeQuestion")
        }
    }

    static func identifier(_ scope: CalendarRecurrenceScope) -> String {
        switch scope {
        case .thisEvent: "calendar.scope.this"
        case .allEvents: "calendar.scope.all"
        case .thisAndFollowing: "calendar.scope.future"
        }
    }
}

// The period in large type, as in the system Calendar, with Previous, Today and Next beside it. The view switch,
// New event and Refresh are in the window's toolbar.
struct CalendarWindowHeader: View {
    @Bindable var model: CalendarWindowModel
    @Environment(\.theme) private var theme

    static let height: CGFloat = 48

    var body: some View {
        HStack(alignment: .center, spacing: theme.space4) {
            Text(model.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("calendar.window.title")
            if let progress = model.progress {
                HStack(spacing: theme.space2) {
                    ProgressView().controlSize(.mini)
                    Text(progress.text).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("calendar.window.updating")
            }
            Spacer(minLength: theme.space3)
            ControlGroup {
                Button { Task { await model.move(by: -1) } } label: {
                    Label("Previous", systemImage: "chevron.left").labelStyle(.iconOnly)
                }
                .help("Previous  −  K")
                .accessibilityIdentifier("calendar.window.previous")
                Button { Task { await model.goToToday() } } label: {
                    Text("Today")
                }
                .help("Today  T")
                .accessibilityIdentifier("calendar.window.today")
                Button { Task { await model.move(by: 1) } } label: {
                    Label("Next", systemImage: "chevron.right").labelStyle(.iconOnly)
                }
                .help("Next  =  J")
                .accessibilityIdentifier("calendar.window.next")
            }
            .fixedSize()
            .accessibilityIdentifier("calendar.window.navigation")
        }
        .padding(.horizontal, theme.space6)
        .frame(height: Self.height)
    }
}

extension View {
    // A question over the calendar: the popover's surface, corner and shadow
    func calendarDialogChrome() -> some View {
        modifier(CalendarDialogChrome())
    }
}

private struct CalendarDialogChrome: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CalendarPopoverPlacement.cornerRadius, style: .continuous)
        content
            .background(shape.fill(theme.component.popover.bg.color).themeShadow(theme.component.popover.shadow))
            .overlay(shape.strokeBorder(theme.component.popover.border.color, lineWidth: theme.borderWidthHairline))
    }
}
