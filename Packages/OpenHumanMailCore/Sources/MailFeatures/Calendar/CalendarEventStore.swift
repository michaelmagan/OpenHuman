import Foundation
import MailModel
import OpenHumanCore

public struct CalendarEventStoreChange: Sendable, Hashable {
    public let key: CalendarCacheKey
    public var inserted: Set<String> = []
    public var updated: Set<String> = []
    public var removed: Set<String> = []
    public var coverageChanged = false

    public init(key: CalendarCacheKey) { self.key = key }

    public var changedIDs: Set<String> { inserted.union(updated).union(removed) }
    public var isEmpty: Bool { changedIDs.isEmpty && !coverageChanged }
}

@MainActor
public final class CalendarEventStore {
    public typealias Key = CalendarCacheKey

    public static let daysBefore = 14
    public static let daysAfter = 45
    public static let adjacentDays = 30
    public static let prefetchMargin = 7
    public static let staleAfter: TimeInterval = 60
    public static let lowPowerStaleAfter: TimeInterval = 300
    public static let fullReadAfter: TimeInterval = 30 * 60
    public static let rangeLifetime: TimeInterval = 7 * 86_400
    public static let firstRetry: TimeInterval = 15
    public static let longestRetry: TimeInterval = 15 * 60
    public static let rateLimitPause: TimeInterval = 60
    public static let maxCoveredDays = 400

    public static let couldNotRefresh = String(localized: "Couldn't refresh. Showing saved events.")

    struct Slice {
        var records: [String: CalendarEventRecord] = [:]
        var ranges: [CalendarCoveredRange] = []
        var syncToken: String?
        var tokensUnsupported = false
        var lastRefresh: Date?
        var lastFullRead: Date?
        var failures = 0
        var retryAt: Date?
        var lastError: String?
        var provisional: Set<String> = []
    }

    private var slices: [Key: Slice] = [:]
    private var flights: [Key: (id: UUID, task: Task<Void, Never>, writes: Int)] = [:]
    private var generations: [Key: Int] = [:]
    private var localWrites: [Key: Int] = [:]
    public private(set) var ownAddresses: [String: Set<String>] = [:]
    private var observers: [UUID: @MainActor (CalendarEventStoreChange) -> Void] = [:]
    private let persistence: (any CalendarCachePersisting)?
    private var persistTail: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?

    public var timeZone: TimeZone
    public var isOffline: @MainActor () -> Bool = { false }
    public var isLowPower: @MainActor () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    public private(set) var networkReads = 0
    public private(set) var isRestored = false

    public init(persistence: (any CalendarCachePersisting)? = nil, timeZone: TimeZone = .current) {
        self.persistence = persistence
        self.timeZone = timeZone
        if persistence == nil { isRestored = true }
    }

    public nonisolated static func key(for provider: any CalendarProviding) -> Key { Key(provider: provider.info) }

    public func covers(_ key: Key, from: Date, to: Date) -> Bool {
        guard to > from, let slice = slices[key] else { return false }
        return Self.covers(slice.ranges, from: from, to: to)
    }

    public func events(_ key: Key, from: Date, to: Date, includeDeclined: Bool = false) -> [CalendarEvent]? {
        guard covers(key, from: from, to: to), let slice = slices[key] else { return nil }
        let zone = timeZone
        let mine = ownAddresses[key.account] ?? []
        return slice.records.values
            .filter { includeDeclined || !$0.declinedByMe }
            .map { record -> CalendarEvent in
                var event = record.materialized(in: zone).event
                if record.declinedByMe, event.myResponse == nil { event.myResponse = .declined }
                return event.resolvingMyResponse(addresses: mine)
            }
            .filter { includeDeclined || !Self.declinedAsAlias($0) }
            .filter { $0.overlaps(from: from, to: to) }
            .sorted(by: Self.soonestFirst)
    }

    // The account's own addresses by calendar account, so an answer given as an alias shows as the account's
    public func learnAddresses(of accounts: [Account]) {
        var known: [String: Set<String>] = [:]
        for account in accounts { known[account.email.lowercased()] = account.myAddresses }
        guard known != ownAddresses else { return }
        let before = ownAddresses
        ownAddresses = known
        for (key, slice) in slices where before[key.account] != known[key.account] && !slice.records.isEmpty {
            var change = CalendarEventStoreChange(key: key)
            change.updated = Set(slice.records.keys)
            notify(change)
        }
    }

    static func declinedAsAlias(_ event: CalendarEvent) -> Bool {
        event.respondsAs != nil && event.myResponse == .declined
    }

    public func busy(_ key: Key, from: Date, to: Date) -> [CalendarBusyInterval]? {
        guard covers(key, from: from, to: to), let slice = slices[key] else { return nil }
        let mine = ownAddresses[key.account] ?? []
        let blocks = slice.records.values
            .filter { $0.isBusy && !$0.event.isAllDay && !$0.declinedByMe
                && $0.event.overlaps(from: from, to: to)
                && !Self.declinedAsAlias($0.event.resolvingMyResponse(addresses: mine)) }
            .map { CalendarBusyInterval(start: max($0.event.start, from), end: min($0.event.end, to)) }
            .sorted { $0.start < $1.start }
        return Self.merged(blocks)
    }

    public func record(_ key: Key, id: String) -> CalendarEventRecord? { slices[key]?.records[id] }

    public func lastError(_ key: Key) -> String? { slices[key]?.lastError }

    public func isUpdating(_ key: Key) -> Bool { flights[key] != nil }

    public func syncToken(_ key: Key) -> String? { slices[key]?.syncToken }

    public func ranges(_ key: Key) -> [CalendarCoveredRange] { slices[key]?.ranges ?? [] }

    public var keys: [Key] { slices.keys.sorted() }

    public var refreshInterval: TimeInterval { isLowPower() ? Self.lowPowerStaleAfter : Self.staleAfter }

    @discardableResult
    public func observe(_ handler: @escaping @MainActor (CalendarEventStoreChange) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    public func stopObserving(_ id: UUID) { observers[id] = nil }

    public func restore(now: Date) async {
        if isRestored { return }
        if let restoreTask { return await restoreTask.value }
        let task = Task { @MainActor [weak self] in
            guard let self, let persistence = self.persistence else { return }
            let entries = await persistence.load()
            var kept = 0
            for entry in entries {
                var slice = Slice()
                slice.ranges = Self.normalized(entry.ranges.filter {
                    now.timeIntervalSince($0.fetchedAt) < Self.rangeLifetime && $0.fetchedAt <= now.addingTimeInterval(60)
                    && $0.end > $0.start
                })
                slice.syncToken = slice.ranges.isEmpty ? nil : entry.syncToken
                for record in entry.records where Self.overlapsAny(slice.ranges, record.event) {
                    slice.records[record.event.id] = record
                }
                slice.lastFullRead = nil
                let dropped = slice.records.count != entry.records.count || slice.ranges.count != entry.ranges.count
                if slice.ranges.isEmpty {
                    self.enqueue(.forgetCalendar(entry.key))
                    continue
                }
                if dropped {
                    self.enqueue(.replace(CalendarCacheEntry(key: entry.key, records: Array(slice.records.values),
                                                             ranges: slice.ranges, syncToken: slice.syncToken)))
                }
                guard self.slices[entry.key] == nil else { continue }
                self.slices[entry.key] = slice
                kept += slice.records.count
                var change = CalendarEventStoreChange(key: entry.key)
                change.inserted = Set(slice.records.keys)
                change.coverageChanged = true
                self.notify(change)
            }
            Log(.app).notice("calendar cache restored: \(self.slices.count) calendar(s), \(kept) event(s)")
        }
        restoreTask = task
        await task.value
        isRestored = true
        restoreTask = nil
    }

    public func retain(_ keep: Set<Key>) {
        for key in slices.keys where !keep.contains(key) { forget(key) }
    }

    public func forget(account: String) {
        let account = account.lowercased()
        for key in Set(slices.keys).union(flights.keys) where key.account == account { drop(key) }
        enqueue(.forgetAccount(account))
    }

    public func forget(_ key: Key) {
        drop(key)
        enqueue(.forgetCalendar(key))
    }

    public func forgetAll() {
        for key in Set(slices.keys).union(flights.keys) { drop(key) }
        enqueue(.forgetAll)
    }

    public func follow(_ states: AsyncStream<CalendarConnectionState>) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            for await state in states {
                guard let self else { return }
                if state.status == .disconnected, !state.account.isEmpty { self.forget(account: state.account) }
            }
        }
    }

    public func ensure(_ key: Key, provider: any CalendarProviding, from: Date, to: Date, today: Date,
                       calendar: Calendar, now: Date) async {
        guard !covers(key, from: from, to: to) else { return }
        let window = Self.window(from: from, to: to, today: today, calendar: calendar)
        await fill(key, provider: provider, window: window, now: now)
    }

    public func fill(_ key: Key, provider: any CalendarProviding, window: DateInterval, now: Date) async {
        while true {
            if let flight = flights[key] {
                await flight.task.value
                continue
            }
            let gaps = Self.gaps(in: window, ranges: slices[key]?.ranges ?? [])
            guard let first = gaps.first, let last = gaps.last else { return }
            await fly(key) { store in
                await store.readWindow(key, provider: provider, from: first.start, to: last.end, now: now)
            }
            return
        }
    }

    public func revalidate(_ key: Key, provider: any CalendarProviding, visible: DateInterval, today: Date,
                           calendar: Calendar, now: Date, force: Bool = false) async {
        if let flight = flights[key] {
            await flight.task.value
            // Why: a read that began before a save can bring the old version, so a forced refresh after it reads again
            guard force, localWrites[key, default: 0] > flight.writes, flights[key] == nil else { return }
        }
        if !force, !isDue(key, now: now) { return }
        let window = Self.window(from: visible.start, to: visible.end, today: today, calendar: calendar)
        await fly(key) { store in
            let current = store.slices[key]
            let fullDue = current?.lastFullRead.map { now.timeIntervalSince($0) >= Self.fullReadAfter || $0 > now } ?? true
            if let token = current?.syncToken, current?.tokensUnsupported != true, !fullDue {
                await store.readChanges(key, provider: provider, token: token, window: window, now: now)
            } else {
                await store.readWindow(key, provider: provider, from: window.start, to: window.end, now: now)
            }
        }
    }

    public func isDue(_ key: Key, now: Date) -> Bool {
        let slice = slices[key]
        if let last = slice?.lastRefresh, now.timeIntervalSince(last) >= 0,
           now.timeIntervalSince(last) < refreshInterval { return false }
        if let retry = slice?.retryAt, retry > now { return false }
        return !isOffline()
    }

    @discardableResult
    public func prefetchAdjacent(_ key: Key, provider: any CalendarProviding, around day: Date, calendar: Calendar,
                                 now: Date) -> Task<Void, Never>? {
        guard flights[key] == nil, let block = Self.block(containing: day, in: slices[key]?.ranges ?? []) else {
            return nil
        }
        let margin = TimeInterval(Self.prefetchMargin) * 86_400
        var span: DateInterval?
        if block.end.timeIntervalSince(day) < margin,
           let end = calendar.date(byAdding: .day, value: Self.adjacentDays, to: block.end) {
            span = DateInterval(start: block.end, end: end)
        } else if day.timeIntervalSince(block.start) < margin,
                  let start = calendar.date(byAdding: .day, value: -Self.adjacentDays, to: block.start) {
            span = DateInterval(start: start, end: block.start)
        }
        guard let span else { return nil }
        return Task(priority: .utility) { @MainActor [weak self] in
            await self?.fill(key, provider: provider, window: span, now: now)
        }
    }

    public func applyLocal(_ key: Key, upsert event: CalendarEvent, provisional: Bool = false) {
        guard !event.id.isEmpty else { return }
        var slice = slices[key] ?? Slice()
        var change = CalendarEventStoreChange(key: key)
        let record = Self.localRecord(event, replacing: slice.records[event.id], readIn: timeZone)
        Self.upsert(record, into: &slice, change: &change, local: true)
        if provisional { slice.provisional.insert(event.id) } else { slice.provisional.remove(event.id) }
        slices[key] = slice
        if !provisional { noteRemoteWrite(key) }
        if !provisional, !change.isEmpty { save(key, slice: slice, upserted: [record], removed: []) }
        notify(change)
    }

    // An answer to a whole series shows at once on the occurrences already read; the next read brings the calendar's own
    public func applyLocalResponse(_ key: Key, series: String, response: CalendarResponse) {
        noteRemoteWrite(key)
        guard !series.isEmpty, var slice = slices[key] else { return }
        var change = CalendarEventStoreChange(key: key)
        var upserted: [CalendarEventRecord] = []
        for record in Array(slice.records.values) where (record.recurringEventID ?? record.event.recurringEventID) == series {
            var answered = record
            answered.event.myResponse = response
            answered.declinedByMe = response == .declined
            Self.upsert(answered, into: &slice, change: &change, local: true)
            upserted.append(answered)
        }
        guard !upserted.isEmpty else { return }
        slices[key] = slice
        save(key, slice: slice, upserted: upserted, removed: [])
        notify(change)
    }

    // A write the store doesn't hold itself (a whole series): the next forced refresh reads again after a read under way
    public func noteRemoteWrite(_ key: Key) {
        localWrites[key, default: 0] += 1
    }

    public func replaceLocal(_ key: Key, id: String, with event: CalendarEvent) {
        var slice = slices[key] ?? Slice()
        var change = CalendarEventStoreChange(key: key)
        if slice.records.removeValue(forKey: id) != nil { change.removed.insert(id) }
        slice.provisional.remove(id)
        var upserted: [CalendarEventRecord] = []
        if !event.id.isEmpty {
            let record = Self.localRecord(event, replacing: slice.records[event.id], readIn: timeZone)
            Self.upsert(record, into: &slice, change: &change, local: true)
            upserted = [record]
            noteRemoteWrite(key)
        }
        slices[key] = slice
        if !upserted.isEmpty { save(key, slice: slice, upserted: upserted, removed: []) }
        notify(change)
    }

    public func removeLocal(_ key: Key, id: String) {
        guard var slice = slices[key], slice.records.removeValue(forKey: id) != nil else { return }
        let wasProvisional = slice.provisional.remove(id) != nil
        if !wasProvisional { noteRemoteWrite(key) }
        slices[key] = slice
        var change = CalendarEventStoreChange(key: key)
        change.removed = [id]
        if !wasProvisional { save(key, slice: slice, upserted: [], removed: [id]) }
        notify(change)
    }

    public func flush() async {
        await persistTail?.value
    }

    private func fly(_ key: Key, _ work: @escaping @MainActor @Sendable (CalendarEventStore) async -> Void) async {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await work(self)
            if self.flights[key]?.id == id { self.flights[key] = nil }
        }
        flights[key] = (id, task, localWrites[key, default: 0])
        await task.value
    }

    private func readWindow(_ key: Key, provider: any CalendarProviding, from: Date, to: Date, now: Date) async {
        networkReads += 1
        let generation = generations[key]
        do {
            let answer = try await provider.eventWindow(from: from, to: to)
            guard generations[key] == generation else { return }
            applyWindow(key, answer, from: from, to: to, now: now)
            succeeded(key, now: now)
            Log(.app).notice("calendar window read: \(answer.records.count) event(s)")
        } catch {
            guard generations[key] == generation else { return }
            failed(key, error, now: now)
        }
    }

    private func readChanges(_ key: Key, provider: any CalendarProviding, token: String, window: DateInterval,
                             now: Date) async {
        networkReads += 1
        let generation = generations[key]
        do {
            let delta = try await provider.eventDelta(since: token)
            guard generations[key] == generation else { return }
            applyDelta(key, delta, now: now)
            succeeded(key, now: now)
            Log(.app).notice("calendar changes read: \(delta.changed.count) changed, \(delta.removed.count) removed")
        } catch CalendarSyncError.tokenExpired {
            guard generations[key] == generation else { return }
            Log(.app).notice("calendar change token expired; reading the window again")
            await rereadAfterExpiry(key, provider: provider, window: window, now: now)
        } catch CalendarSyncError.unsupported {
            guard generations[key] == generation else { return }
            slices[key]?.tokensUnsupported = true
            slices[key]?.syncToken = nil
            await readWindow(key, provider: provider, from: window.start, to: window.end, now: now)
        } catch {
            guard generations[key] == generation else { return }
            failed(key, error, now: now)
        }
    }

    private func rereadAfterExpiry(_ key: Key, provider: any CalendarProviding, window: DateInterval, now: Date) async {
        networkReads += 1
        let old = slices[key] ?? Slice()
        let generation = generations[key]
        do {
            let answer = try await provider.eventWindow(from: window.start, to: window.end)
            guard generations[key] == generation else { return }
            var fresh = Slice()
            fresh.provisional = old.provisional.filter { old.records[$0] != nil }
            for id in fresh.provisional { fresh.records[id] = old.records[id] }
            var change = CalendarEventStoreChange(key: key)
            change.coverageChanged = true
            for record in answer.records {
                let id = record.event.id
                guard !id.isEmpty else { continue }
                fresh.records[id] = record
                if let before = old.records[id] {
                    if !before.isSameVersion(as: record) { change.updated.insert(id) }
                } else {
                    change.inserted.insert(id)
                }
            }
            change.removed = Set(old.records.keys).subtracting(fresh.records.keys)
            fresh.ranges = [CalendarCoveredRange(start: window.start, end: window.end, fetchedAt: now)]
            fresh.syncToken = answer.syncToken
            fresh.lastRefresh = now
            fresh.lastFullRead = now
            slices[key] = fresh
            enqueue(.replace(CalendarCacheEntry(key: key, records: persistable(fresh), ranges: fresh.ranges,
                                                syncToken: fresh.syncToken)))
            notify(change)
        } catch {
            guard generations[key] == generation else { return }
            drop(key)
            enqueue(.forgetCalendar(key))
            failed(key, error, now: now)
        }
    }

    private func applyWindow(_ key: Key, _ answer: CalendarEventWindow, from: Date, to: Date, now: Date) {
        var slice = slices[key] ?? Slice()
        var change = CalendarEventStoreChange(key: key)
        change.coverageChanged = true
        let incoming = Set(answer.records.map(\.event.id))
        var removed: [String] = []
        for (id, record) in slice.records where answer.isComplete && record.event.overlaps(from: from, to: to)
            && !incoming.contains(id) && !slice.provisional.contains(id) {
            slice.records[id] = nil
            change.removed.insert(id)
            removed.append(id)
        }
        var upserted: [CalendarEventRecord] = []
        for record in answer.records {
            let before = change
            Self.upsert(record, into: &slice, change: &change)
            if change.removed.count > before.removed.count { removed.append(record.event.id) }
            if change.inserted.count > before.inserted.count || change.updated.count > before.updated.count {
                upserted.append(record)
            }
        }
        slice.ranges = Self.inserting(CalendarCoveredRange(start: from, end: to, fetchedAt: now), into: slice.ranges)
        if !slice.tokensUnsupported, answer.isComplete, let token = answer.syncToken { slice.syncToken = token }
        slice.lastRefresh = now
        if answer.isComplete { slice.lastFullRead = now }
        removed += Self.trim(&slice, now: now)
        slices[key] = slice
        save(key, slice: slice, upserted: upserted, removed: removed)
        notify(change)
    }

    private func applyDelta(_ key: Key, _ delta: CalendarEventDelta, now: Date) {
        var slice = slices[key] ?? Slice()
        var change = CalendarEventStoreChange(key: key)
        var upserted: [CalendarEventRecord] = []
        var removed: [String] = []
        for record in delta.changed {
            let id = record.event.id
            guard slice.records[id] != nil || Self.overlapsAny(slice.ranges, record.event) else { continue }
            let before = change
            Self.upsert(record, into: &slice, change: &change)
            if change.removed.count > before.removed.count { removed.append(id) }
            if change.inserted.count > before.inserted.count || change.updated.count > before.updated.count {
                upserted.append(record)
            }
        }
        for id in delta.removed where slice.records.removeValue(forKey: id) != nil {
            slice.provisional.remove(id)
            change.removed.insert(id)
            removed.append(id)
        }
        slice.syncToken = delta.syncToken
        slice.ranges = slice.ranges.map { CalendarCoveredRange(start: $0.start, end: $0.end, fetchedAt: now) }
        slice.lastRefresh = now
        slices[key] = slice
        save(key, slice: slice, upserted: upserted, removed: removed)
        notify(change)
    }

    private func succeeded(_ key: Key, now: Date) {
        guard var slice = slices[key] else { return }
        slice.failures = 0
        slice.retryAt = nil
        slice.lastError = nil
        slices[key] = slice
    }

    private func failed(_ key: Key, _ error: Error, now: Date) {
        var slice = slices[key] ?? Slice()
        slice.failures += 1
        var wait = min(Self.firstRetry * pow(2, Double(min(slice.failures - 1, 16))), Self.longestRetry)
        if case CalendarSyncError.rateLimited(let after) = error { wait = max(wait, after ?? Self.rateLimitPause) }
        slice.retryAt = now.addingTimeInterval(wait)
        slice.lastError = Self.words(error)
        slices[key] = slice
        Log(.app).notice("calendar refresh failed (\(slice.failures) in a row); next try in \(Int(wait)) s")
        var change = CalendarEventStoreChange(key: key)
        change.coverageChanged = true
        notify(change)
    }

    static func words(_ error: Error) -> String {
        switch error {
        case let calendar as CalendarError: calendar.description
        case CalendarSyncError.rateLimited: String(localized: "Google is limiting calendar requests. Try again in a minute.")
        default: String(localized: "The calendar didn't answer.")
        }
    }

    private func drop(_ key: Key) {
        generations[key, default: 0] += 1
        guard let slice = slices.removeValue(forKey: key) else { return }
        var change = CalendarEventStoreChange(key: key)
        change.removed = Set(slice.records.keys)
        change.coverageChanged = true
        notify(change)
    }

    private func notify(_ change: CalendarEventStoreChange) {
        guard !change.isEmpty else { return }
        for handler in observers.values { handler(change) }
    }

    private func persistable(_ slice: Slice) -> [CalendarEventRecord] {
        slice.records.values.filter { !slice.provisional.contains($0.event.id) }
    }

    private func save(_ key: Key, slice: Slice, upserted: [CalendarEventRecord], removed: [String]) {
        let kept = upserted.filter { !slice.provisional.contains($0.event.id) && slice.records[$0.event.id] != nil }
        enqueue(.save(key, upserted: kept, removed: removed, ranges: slice.ranges, syncToken: slice.syncToken))
    }

    private func enqueue(_ write: CalendarCacheWrite) {
        guard let persistence else { return }
        let previous = persistTail
        persistTail = Task.detached(priority: .utility) {
            await previous?.value
            await persistence.apply(write)
        }
    }

    // Why: the written copy keeps the version it replaced, so a read that began before the write (and so still carries
    // that version) leaves it alone; the calendar's next version replaces it
    static func localRecord(_ event: CalendarEvent, replacing old: CalendarEventRecord?, readIn zone: TimeZone)
        -> CalendarEventRecord {
        CalendarEventRecord(event: event, etag: old?.etag, updated: old?.updated,
                            recurringEventID: event.recurringEventID ?? old?.recurringEventID,
                            isBusy: old?.isBusy, declinedByMe: event.myResponse == .declined, readIn: zone)
    }

    static func upsert(_ record: CalendarEventRecord, into slice: inout Slice, change: inout CalendarEventStoreChange,
                       local: Bool = false) {
        let id = record.event.id
        guard !id.isEmpty else { return }
        if let old = slice.records[id] {
            let same = local ? old == record : old.isSameVersion(as: record)
            if same && !slice.provisional.contains(id) { return }
            change.updated.insert(id)
        } else {
            change.inserted.insert(id)
        }
        slice.records[id] = record
        slice.provisional.remove(id)
    }

    static func trim(_ slice: inout Slice, now: Date) -> [String] {
        var total = slice.ranges.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let limit = TimeInterval(maxCoveredDays) * 86_400
        guard total > limit else { return [] }
        var ranges = slice.ranges.sorted { distance($0, now) > distance($1, now) }
        while total > limit, ranges.count > 1 {
            let gone = ranges.removeFirst()
            total -= gone.end.timeIntervalSince(gone.start)
        }
        slice.ranges = normalized(ranges)
        var removed: [String] = []
        for (id, record) in slice.records where !slice.provisional.contains(id) && !overlapsAny(slice.ranges, record.event) {
            slice.records[id] = nil
            removed.append(id)
        }
        return removed
    }

    private static func distance(_ range: CalendarCoveredRange, _ now: Date) -> TimeInterval {
        if now < range.start { return range.start.timeIntervalSince(now) }
        if now >= range.end { return now.timeIntervalSince(range.end) }
        return 0
    }

    public static func window(from: Date, to: Date, today: Date, calendar: Calendar) -> DateInterval {
        func around(_ start: Date, _ end: Date) -> DateInterval {
            let first = calendar.startOfDay(for: start)
            let last = calendar.startOfDay(for: end)
            let from = calendar.date(byAdding: .day, value: -daysBefore, to: first) ?? first
            let until = calendar.date(byAdding: .day, value: daysAfter, to: last) ?? last
            return DateInterval(start: from, end: max(until, end))
        }
        let standard = around(today, today)
        if from >= standard.start, to <= standard.end { return standard }
        return around(from, to)
    }

    static func covers(_ ranges: [CalendarCoveredRange], from: Date, to: Date) -> Bool {
        var cursor = from
        for range in ranges.sorted(by: { $0.start < $1.start }) where range.end > cursor {
            if range.start > cursor { return false }
            cursor = range.end
            if cursor >= to { return true }
        }
        return cursor >= to
    }

    static func gaps(in window: DateInterval, ranges: [CalendarCoveredRange]) -> [DateInterval] {
        var gaps: [DateInterval] = []
        var cursor = window.start
        for range in ranges.sorted(by: { $0.start < $1.start }) where range.end > cursor && range.start < window.end {
            if range.start > cursor { gaps.append(DateInterval(start: cursor, end: range.start)) }
            cursor = max(cursor, range.end)
        }
        if cursor < window.end { gaps.append(DateInterval(start: cursor, end: window.end)) }
        return gaps
    }

    static func block(containing day: Date, in ranges: [CalendarCoveredRange]) -> DateInterval? {
        var blocks: [DateInterval] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = blocks.last, range.start <= last.end {
                blocks[blocks.count - 1] = DateInterval(start: last.start, end: max(last.end, range.end))
            } else {
                blocks.append(DateInterval(start: range.start, end: range.end))
            }
        }
        return blocks.first { $0.start <= day && day < $0.end }
    }

    static func inserting(_ new: CalendarCoveredRange, into ranges: [CalendarCoveredRange]) -> [CalendarCoveredRange] {
        var out: [CalendarCoveredRange] = []
        for range in ranges {
            if range.end <= new.start || range.start >= new.end {
                out.append(range)
                continue
            }
            if range.start < new.start {
                out.append(CalendarCoveredRange(start: range.start, end: new.start, fetchedAt: range.fetchedAt))
            }
            if range.end > new.end {
                out.append(CalendarCoveredRange(start: new.end, end: range.end, fetchedAt: range.fetchedAt))
            }
        }
        out.append(new)
        return out.sorted { $0.start < $1.start }
    }

    static func normalized(_ ranges: [CalendarCoveredRange]) -> [CalendarCoveredRange] {
        ranges.sorted { $0.fetchedAt < $1.fetchedAt }.reduce(into: [CalendarCoveredRange]()) { out, range in
            out = inserting(range, into: out)
        }
    }

    static func overlapsAny(_ ranges: [CalendarCoveredRange], _ event: CalendarEvent) -> Bool {
        ranges.contains { event.overlaps(from: $0.start, to: $0.end) }
    }

    static func merged(_ blocks: [CalendarBusyInterval]) -> [CalendarBusyInterval] {
        var out: [CalendarBusyInterval] = []
        for block in blocks where block.end > block.start {
            if let last = out.last, block.start <= last.end {
                out[out.count - 1] = CalendarBusyInterval(start: last.start, end: max(last.end, block.end))
            } else {
                out.append(block)
            }
        }
        return out
    }

    static func soonestFirst(_ a: CalendarEvent, _ b: CalendarEvent) -> Bool {
        a.start != b.start ? a.start < b.start : a.id < b.id
    }
}
