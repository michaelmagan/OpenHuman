import Foundation
import MailActions
import MailModel
import Observation
import Testing
@testable import MailFeatures

@MainActor
@Suite struct ActionRegistryObservationTests {
    private final class Count: @unchecked Sendable { var value = 0 }

    private final class Handler: ActionHandler {
        func perform(_ request: ActionRequest) -> ActionPerformance { .done }
    }

    private let extra = ActionDescriptor(ActionID("test.extra"), "Extra", category: .view)

    private func watch(_ registry: ActionRegistry) -> Count {
        let changes = Count()
        withObservationTracking {
            _ = (registry.descriptors, registry.defaultDescriptors, registry.keymap, registry.keymapRevision)
            _ = registry.enabledModules
        } onChange: { changes.value += 1 }
        return changes
    }

    @Test func registeringNothingLeavesObserversAlone() {
        let registry = ActionRegistry()
        let revision = registry.keymapRevision
        let changes = watch(registry)
        registry.register([], handler: Handler(), module: nil)
        #expect(changes.value == 0 && registry.keymapRevision == revision)
    }

    @Test func aCatalogDescriptorOnlyChangesItsHandler() throws {
        let registry = ActionRegistry()
        let revision = registry.keymapRevision
        let descriptor = try #require(ActionCatalog.descriptor(.themeDark))
        let handler = Handler()
        let changes = watch(registry)
        registry.register([descriptor], handler: handler, module: nil)
        #expect(changes.value == 0 && registry.keymapRevision == revision)
        #expect(registry.handler(for: .themeDark) === handler)
    }

    @Test func aNewDescriptorRebuildsOnceAndRepeatingItDoesNot() {
        let registry = ActionRegistry()
        let revision = registry.keymapRevision
        let first = Handler()
        registry.register([extra], handler: first, module: nil)
        #expect(registry.keymapRevision == revision + 1)
        #expect(registry.contains(extra.id))
        #expect(registry.handler(for: extra.id) === first)

        let second = Handler()
        let changes = watch(registry)
        registry.register([extra], handler: second, module: nil)
        #expect(changes.value == 0 && registry.keymapRevision == revision + 1)
        #expect(registry.descriptors.filter { $0.id == extra.id }.count == 1)
        #expect(registry.handler(for: extra.id) === second, "a repeat still takes the newest handler")
    }

    @Test func aModuleRebuildsOnlyForWhatItAdds() throws {
        let gated = ActionCatalog.all.filter { $0.module == .snooze }
        try #require(gated.count >= 2)
        let registry = ActionRegistry()
        #expect(!registry.contains(gated[0].id), "a module's actions stay out until it registers")
        let start = registry.keymapRevision

        registry.register([gated[0]], handler: Handler(), module: .snooze)
        #expect(registry.keymapRevision == start + 1)
        #expect(registry.contains(gated[0].id) && registry.enabledModules == [.snooze])

        let changes = watch(registry)
        registry.register([gated[0]], handler: Handler(), module: .snooze)
        #expect(changes.value == 0 && registry.keymapRevision == start + 1)

        registry.register(gated, handler: Handler(), module: .snooze)
        #expect(changes.value == 1, "the second action is new")
        #expect(registry.keymapRevision == start + 2)
        #expect(gated.allSatisfy { registry.contains($0.id) })
        #expect(registry.enabledModules == [.snooze])
    }

    @Test func aModuleWithNoActionsStillRegisters() {
        let registry = ActionRegistry()
        let start = registry.keymapRevision
        registry.register([], handler: Handler(), module: .snooze)
        #expect(registry.enabledModules == [.snooze])
        #expect(registry.keymapRevision == start + 1)
        registry.register([], handler: Handler(), module: .snooze)
        #expect(registry.keymapRevision == start + 1)
    }

    @Test func aRebuildInATrackedScopeReadsNothingObserved() {
        let registry = ActionRegistry()
        let changes = Count()
        withObservationTracking { registry.register([extra], handler: Handler(), module: nil) } onChange: { changes.value += 1 }
        #expect(registry.contains(extra.id))
        registry.applyKeymap(KeymapOverrides())
        #expect(changes.value == 0)
    }

    @Test func aKeymapChangeStillBumpsTheRevisionAndTellsObservers() {
        let registry = ActionRegistry()
        let revision = registry.keymapRevision
        let changes = watch(registry)
        registry.applyKeymap(KeymapOverrides())
        #expect(changes.value == 1 && registry.keymapRevision == revision + 1)
    }
}
