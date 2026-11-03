import Foundation
import MailActions
import MailModel
import Observation

@MainActor @Observable
public final class ActionRegistry {
    public private(set) var descriptors: [ActionDescriptor] = []
    public private(set) var enabledModules: [FeatureModuleID] = []
    public private(set) var keymap: Keymap = .defaults
    public private(set) var defaultDescriptors: [ActionDescriptor] = []
    public private(set) var keymapRevision = 0
    public private(set) var performCount = 0

    @ObservationIgnored public weak var presenter: (any ActionPresenting)?
    @ObservationIgnored public let recents: RecentActions
    @ObservationIgnored public private(set) lazy var palette = CommandPaletteModel(registry: self)
    @ObservationIgnored public var didPerform: ((ActionID, ActionSource) -> Void)?
    @ObservationIgnored public var onRefused: ((ActionID, DisabledReason) -> Void)?
    @ObservationIgnored public var performedObservers: [String: (ActionID, ActionContext) -> Void] = [:]
    @ObservationIgnored public internal(set) var shortcutHints: ShortcutLearning?
    @ObservationIgnored public private(set) var lastTask: Task<Void, Never>?

    @ObservationIgnored var core: CoreActions?
    @ObservationIgnored private var handlers: [ActionID: any ActionHandler] = [:]
    @ObservationIgnored private var index: [ActionID: Int] = [:]
    @ObservationIgnored private var registeredModules: [FeatureModuleID: [ActionID]] = [:]
    @ObservationIgnored private var extraDescriptors: [ActionDescriptor] = []
    @ObservationIgnored private var userKeymap = KeymapOverrides()
    @ObservationIgnored private var rebuildCount = 0

    public init(recents: RecentActions = RecentActions()) {
        self.recents = recents
        rebuild()
    }

    public func register(_ handler: any ActionHandler, for ids: [ActionID]) {
        for id in ids { handlers[id] = handler }
    }

    public func register(_ descriptors: [ActionDescriptor], handler: any ActionHandler, module: FeatureModuleID?) {
        var changed = false
        for descriptor in descriptors {
            handlers[descriptor.id] = handler
            if ActionCatalog.descriptor(descriptor.id) == nil, !extraDescriptors.contains(where: { $0.id == descriptor.id }) {
                extraDescriptors.append(descriptor)
                changed = true
            }
        }
        if let module {
            let known = registeredModules[module]
            let added = descriptors.map(\.id).filter { !(known ?? []).contains($0) }
            if known == nil || !added.isEmpty {
                registeredModules[module] = (known ?? []) + added
                if !enabledModules.contains(module) { enabledModules.append(module) }
                changed = true
            }
        }
        // Why: observers of the registry would redraw for nothing, and a redraw that registers again never ends
        if changed { rebuild() }
    }

    public func noteEnabled(_ module: FeatureModuleID) {
        guard !enabledModules.contains(module) else { return }
        enabledModules.append(module)
    }

    public func applyKeymap(_ overrides: KeymapOverrides) {
        userKeymap = overrides
        rebuild()
    }

    public var userKeymapOverrides: KeymapOverrides { userKeymap }

    public func descriptor(_ id: ActionID) -> ActionDescriptor? { index[id].map { descriptors[$0] } }

    public func contains(_ id: ActionID) -> Bool { index[id] != nil }

    public func descriptors(in category: ActionCategory) -> [ActionDescriptor] {
        descriptors.filter { $0.category == category }
    }

    public func handler(for id: ActionID) -> (any ActionHandler)? { handlers[id] }

    public func availability(_ id: ActionID, host: (any ActionHost)?, context: ActionContext? = nil) -> ActionAvailability {
        guard let descriptor = descriptor(id), let handler = handlers[id] else { return .hidden }
        let context = context ?? host?.actionContext() ?? ActionContext()
        let rules = ActionRules.availability(descriptor, in: context)
        guard rules == .enabled else { return rules }
        return handler.availability(of: id, in: context, host: host)
    }

    @discardableResult
    public func perform(_ id: ActionID, source: ActionSource, host: (any ActionHost)?,
                        context: ActionContext? = nil) -> Bool {
        let given = context
        var context = context ?? host?.actionContext() ?? ActionContext()
        switch availability(id, host: host, context: context) {
        case .hidden:
            return false
        case .disabled(let reason):
            guard reason.announces else { return false }
            onRefused?(id, reason)
            return true
        case .enabled:
            break
        }
        if let descriptor = descriptor(id), CalendarWindowActions.stepAside(for: descriptor, host: host), given == nil {
            context = host?.actionContext() ?? context
        }
        guard let handler = handlers[id] else { return false }
        let request = ActionRequest(id: id, context: context, source: source, host: host)
        switch handler.perform(request) {
        case .notHandled:
            return false
        case .done:
            lastTask = nil
        case .started(let task):
            lastTask = task
        }
        performCount += 1
        if source == .palette { recents.record(id) }
        didPerform?(id, source)
        for observer in performedObservers.values { observer(id, context) }
        shortcutHints?.performed(id, source: source, descriptor: descriptor(id), context: context)
        return true
    }

    @discardableResult
    public func run(_ id: ActionID, source: ActionSource, host: (any ActionHost)?,
                    context: ActionContext? = nil) async -> Bool {
        lastTask = nil
        let handled = perform(id, source: source, host: host, context: context)
        await lastTask?.value
        return handled
    }

    // Why: reads no observed property, so a rebuild inside a view's body can't make that body depend on what it writes
    private func rebuild() {
        let enabled = Set(registeredModules.values.joined())
        let base = ActionCatalog.all.filter { descriptor in
            descriptor.module == nil || enabled.contains(descriptor.id)
        } + extraDescriptors
        let resolved = Keymap.resolve(userKeymap, descriptors: base)
        let applied = resolved.apply(to: base)
        keymap = resolved
        defaultDescriptors = base
        descriptors = applied
        index = Dictionary(uniqueKeysWithValues: applied.enumerated().map { ($1.id, $0) })
        rebuildCount += 1
        keymapRevision = rebuildCount
    }
}
