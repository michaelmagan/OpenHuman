#if os(macOS)
import AppKit
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI

/// "Pick a date…" in the snooze and remind pickers: the system calendar and a time field.
@MainActor
@Suite(.serialized) struct PickerGridVisibilityTests {
    nonisolated static let now = Date(timeIntervalSince1970: 1_791_000_000 + 10 * 86_400)

    private func model() -> TimePickerModel {
        let m = TimePickerModel(kind: .remind, targets: [], presets: TimePresets(timeZone: TimeZone(identifier: "UTC")!),
                                locale: Locale(identifier: "en_US_POSIX"), now: { Self.now }) { _ in }
        m.openDatePick()
        return m
    }

    private final class Stage {
        let window: NSWindow
        let hosting: NSView

        init(window: NSWindow, hosting: NSView) {
            self.window = window
            self.hosting = hosting
        }
    }

    private func stage(_ m: TimePickerModel, dark: Bool, size: NSSize = NSSize(width: 420, height: 340)) -> Stage {
        let view = TimePickerDatePick(model: m)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return Stage(window: window, hosting: hosting)
    }

    private func close(_ stage: Stage) {
        stage.window.contentView = nil
        stage.window.close()
    }

    private func ink(_ view: NSView, name: String) throws -> Int {
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        func luma(_ c: NSColor) -> CGFloat { 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent }
        let ref = luma(try #require(rep.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB)))
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(luma(c) - ref) > 0.2 { count += 1 }
            }
        }
        if let dir = ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] {
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(count).png"))
        }
        return count
    }

    private static func subviews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { subviews(type, in: $0) }
    }

    @Test(arguments: [false, true])
    func theCalendarAndTheTimeFieldDraw(dark: Bool) throws {
        let m = model()
        let staged = stage(m, dark: dark)
        defer { close(staged) }
        #expect(try ink(staged.hosting, name: "date-pick-\(dark ? "dark" : "light")") > 1200, "days, month and time, dark \(dark)")
    }

    @Test func theCalendarIsTheSystemDatePickerOnTheChosenDay() throws {
        let m = model()
        let staged = stage(m, dark: false)
        defer { close(staged) }
        let pick = try #require(m.datePick)
        let pickers = Self.subviews(NSDatePicker.self, in: staged.hosting)
        let calendar = try #require(pickers.first { $0.datePickerStyle == .clockAndCalendar }, "a graphical NSDatePicker")
        #expect(calendar.dateValue == pick.day)
        #expect(calendar.minDate == m.todayStart, "days before today cannot be picked")

        m.moveDay(by: 2)
        staged.hosting.layoutSubtreeIfNeeded()
        #expect(calendar.dateValue == m.datePick?.day, "the arrows in the picker's field move the calendar's day")
    }

    @Test func theTimeFieldIsTheOnlyFieldAndABadTimeKeepsThePickerOpen() throws {
        let m = model()
        let staged = stage(m, dark: false)
        defer { close(staged) }
        let time = try #require(m.datePick).timeText
        let fields = Self.subviews(NSTextField.self, in: staged.hosting).filter(\.isEditable)
        #expect(fields.map(\.stringValue) == [time], "one editable field: the time")

        m.setTimeText("zz")
        m.confirm()
        #expect(m.datePickError != nil && !m.isClosed && m.datePick != nil)
        #expect(try ink(staged.hosting, name: "date-pick-error") > 1200)
    }
}
#endif
