import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore

@MainActor
public protocol OverlayFocusKeeping: AnyObject {
    func overlayChanged(showing: Bool)
    func overlayAppeared()
    func overlayDisappeared()
}

extension OverlayFocusKeeping {
    public func overlayAppeared() {}
    public func overlayDisappeared() {}
}

@MainActor @Observable
public final class OverlayCenter: ActionPresenting {
    public enum Overlay {
        case none
        case palette(PaletteController)
        case shortcuts(ShortcutHelpModel)
        case time(TimePickerModel)
        case label(LabelPickerModel)
        case zero(GetMeToZeroModel)
        case ask(AskModel)
        case batchSend(BatchSendModel)
    }

    private var stored: Overlay = .none
    public var overlay: Overlay {
        get {
            if case .palette(let palette) = stored, !palette.isOpen { return .none }
            return stored
        }
        set {
            if case .ask(let shown) = stored {
                if case .ask(let next) = newValue, next === shown {} else { shown.panelClosed() }
            }
            stored = newValue
            if case .none = newValue {} else { showing += 1 }
            focusKeeper?.overlayChanged(showing: isShowing)
        }
    }
    public private(set) var showing = 0
    public let search: SearchModel
    @ObservationIgnored public weak var focusKeeper: (any OverlayFocusKeeping)?
    @ObservationIgnored public weak var fallback: (any ActionPresenting)?
    @ObservationIgnored public var timeZone: TimeZone = .current
    @ObservationIgnored public var locale: Locale = .current
    public var timeDefaults: TimeDefaults {
        get { timeDefaultsOverride ?? environment.reminderTimes.defaults }
        set { timeDefaultsOverride = newValue }
    }
    @ObservationIgnored public var now: @Sendable () -> Date = { Date() }

    @ObservationIgnored public let moveToSuperset: StoredSetting<Bool>

    @ObservationIgnored private unowned let environment: AppEnvironment
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var timeDefaultsOverride: TimeDefaults?
    @ObservationIgnored private var recentMoveLabels: [AccountID: [Int64]] = [:]

    public init(environment: AppEnvironment, router: AppRouter, searchStore: any RecentSearchesStoring) {
        self.environment = environment
        self.moveToSuperset = StoredSetting(AppSettings.moveToSuperset, port: environment.settings)
        self.search = SearchModel(router: router, store: searchStore)
        environment.actions.register(SearchGmailActionHandler(search: search), for: [.searchGmail])
        environment.actions.register(AllInboxesActionHandler(router: router), for: [.goAllInboxes])
        _ = environment.reminderTimes
        moveToSuperset.start()
    }

    private var router: AppRouter { environment.router }
    private var registry: ActionRegistry { environment.actions }

    public func overlayAppeared() { focusKeeper?.overlayAppeared() }
    public func overlayDisappeared() { focusKeeper?.overlayDisappeared() }

    public var isShowing: Bool {
        if case .none = overlay { false } else { true }
    }

    private static let ownKinds: Set<ActionPresentation.Kind> = [.palette, .shortcutHelp, .search, .labelPicker,
                                                                  .snoozePicker, .remindPicker, .getMeToZero]

    public func canPresent(_ kind: ActionPresentation.Kind) -> Bool {
        if kind == .askInbox { return environment.ai != nil }
        return Self.ownKinds.contains(kind) || fallback?.canPresent(kind) == true
    }

    public func present(_ presentation: ActionPresentation) {
        switch presentation {
        case .palette:
            showPalette()
        case .shortcutHelp:
            overlay = .shortcuts(ShortcutHelpModel(descriptors: registry.descriptors))
        case .search:
            dismiss()
            // All Inboxes has its own field; the account's search would open out of sight behind it
            if let unified = router.unifiedInbox {
                unified.requestSearchFocus()
                return
            }
            search.open()
        case .labelPicker(let targets, let mode):
            showLabelPicker(targets: targets, mode: mode)
        case .snoozePicker(let targets):
            showSnoozePicker(targets: targets)
        case .remindPicker(let thread):
            showRemindPicker(thread: thread)
        case .getMeToZero(let account):
            showGetMeToZero(account: account)
        case .compose, .openURL:
            fallback?.present(presentation)
        case .askInbox(let question):
            showAsk(question: question)
        }
    }

    private func showGetMeToZero(account: AccountID) {
        let model = GetMeToZeroModel(account: account, now: now) { [weak self] keys in
            guard let self else { return }
            self.overlay = .none
            let environment = self.environment
            Task { await BulkArchive.archive(keys, account: account, environment: environment) }
        }
        overlay = .zero(model)
        let data = environment.data
        loadTask?.cancel()
        loadTask = Task { await model.load(from: data) }
    }

    public func dismiss() {
        loadTask?.cancel()
        switch overlay {
        case .palette(let palette): palette.model.close()
        case .time(let model): model.close()
        case .label(let model): model.close()
        case .zero(let model): model.close()
        case .batchSend(let model): model.close()
        case .shortcuts, .ask, .none: break
        }
        overlay = .none
    }

    private func showPalette() {
        let model = registry.palette
        if !model.isOpen { model.open(host: router) }
        overlay = .palette(PaletteController(model: model, router: router, timeZone: timeZone, locale: locale, now: now,
                                             timeDefaults: timeDefaults) { [weak self] in
            self?.overlay = .none
        })
    }

    private func showAsk(question: String?) {
        guard let model = environment.ai?.ask else { return }
        if isShowing { dismiss() }
        overlay = .ask(model)
        model.presented(question: question) { [weak self] in self?.dismiss() }
    }

    private func context(for targets: [ThreadKey], focused: ThreadKey? = nil) -> ActionContext {
        var c = router.contentContext()
        c.selection = targets
        c.focusedThread = focused ?? targets.first
        c.account = targets.first?.account ?? c.account
        return c
    }

    private func makeTimePicker(kind: TimePickerKind, targets: [ThreadKey],
                                perform: @escaping @MainActor (TimeChoice) -> Void) -> TimePickerModel {
        let model = TimePickerModel(kind: kind, targets: targets, presets: TimePresets(timeZone: timeZone, defaults: timeDefaults),
                                    locale: locale, now: now) { [weak self] choice in
            self?.overlay = .none
            perform(choice)
        }
        overlay = .time(model)
        let data = environment.data
        loadTask?.cancel()
        loadTask = Task { await model.load(from: data) }
        return model
    }

    private func showSnoozePicker(targets: [ThreadKey]) {
        guard !targets.isEmpty else { return }
        let registry = self.registry
        let router = self.router
        var context = context(for: targets)
        context.targets.anySnoozed = true
        _ = makeTimePicker(kind: .snooze, targets: targets) { choice in
            switch choice {
            case .at(let date, _):
                registry.threadActions?.snooze(targets, until: date, host: router)
            case .wakeNow:
                registry.perform(.unsnooze, source: .palette, host: router, context: context)
            case .clearReminder:
                break
            }
        }
    }

    private func showRemindPicker(thread: ThreadKey) {
        let registry = self.registry
        let router = self.router
        var context = context(for: [thread], focused: thread)
        context.targets.anyReminder = true
        _ = makeTimePicker(kind: .remind, targets: [thread]) { choice in
            switch choice {
            case .at(let date, let kind):
                registry.threadActions?.remind(thread, at: date, kind: kind, host: router)
            case .clearReminder:
                registry.perform(.clearReminder, source: .palette, host: router, context: context)
            case .wakeNow:
                break
            }
        }
    }

    public func presentSendLater(draftTargets: [ThreadKey] = [], schedule: @escaping @MainActor (Date) -> Void) {
        presentSendLater(draftTargets: draftTargets, scheduleWithCondition: { date, _ in schedule(date) })
    }

    public func presentSendLater(draftTargets: [ThreadKey] = [], condition: SendLaterCondition = .always,
                                 scheduleWithCondition schedule: @escaping @MainActor (Date, SendLaterCondition) -> Void) {
        let model = makeTimePicker(kind: .sendLater, targets: draftTargets) { choice in
            if case .at(let date, let kind) = choice { schedule(date, kind == .ifNoReply ? .ifNoReply : .always) }
        }
        model.onlyIfNoReply = condition == .ifNoReply
    }

    public func presentBatchSend(_ model: BatchSendModel) {
        if isShowing { dismiss() }
        overlay = .batchSend(model)
    }

    public func presentDraftReminder(thread: ThreadKey?, current: ComposeSession.PendingReminder?,
                                     choose: @escaping @MainActor (ComposeSession.PendingReminder?) -> Void) {
        let registry = self.registry
        let router = self.router
        let targets = thread.map { [$0] } ?? []
        var context = context(for: targets, focused: thread)
        context.targets.anyReminder = true
        let model = makeTimePicker(kind: .remind, targets: targets) { choice in
            switch choice {
            case .at(let date, let kind):
                choose(ComposeSession.PendingReminder(dueAt: date, kind: kind))
            case .clearReminder:
                choose(nil)
                if thread != nil { registry.perform(.clearReminder, source: .palette, host: router, context: context) }
            case .wakeNow:
                break
            }
        }
        model.onlyIfNoReply = (current?.kind ?? .ifNoReply) == .ifNoReply
    }

    private func showLabelPicker(targets: [ThreadKey], mode: LabelPickerMode) {
        let router = self.router
        let registry = self.registry
        let account = targets.first?.account ?? router.active?.id
        let state = router.accounts.first { $0.id == account } ?? router.active
        let context = context(for: targets)
        let actions = LabelPickerActions(
            setLabels: { add, remove in registry.threadActions?.setLabels(targets, add: add, remove: remove, host: router) },
            move: { label in registry.threadActions?.move(targets, to: label, host: router) },
            create: { name in
                guard let account else { return }
                registry.threadActions?.createLabel(named: name, account: account, applyTo: targets, host: router)
            },
            navigate: { label in router.go(to: .label(label.labelID)) },
            moveToPlace: { place in registry.threadActions?.moveToPlace(place, context: context, host: router) },
            moveToSplit: { split, label in
                registry.threadActions?.moveToSplit(targets, split: split, label: label, host: router)
            },
            addSenderToSplit: { split, sender in
                guard let core = registry.superhumanCore else { return }
                Task { await core.addToSplit(sender, into: split.id, account: split.account) }
            })
        let wrapped = LabelPickerActions(
            setLabels: { [weak self] a, r in self?.overlay = .none; actions.setLabels(a, r) },
            move: { [weak self] l in
                self?.overlay = .none
                if let account { self?.noteMoved(to: l, account: account) }
                actions.move(l)
            },
            create: { [weak self] n in self?.overlay = .none; actions.create(n) },
            navigate: { [weak self] l in self?.overlay = .none; actions.navigate(l) },
            moveToPlace: { [weak self] p in self?.overlay = .none; actions.moveToPlace(p) },
            moveToSplit: { [weak self] s, l in self?.overlay = .none; actions.moveToSplit(s, l) },
            addSenderToSplit: { [weak self] s, c in self?.overlay = .none; actions.addSenderToSplit(s, c) })
        let rows = router.unifiedInbox?.threadRows(for: targets) ?? state?.list?.rows ?? []
        let labels = environment.superhumanLabels.visible(state?.labels ?? [])
        let move = mode == .move && moveToSuperset.value
            ? moveOptions(targets: targets, account: account, splits: state?.splits ?? [], context: context) : nil
        overlay = .label(LabelPickerModel(mode: mode, targets: targets, account: account, labels: labels,
                                          targetRows: rows, actions: wrapped, move: move))
    }

    private func moveOptions(targets: [ThreadKey], account: AccountID?, splits: [SplitInfo],
                             context: ActionContext) -> MoveOptions {
        let registry = self.registry
        let router = self.router
        let places = MoveToSuperset.places(targets: targets) { id in
            registry.availability(id, host: router, context: context)
        }
        let sender = targets.count == 1 && registry.superhumanCore != nil
            ? AddToSplit.choices(for: targets[0], router: router).first { $0.kind == .sender } : nil
        return MoveOptions(places: places, splits: splits, sender: sender,
                           recentLabelIDs: account.flatMap { recentMoveLabels[$0] } ?? [])
    }

    private func noteMoved(to label: LabelInfo, account: AccountID) {
        recentMoveLabels[account] = MoveToSuperset.noting(label.id, in: recentMoveLabels[account] ?? [])
    }
}

@MainActor
final class SearchGmailActionHandler: ActionHandler {
    private weak var search: SearchModel?

    init(search: SearchModel) {
        self.search = search
    }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        search?.canSearchGmail == true ? .enabled : .hidden
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let search, search.canSearchGmail else { return .notHandled }
        search.searchGmail()
        return .done
    }
}
