import AppKit
import MailFeatures
import MailModel
import MailTheme
import MailUI
import SwiftUI

enum CalendarFormMetrics {
    static let sectionSpacing: CGFloat = 10
    static let iconGap: CGFloat = 8
    static let rowPaddingX: CGFloat = 10
    static let rowPaddingY: CGFloat = 5
    static let rowMinHeight: CGFloat = 30
    static let sectionRadius: CGFloat = 10
    static let sectionFillOpacity: Double = 0.045
    static let symbolWidth: CGFloat = 18
    static let avatarSize: CGFloat = 24
    static let badgeSize: CGFloat = 12
    static let dateFieldWidth: CGFloat = 92
}

// One group of rows on a rounded plate, as in a grouped form; rows are split by inset separators. Draws nothing
// when every row is switched off.
struct CalendarFormSection<Content: View>: View {
    var identifier: String?
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CalendarFormMetrics.sectionRadius, style: .continuous)
        Group(subviews: content) { rows in
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            Rectangle().fill(theme.borderHairline.color)
                                .frame(height: theme.borderWidthHairline)
                                .padding(.leading, CalendarFormMetrics.rowPaddingX)
                                .accessibilityHidden(true)
                        }
                        row
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shape.fill(theme.textPrimary.color.opacity(CalendarFormMetrics.sectionFillOpacity)))
                .overlay(shape.strokeBorder(theme.borderHairline.color, lineWidth: theme.borderWidthHairline))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier ?? "")
            }
        }
    }
}

// A labelled row: an optional symbol and the label on the leading side, the control on the trailing side. Quiet rows
// (the settings most events keep) use the secondary text colour.
struct CalendarFormRow<Control: View>: View {
    let title: String
    var symbol: String?
    var detail: String?
    var quiet = false
    @ViewBuilder var control: Control
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: CalendarFormMetrics.iconGap) {
            if let symbol { CalendarFormSymbol(symbol: symbol) }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .foregroundStyle((quiet ? theme.textSecondary : theme.textPrimary).color)
                    .lineLimit(1)
                if let detail {
                    Text(verbatim: detail).font(.subheadline).foregroundStyle(theme.textTertiary.color)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
            Spacer(minLength: CalendarFormMetrics.iconGap)
            control
        }
        .calendarFormRowPadding()
    }
}

// A row whose control fills it: a text field, the notes or a guest
struct CalendarFormWideRow<Content: View>: View {
    var symbol: String?
    var alignment: VerticalAlignment = .center
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: alignment, spacing: CalendarFormMetrics.iconGap) {
            if let symbol { CalendarFormSymbol(symbol: symbol) }
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .calendarFormRowPadding()
    }
}

struct CalendarFormSymbol: View {
    let symbol: String
    @Environment(\.theme) private var theme

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: 13))
            .foregroundStyle(theme.textSecondary.color)
            .frame(width: CalendarFormMetrics.symbolWidth)
            .accessibilityHidden(true)
    }
}

extension View {
    func calendarFormRowPadding() -> some View {
        padding(.horizontal, CalendarFormMetrics.rowPaddingX)
            .padding(.vertical, CalendarFormMetrics.rowPaddingY)
            .frame(maxWidth: .infinity, minHeight: CalendarFormMetrics.rowMinHeight, alignment: .leading)
    }

    // An inline pull-down: the value and a chevron, no bezel, as in an inspector
    func calendarQuietMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.visible)
            .fixedSize()
    }
}

enum CalendarFormSummary {
    // The event's length under Ends, short enough for the sidebar: "1h 15m", or the number of days for an all-day event
    static func duration(start: Date, end: Date, isAllDay: Bool, calendar: Calendar) -> String? {
        guard end > start else { return nil }
        if isAllDay {
            let days = max(calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                                   to: calendar.startOfDay(for: end)).day ?? 1, 1)
            return Duration.seconds(days * 86_400).formatted(.units(allowed: [.days], width: .wide))
        }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        guard minutes > 0 else { return nil }
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow))
    }

    static func permissions(_ permissions: CalendarGuestPermissions) -> String {
        var parts: [String] = []
        if permissions.canModify { parts.append(String(localized: "Modify")) }
        if permissions.canInviteOthers { parts.append(String(localized: "Invite others")) }
        if permissions.canSeeGuestList { parts.append(String(localized: "See guests")) }
        return parts.isEmpty ? String(localized: "None") : parts.joined(separator: ", ")
    }

    static func answer(_ response: CalendarResponse?) -> String? {
        switch response {
        case .accepted: String(localized: "Accepted")
        case .declined: String(localized: "Declined")
        case .tentative: String(localized: "Maybe")
        case .needsAction, nil: nil
        }
    }
}

// A guest's initials in the reader's neutral circle, with their answer as a small badge, as in the event details
struct CalendarGuestAvatar: View {
    let guest: CalendarGuest
    @Environment(\.theme) private var theme

    var body: some View {
        let avatar = theme.component.avatar
        let side = CalendarFormMetrics.avatarSize
        Text(verbatim: ThreadRowFormatting().initials(name: guest.name, email: guest.email))
            .themeFont(theme.typeCaption)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(avatar.text.color)
            .frame(width: side, height: side)
            .background(Circle().fill(avatar.bg.color))
            .overlay(Circle().strokeBorder(avatar.ring.color, lineWidth: theme.borderWidthHairline))
            .overlay(alignment: .bottomTrailing) { badge.offset(x: 3, y: 3) }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var badge: some View {
        if let style = badgeStyle {
            Image(systemName: style.symbol).font(.system(size: 6, weight: .heavy)).foregroundStyle(theme.bgElevated.color)
                .frame(width: CalendarFormMetrics.badgeSize, height: CalendarFormMetrics.badgeSize)
                .background(Circle().fill(style.color.color))
                .overlay(Circle().strokeBorder(theme.bgElevated.color, lineWidth: 1.5))
        }
    }

    private var badgeStyle: (symbol: String, color: ThemeColor)? {
        switch guest.response {
        case .accepted: ("checkmark", theme.textSuccess)
        case .tentative: ("questionmark", theme.textWarning)
        case .declined: ("xmark", theme.textDanger)
        case .needsAction, nil: nil
        }
    }
}

// A TextEditor that reads like the rounded fields: it rests at one line, opens to three when focused or filled,
// grows with the text up to ten lines and then scrolls. Return inserts a new line. Unframed, it sits in a form row
// with no field of its own.
struct CalendarTextAreaModifier: ViewModifier {
    let text: String
    let prompt: LocalizedStringKey
    let focused: Bool
    var framed = true

    static let restingLines = 1
    static let minLines = 3
    static let maxLines = 10
    static let textInset: CGFloat = 5
    static let radius: CGFloat = 6

    @MainActor static var lineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: NSFont.systemFontSize))
    }

    static func minimumLines(text: String, focused: Bool) -> Int {
        text.isEmpty && !focused ? restingLines : minLines
    }

    func body(content: Content) -> some View {
        if framed {
            area(content: content)
                .padding(.horizontal, 3)
                .padding(.vertical, 3)
                .background(shape.fill(Color(nsColor: .textBackgroundColor)))
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
                .overlay {
                    if focused {
                        RoundedRectangle(cornerRadius: Self.radius + 1.5, style: .continuous)
                            .stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                            .padding(-1.5)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            // The text lines up with the plain fields above it; the editor's own line padding sits in the row's margin
            area(content: content).padding(.horizontal, -Self.textInset)
        }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.radius, style: .continuous) }

    private func area(content: Content) -> some View {
        let lines = Self.minimumLines(text: text, focused: focused)
        return Text(verbatim: text + " ")
            .font(.body)
            .lineLimit(Self.maxLines)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: CGFloat(lines) * Self.lineHeight, alignment: .topLeading)
            .padding(.horizontal, Self.textInset)
            .padding(.vertical, 2)
            .hidden()
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                content
                    .font(.body)
                    .textEditorStyle(.plain)
                    .scrollContentBackground(.hidden)
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(prompt).font(.body).foregroundStyle(.tertiary)
                        .padding(.horizontal, Self.textInset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

extension View {
    func calendarTextArea(text: String, prompt: LocalizedStringKey, focused: Bool, framed: Bool = true) -> some View {
        modifier(CalendarTextAreaModifier(text: text, prompt: prompt, focused: focused, framed: framed))
    }
}

// The calendar's own colour fills the checkbox, as in the system Calendar
struct CalendarColorCheckboxStyle: ToggleStyle {
    let color: ThemeColor

    static func checkReadsDark(on color: ThemeColor) -> Bool {
        0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue > 0.6
    }

    func makeBody(configuration: Configuration) -> some View {
        let fill = color.color
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                shape.fill(configuration.isOn ? fill : Color.clear)
                    .overlay(shape.strokeBorder(fill, lineWidth: 1.5))
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Self.checkReadsDark(on: color) ? Color.black.opacity(0.8) : Color.white)
                        }
                    }
                    .frame(width: 14, height: 14)
                configuration.label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

// One menu for the reminders: Calendar default, None, then a checkmark per reminder
enum CalendarReminderMenu {
    struct Item: Hashable, Identifiable {
        let reminder: CalendarReminder
        let title: String
        let isOn: Bool
        let isEnabled: Bool
        var id: String { reminder.id }
    }

    static func current(_ reminders: CalendarReminders) -> [CalendarReminder] {
        switch reminders {
        case .calendarDefault: []
        case .custom(let list): list
        }
    }

    static func ordered(_ a: CalendarReminder, _ b: CalendarReminder) -> Bool {
        (a.minutesBefore, a.method.rawValue) < (b.minutesBefore, b.method.rawValue)
    }

    static func itemTitle(_ reminder: CalendarReminder) -> String {
        reminder.method == .email ? String(localized: "Email, \(reminder.text)") : reminder.text
    }

    static func title(_ reminders: CalendarReminders) -> String {
        switch reminders {
        case .calendarDefault:
            return String(localized: "Calendar default")
        case .custom(let list):
            guard let first = list.sorted(by: ordered).first else { return String(localized: "None") }
            let lead = itemTitle(first)
            return list.count == 1 ? lead : String(localized: "\(lead), +\(list.count - 1)")
        }
    }

    static func items(_ reminders: CalendarReminders) -> [Item] {
        let chosen = current(reminders)
        var all = CalendarReminder.presets.map { CalendarReminder(minutesBefore: $0) }
        for reminder in chosen where !all.contains(reminder) { all.append(reminder) }
        let full = chosen.count >= CalendarReminder.maxCount
        return all.sorted(by: ordered).map { reminder in
            let on = chosen.contains(reminder)
            return Item(reminder: reminder, title: itemTitle(reminder), isOn: on, isEnabled: on || !full)
        }
    }

    static func toggling(_ reminder: CalendarReminder, in reminders: CalendarReminders) -> CalendarReminders {
        var list = current(reminders)
        if let index = list.firstIndex(of: reminder) {
            list.remove(at: index)
        } else if list.count < CalendarReminder.maxCount {
            list.append(reminder)
        }
        return .custom(list)
    }
}

enum CalendarColourMenu {
    static let numbers = Array(1...11)

    static func choices(including current: String?) -> [String?] {
        var all: [String?] = [nil] + numbers.map { Optional(String($0)) }
        if let current, !all.contains(current) { all.append(current) }
        return all
    }

    static func title(_ id: String?) -> String {
        guard let id else { return String(localized: "Calendar colour") }
        return String(localized: "Colour \(id)")
    }

    static func ink(_ id: String?, theme: ResolvedTheme) -> ThemeColor? {
        guard let number = id.flatMap({ Int($0) }) else { return nil }
        return CalendarPalette.ink(number, tokens: theme.tokens)
    }

    static func swatch(_ fill: ThemeColor?, ring: ThemeColor, side: CGFloat = 14) -> NSImage {
        let filled = fill.map { [$0.red, $0.green, $0.blue, $0.alpha] }
        let edge = [ring.red, ring.green, ring.blue, ring.alpha]
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            if let filled {
                NSColor(srgbRed: filled[0], green: filled[1], blue: filled[2], alpha: filled[3]).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            } else {
                NSColor(srgbRed: edge[0], green: edge[1], blue: edge[2], alpha: edge[3]).setStroke()
                let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.75, dy: 1.75))
                circle.lineWidth = 1.5
                circle.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

// A TextEditor that reads like the rounded fields: it rests at one line, opens to three when focused or filled,
