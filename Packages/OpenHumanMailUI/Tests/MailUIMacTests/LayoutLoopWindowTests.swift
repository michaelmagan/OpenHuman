import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

// Counts the window's constraint passes. AppKit stops a window that keeps asking for another pass inside one display
// cycle; before it does, the count climbs here.
final class ConstraintPassWindow: NSWindow {
    // Every call in this sampling interval; AppKit also makes one before each layout of a subtree
    var constraintPasses = 0
    // A suspended sample can span several run-loop turns. Keep their maximum, rather than adding them together.
    var maxPassesInTurn = 0
    private var passesInTurn = 0
    // Calls that found a view asking to update its constraints
    var pendingPasses = 0
    // Calls made from inside another call
    var nestedPasses = 0
    var tracer: ConstraintPassTracer?
    private var inside = 0

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func finishTurn() { passesInTurn = 0 }

    func startSample() {
        constraintPasses = 0
        pendingPasses = 0
        nestedPasses = 0
        maxPassesInTurn = passesInTurn
    }

    override func updateConstraintsIfNeeded() {
        constraintPasses += 1
        passesInTurn += 1
        maxPassesInTurn = max(maxPassesInTurn, passesInTurn)
        if inside > 0 { nestedPasses += 1 }
        let tracer = self.tracer?.traces == true ? self.tracer : nil
        if let tracer {
            let asking = tracer.views(askingIn: self)
            if !asking.isEmpty { pendingPasses += 1 }
            tracer.record(asking, again: false)
        }
        inside += 1
        super.updateConstraintsIfNeeded()
        inside -= 1
        // A view still asking once the pass is over asked again from inside it, as in the crash this suite reproduces
        if let tracer { tracer.record(tracer.views(askingIn: self), again: true) }
    }
}

// Which views asked the window for a constraint pass, without swizzling: each call walks the window's views and reads
// `needsUpdateConstraints`, before the pass and again after it. The walk is capped so a loop cannot make it the cost
@MainActor
final class ConstraintPassTracer {
    struct Asker {
        var depth: Int
        var kind: String
        var path: String
        var asked = 0
        var askedAgain = 0
        var widths: Set<Int> = []
        var heights: Set<Int> = []
    }

    static let walksPerCycle = 400
    static let walksInAll = 20_000

    private(set) var askers: [ObjectIdentifier: Asker] = [:]
    private(set) var viewCount = 0
    private var walksThisCycle = 0
    private var walks = 0

    var traces: Bool { walksThisCycle < Self.walksPerCycle && walks < Self.walksInAll }

    func startCycle() { walksThisCycle = 0 }

    func views(askingIn window: NSWindow) -> [(view: NSView, depth: Int)] {
        guard let root = window.contentView?.superview ?? window.contentView else { return [] }
        walksThisCycle += 1
        walks += 1
        var found: [(view: NSView, depth: Int)] = []
        var count = 0
        func walk(_ view: NSView, _ depth: Int) {
            count += 1
            if view.needsUpdateConstraints { found.append((view, depth)) }
            for subview in view.subviews { walk(subview, depth + 1) }
        }
        walk(root, 0)
        viewCount = max(viewCount, count)
        return found
    }

    func record(_ asking: [(view: NSView, depth: Int)], again: Bool) {
        for (view, depth) in asking {
            let id = ObjectIdentifier(view)
            var asker = askers[id] ?? Asker(depth: depth, kind: Self.kind(of: view), path: Self.path(to: view))
            if again { asker.askedAgain += 1 } else { asker.asked += 1 }
            asker.widths.insert(Int((view.frame.width * 2).rounded()))
            asker.heights.insert(Int((view.frame.height * 2).rounded()))
            askers[id] = asker
        }
    }

    // The busiest first
    var ranked: [Asker] {
        askers.values.sorted { ($0.asked + $0.askedAgain, $0.depth) > ($1.asked + $1.askedAgain, $1.depth) }
    }

    static func kind(of view: NSView) -> String {
        let name = String(describing: type(of: view))
        return name.count > 240 ? String(name.prefix(240)) + "…" : name
    }

    static func path(to view: NSView) -> String {
        var names: [String] = []
        var current: NSView? = view
        while let shown = current {
            let name = String(describing: type(of: shown))
            names.append(String(name.prefix { $0 != "<" }))
            current = shown.superview
        }
        return names.reversed().joined(separator: " > ")
    }

    static func line(_ asker: Asker) -> String {
        let widths = asker.widths.sorted().prefix(8).map { String(format: "%.1f", Double($0) / 2) }
        let heights = asker.heights.sorted().prefix(8).map { String(format: "%.1f", Double($0) / 2) }
        return "asked \(asker.asked), again inside the pass \(asker.askedAgain), depth \(asker.depth), "
            + "widths \(widths) (\(asker.widths.count)), heights \(heights) (\(asker.heights.count)): \(asker.kind)"
    }
}

// A layout that never settles can hold the main thread inside one display cycle, where the test can neither record
// an issue nor stop. A queue beside it ends the test process with a message once a cycle has not come back for
// `seconds`, instead of letting it spin for minutes.
final class LayoutStallWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let seconds: Int
    private let state: String
    private var lastBeat = DispatchTime.now()
    private var note = "starting"
    private var stopped = false

    init(seconds: Int, state: String) {
        self.seconds = seconds
        self.state = state
        schedule()
    }

    func beat(_ note: String) {
        lock.withLock {
            lastBeat = .now()
            self.note = note
        }
    }

    func stop() {
        lock.withLock { stopped = true }
    }

    private func schedule() {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(1)) { [self] in check() }
    }

    private func check() {
        let (done, stalled, note) = lock.withLock { (stopped, DispatchTime.now() > lastBeat + .seconds(seconds), note) }
        if done { return }
        guard !stalled else {
            let message = "LayoutLoopWindowTests: \(state): the main thread has not come back from \(note) for "
                + "\(seconds) s; a layout that never settles\n"
            FileHandle.standardError.write(Data(message.utf8))
            fatalError(message)
        }
        schedule()
    }
}

@MainActor
enum LayoutLoopProbe {
    static let cycles = 200
    static let settledCycles = 20
    // Count every updateConstraintsIfNeeded call in an actual main run-loop turn, including redundant calls before
    // subtree layouts. A sleep is only a sampling interval: on a busy runner several turns can pass before its
    // continuation runs. Their sum is not a display-cycle cost. Keep the same 32-call bound for each turn, and keep
    // the raw interval totals in the report. The watchdog also catches a pass that never returns.
    static let passesPerCycle = 32
    // Once a cycle is over the limit, this many more run so the report shows whether the loop lasts
    static let cyclesAfterLimit = 10
    static let reportedCycles = 20

    // A run that has not finished its cycles by then stops and fails instead of spinning
    static let runBudget: Duration = .seconds(60)
    // A single cycle the main thread has not come back from by then ends the test process with a message
    static let stallSeconds = 45

    struct Cycle {
        var calls: Int
        var peakCalls: Int
        var pending: Int
        var nested: Int
        var milliseconds: Int
        var windowFrame: NSRect
    }

    struct Report {
        var maxPasses = 0
        var tailStable = false
        var forcedInTail = false
        var changes = 0
        var cyclesRun = 0
        var stopped: String?
        var firstOverLimit: Int?
        var cycles: [Cycle] = []
        var askers: [ConstraintPassTracer.Asker] = []
        var viewCount = 0
        var reportPath = ""
    }

    // Each sample's total calls / peak in one turn / calls with a view asking / nested calls
    static func sequence(_ report: Report) -> String {
        report.cycles.prefix(reportedCycles).map { "\($0.calls)/\($0.peakCalls)/\($0.pending)/\($0.nested)" }.joined(separator: " ")
    }

    static func summary(_ report: Report) -> String {
        let top = report.askers.prefix(3).map { ConstraintPassTracer.line($0) }.joined(separator: "\n  ")
        let over = report.firstOverLimit.map { "sample \($0)" } ?? "none"
        return "max \(report.maxPasses) calls in a run-loop turn (first sample over \(passesPerCycle): \(over)), "
            + "\(report.viewCount) views in the window; first \(reportedCycles) samples "
            + "(total calls/peak in one turn/with a view asking/nested): \(sequence(report))\n"
            + "views asking most:\n  \(top.isEmpty ? "none" : top)\nreport: \(report.reportPath)"
    }

    static func make(size: NSSize, frameName: String, environment: AppEnvironment) async throws -> InlineReplyWindow {
        let themes = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: .light)),
                                reduceMotion: true)
        var attached: MainContentViewController?
        let root = MainWindowRoot(environment: environment, themes: themes) { attached = $0 }
        let hosting = NSHostingView(rootView: root)
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let frame = NSRect(origin: NSPoint(x: -6000, y: -6000), size: size)
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(frameName)")
        let window = ConstraintPassWindow(contentRect: frame, styleMask: [.titled, .resizable, .fullSizeContentView],
                                          backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        #expect(window.setFrameAutosaveName(frameName), "the frame name \(frameName) is free")
        window.contentView = hosting
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        try await until { attached != nil && environment.router.list?.state == .loaded }
        let content = try #require(attached)
        try await settleWindowChrome(of: window)
        content.keyRouter.isMailWindow = { $0 === window }
        return InlineReplyWindow(environment: environment, window: window, content: content)
    }

    // A legacy scroll bar (a mouse attached, or Show scroll bars: Always) takes width beside the content, so content
    // that re-wraps can bring it and take it away. The system setting is not the test's to change, so every scroll
    // view in the window is switched instead; one SwiftUI makes later is switched on the next cycle.
    static func forceLegacyScrollBars(in window: NSWindow) -> Bool {
        guard let root = window.contentView else { return false }
        var forced = false
        for scroll in subviews(of: NSScrollView.self, in: root) where scroll.scrollerStyle != .legacy {
            scroll.scrollerStyle = .legacy
            forced = true
        }
        return forced
    }

    // Where every shown scroll view and its clip sit; a clip that narrows and widens is a scroll bar coming and going
    static func shape(of window: NSWindow) -> [NSRect] {
        guard let root = window.contentView else { return [] }
        return subviews(of: NSScrollView.self, in: root)
            .filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
            .flatMap { [$0.convert($0.bounds, to: nil), $0.contentView.convert($0.contentView.bounds, to: nil)] }
    }

    // Samples the window `cycles` times, running `step` before each interval. A turn over the pass limit ends the
    // run `cyclesAfterLimit` samples later so the report also shows whether the loop lasts.
    static func run(_ w: InlineReplyWindow, _ state: String, step: (Int) -> Void = { _ in }) async throws -> Report {
        let window = try #require(w.window as? ConstraintPassWindow)
        let watchdog = LayoutStallWatchdog(seconds: stallSeconds, state: state)
        let tracer = ConstraintPassTracer()
        window.tracer = tracer
        defer {
            watchdog.stop()
            window.tracer = nil
        }
        window.finishTurn()
        // Observe after AppKit's work, immediately before the run loop sleeps or exits. This also covers turns
        // that occur while Task.sleep's continuation is waiting for the main actor.
        let boundaries = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        let observer = try #require(CFRunLoopObserverCreateWithHandler(nil, boundaries, true, .max) { [weak window] _, _ in
            MainActor.assumeIsolated { window?.finishTurn() }
        })
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        let clock = ContinuousClock()
        let deadline = clock.now + runBudget
        var report = Report()
        var shapes: [[NSRect]] = []
        var forced: [Bool] = []
        for cycle in 0..<cycles {
            watchdog.beat("cycle \(cycle)")
            step(cycle)
            forced.append(forceLegacyScrollBars(in: window))
            window.startSample()
            tracer.startCycle()
            let started = clock.now
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(4)) // flake-ok: sampling interval; the observer measures turn boundaries
            let took = clock.now - started
            report.cycles.append(Cycle(calls: window.constraintPasses, peakCalls: window.maxPassesInTurn,
                                       pending: window.pendingPasses, nested: window.nestedPasses,
                                       milliseconds: Int(took.components.seconds * 1000
                                           + took.components.attoseconds / 1_000_000_000_000_000),
                                       windowFrame: window.frame))
            report.cyclesRun = cycle + 1
            report.maxPasses = max(report.maxPasses, window.maxPassesInTurn)
            let now = shape(of: window)
            if let last = shapes.last, last != now { report.changes += 1 }
            shapes.append(now)
            if window.maxPassesInTurn > passesPerCycle, report.firstOverLimit == nil {
                report.firstOverLimit = cycle
                report.stopped = "sample \(cycle) had \(window.maxPassesInTurn) constraint calls in one run-loop turn"
            }
            if let first = report.firstOverLimit, cycle >= first + cyclesAfterLimit { break }
            if clock.now > deadline {
                let late = "\(cycle + 1) of \(cycles) cycles in \(runBudget)"
                report.stopped = report.stopped.map { $0 + "; " + late } ?? late
                break
            }
        }
        let tail = shapes.suffix(settledCycles)
        report.tailStable = tail.allSatisfy { $0 == tail.first }
        report.forcedInTail = forced.suffix(settledCycles).contains(true)
        report.askers = tracer.ranked
        report.viewCount = tracer.viewCount
        report.reportPath = write(report, state)
        print("LayoutLoop \(state): \(summary(report))")
        return report
    }

    // The whole report, for the failure message to point at
    static func write(_ report: Report, _ state: String) -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LayoutLoopWindowTests", // temp-ok: the report is kept so a failure can be read afterwards
                                                                                 isDirectory: true)
        let slug = state.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let file = folder.appendingPathComponent(String(slug) + ".txt")
        var lines = [
            state,
            "views in the window: \(report.viewCount) (AppKit stops a cycle whose passes outnumber them)",
            "samples run: \(report.cyclesRun), stopped: \(report.stopped ?? "no"), "
                + "max calls in a run-loop turn: \(report.maxPasses)",
            "first sample over \(passesPerCycle): \(report.firstOverLimit.map { String($0) } ?? "none")",
            "scroll views and clips moved \(report.changes) times; still in the last \(settledCycles) cycles: "
                + "\(report.tailStable)",
            "",
            "sample: total calls, max calls in one turn, with a view asking, nested, ms, window frame",
        ]
        for (index, cycle) in report.cycles.enumerated()
        where index < 40 || cycle.calls > passesPerCycle || index >= report.cycles.count - 5 {
            lines.append("\(index): \(cycle.calls), \(cycle.peakCalls), \(cycle.pending), \(cycle.nested), \(cycle.milliseconds), "
                + "\(NSStringFromRect(cycle.windowFrame))")
        }
        lines.append("")
        lines.append("views that asked for a constraint pass, busiest first (about the first "
            + "\(ConstraintPassTracer.walksPerCycle / 2) calls of each cycle are traced, and the second count "
            + "only for those):")
        for asker in report.askers.prefix(40) {
            lines.append("- " + ConstraintPassTracer.line(asker))
            lines.append("    in: " + asker.path)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return "not written: \(error)"
        }
        return file.path
    }

    static func expectSettled(_ report: Report, _ state: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(report.maxPasses <= passesPerCycle,
                "\(state): at most \(passesPerCycle) constraint calls per run-loop turn; \(summary(report))",
                sourceLocation: sourceLocation)
        if report.maxPasses <= passesPerCycle {
            #expect(report.stopped == nil && report.cyclesRun == cycles,
                    "\(state): all \(cycles) sampling intervals run, stopped after \(report.stopped ?? "none")",
                    sourceLocation: sourceLocation)
        }
        // A scroll view whose style SwiftUI keeps resetting is switched every cycle, which moves its clip by itself
        if !report.forcedInTail, report.stopped == nil {
            #expect(report.tailStable,
                    "\(state): nothing moves in the last \(settledCycles) cycles (\(report.changes) changes in all)",
                    sourceLocation: sourceLocation)
        }
    }

    static let longTitle = "Quarterly planning review with the design, research and platform teams, and the follow-up "
        + "on the launch checklist"
    static let longNotes = (1...14).map { line in
        "Line \(line): agenda item with enough words in it to wrap across the card at its usual width and again "
            + "when a scroll bar takes some of it."
    }.joined(separator: "\n")
    static let guests = [
        EmailAddress(name: "Dana Ruiz", email: "dana@example.com"),
        EmailAddress(name: "Sam Rivera", email: "sam@example.org"),
        EmailAddress(name: "Priya Natarajan", email: "priya.natarajan@example.net"),
        EmailAddress(name: "Theo Laurent", email: "theo@example.com"),
    ]
}

enum LayoutLoopSize: String, CaseIterable, CustomTestStringConvertible {
    case regular, narrow
    // Regular's width at narrow's height, and narrow's width at regular's height: which of the two a loop follows
    case short, slim

    static let common: [LayoutLoopSize] = [.regular, .narrow]

    var size: NSSize {
        switch self {
        case .regular: NSSize(width: 1280, height: 800)
        case .narrow: NSSize(width: 900, height: 700)
        case .short: NSSize(width: 1280, height: 700)
        case .slim: NSSize(width: 900, height: 800)
        }
    }

    var testDescription: String { rawValue }
}

private struct NarrowingFormHost: View {
    let box: CalendarFormBox
    let width: CGFloat
    @State private var sendUpdates: CalendarSendUpdates = .all

    var body: some View {
        CalendarEventFormView(form: Binding(get: { box.form }, set: { box.form = $0 }), rights: .all,
                              timeZone: TimeZone(identifier: "UTC") ?? .gmt, idPrefix: "test.narrowing", meetLink: nil,
                              asksSendUpdates: true, sendUpdates: $sendUpdates, isNewEvent: true)
            .frame(width: width)
            .environment(\.theme, ResolvedTheme.light)
    }
}

@MainActor
@Suite(.serialized)
struct LayoutLoopWindowTests {
    // In a scroll view a legacy scroll bar narrows the content by its width. Content that got shorter as it narrowed
    // could fit once the bar showed, lose the bar, overflow again at the full width, and never settle.
    @Test func theEventFormNeverGetsShorterAsItNarrows() async throws {
        let start = Date(timeIntervalSince1970: 1_791_000_000)
        let box = CalendarFormBox(CalendarEventForm(
            title: LayoutLoopProbe.longTitle, start: start, end: start.addingTimeInterval(3_600), timeZone: "UTC",
            guests: LayoutLoopProbe.guests.map { CalendarGuest($0) }, notes: LayoutLoopProbe.longNotes))
        let widths = Array(stride(from: CGFloat(520), through: 240, by: -3))
        let hosting = NSHostingView(rootView: AnyView(NarrowingFormHost(box: box, width: widths[0])))
        hosting.sizingOptions = [.intrinsicContentSize]
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 600, height: 1400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }
        // The form makes its guest field when it appears; the sweep starts once its height has stopped changing
        var last: CGFloat = 0
        try await until {
            hosting.layoutSubtreeIfNeeded()
            let height = hosting.fittingSize.height
            defer { last = height }
            return height > 100 && height == last
        }

        var heights: [(width: CGFloat, height: CGFloat)] = []
        for width in widths {
            hosting.rootView = AnyView(NarrowingFormHost(box: box, width: width))
            hosting.layoutSubtreeIfNeeded()
            heights.append((width, hosting.fittingSize.height))
        }
        let drops = zip(heights, heights.dropFirst()).filter { wide, narrow in narrow.height < wide.height - 0.5 }
            .map { wide, narrow in "\(wide.width)→\(narrow.width): \(wide.height)→\(narrow.height)" }
        #expect(drops.isEmpty, "the form gets shorter as it narrows: \(drops)")
        #expect((heights.last?.height ?? 0) >= (heights.first?.height ?? 0), "narrower wraps taller, never shorter")
    }

    @Test(arguments: LayoutLoopSize.common)
    func theNewEventCardSettlesWithLegacyScrollBars(_ size: LayoutLoopSize) async throws {
        let (environment, now) = CalendarWindowSweep.environment()
        let w = try await LayoutLoopProbe.make(size: size.size, frameName: "dev.openhuman.tests.loop-draft-\(size)",
                                               environment: environment)
        defer { w.close() }
        let model = try #require(environment.calendarWindow)
        let sidebar = try #require(environment.calendarSidebar)
        model.now = { now }
        sidebar.now = { now }
        await model.open(.week, source: .keyboard)
        try await until { model.state == .loaded && model.events.count > 10 }
        let calendar = CalendarDateMentions.calendar(model.timeZone)
        let free = try #require(calendar.date(bySettingHour: 16, minute: 0, second: 0, of: model.period.days[1]))
        await model.newEvent(start: free, end: free.addingTimeInterval(3_600))
        try await until { model.showsPendingCard }
        sidebar.draft?.title = LayoutLoopProbe.longTitle
        sidebar.draft?.attendees = LayoutLoopProbe.guests
        sidebar.draft?.sendUpdates = .all
        sidebar.draft?.notes = LayoutLoopProbe.longNotes

        let state = "the new-event card at \(size)"
        let report = try await LayoutLoopProbe.run(w, state) { cycle in
            // Notes typed while the card is open, then left alone
            if cycle < 60, cycle % 6 == 0 { sidebar.draft?.notes += " More." }
        }
        LayoutLoopProbe.expectSettled(report, state)
        sidebar.cancelDraft()
        await model.close()
    }

    @Test(arguments: LayoutLoopSize.common)
    func theEventCardSettlesWithLegacyScrollBars(_ size: LayoutLoopSize) async throws {
        let (environment, now) = CalendarWindowSweep.environment()
        let w = try await LayoutLoopProbe.make(size: size.size, frameName: "dev.openhuman.tests.loop-card-\(size)",
                                               environment: environment)
        defer { w.close() }
        let model = try #require(environment.calendarWindow)
        let sidebar = try #require(environment.calendarSidebar)
        model.now = { now }
        sidebar.now = { now }
        await model.open(.week, source: .keyboard)
        try await until { model.state == .loaded && model.events.count > 10 }
        let review = try #require(model.events.first { $0.id == "review" })
        model.openEvent(review)
        try await until { model.card?.form != nil }
        // A long title and notes; the change asks whether to email the guest
        model.card?.form?.title = LayoutLoopProbe.longTitle
        model.card?.form?.notes = LayoutLoopProbe.longNotes
        model.card?.form?.guests += LayoutLoopProbe.guests.prefix(3).map { CalendarGuest($0) }

        let state = "the event card at \(size)"
        let report = try await LayoutLoopProbe.run(w, state)
        LayoutLoopProbe.expectSettled(report, state)
        model.closeCard()
        await model.close()
    }

    // The panel alone, with no new event over it: whether a loop is the panel's or the card's
    @Test(arguments: LayoutLoopSize.allCases)
    func theSidebarDaySettlesWithLegacyScrollBars(_ size: LayoutLoopSize) async throws {
        let (environment, now) = CalendarWindowSweep.environment()
        let w = try await LayoutLoopProbe.make(size: size.size, frameName: "dev.openhuman.tests.loop-day-\(size)",
                                               environment: environment)
        defer { w.close() }
        let sidebar = try #require(environment.calendarSidebar)
        sidebar.now = { now }
        sidebar.setVisible(true)
        await sidebar.show(thread: nil)
        try await until { sidebar.state == .loaded }

        let state = "the sidebar's day at \(size)"
        let report = try await LayoutLoopProbe.run(w, state)
        LayoutLoopProbe.expectSettled(report, state)
        sidebar.setVisible(false)
    }

    @Test(arguments: LayoutLoopSize.allCases)
    func theSidebarDraftSettlesWithLegacyScrollBars(_ size: LayoutLoopSize) async throws {
        let (environment, now) = CalendarWindowSweep.environment()
        let w = try await LayoutLoopProbe.make(size: size.size, frameName: "dev.openhuman.tests.loop-sidebar-\(size)",
                                               environment: environment)
        defer { w.close() }
        let sidebar = try #require(environment.calendarSidebar)
        sidebar.now = { now }
        sidebar.setVisible(true)
        await sidebar.show(thread: nil)
        try await until { sidebar.state == .loaded }
        await sidebar.beginDraft(start: now, end: now.addingTimeInterval(3_600), key: .draft(UUID()))
        try await until { sidebar.draft != nil }
        sidebar.draft?.title = LayoutLoopProbe.longTitle
        sidebar.draft?.attendees = LayoutLoopProbe.guests
        sidebar.draft?.sendUpdates = .all
        sidebar.draft?.notes = LayoutLoopProbe.longNotes

        let state = "the sidebar's new event at \(size)"
        let report = try await LayoutLoopProbe.run(w, state)
        LayoutLoopProbe.expectSettled(report, state)
        sidebar.cancelDraft()
        sidebar.setVisible(false)
    }

    @Test(arguments: LayoutLoopSize.common)
    func theInlineReplySettlesWhileTypingWithLegacyScrollBars(_ size: LayoutLoopSize) async throws {
        let w = try await LayoutLoopProbe.make(size: size.size, frameName: "dev.openhuman.tests.loop-reply-\(size)",
                                               environment: AppEnvironment.fake(
                                                   corpus: .small, options: .init(remoteAck: .immediate),
                                                   featureFlags: ComposerTypingLayoutTests.flags,
                                                   notices: NoticeCenter(autoExpire: false)))
        defer { w.close() }
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        try await until { composer.hasKeyboardFocus }
        let editor = try #require(w.editors.first)
        let line = "A line long enough to wrap in the reply at this width, and to wrap again when a scroll bar shows. "

        let state = "the inline reply at \(size)"
        let report = try await LayoutLoopProbe.run(w, state) { cycle in
            guard cycle < 120 else { return }
            if cycle % 8 == 7 {
                editor.insertNewline(nil)
            } else {
                editor.insertText(line, replacementRange: editor.selectedRange())
            }
        }
        LayoutLoopProbe.expectSettled(report, state)
    }
}
