import MailFeatures
import MailTheme
import SwiftUI

struct TimePickerView: View {
    let model: TimePickerModel
    let dismiss: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        OverlayPanel(width: OverlayMetrics.timePickerWidth, dismiss: dismiss) { _ in
            VStack(spacing: 0) {
                OverlayHeader(title: model.title)
                input
                Divider()
                VStack(spacing: 0) {
                    if let line = model.currentLine { note(line, style: .secondary) }
                    if let hint = model.hint, model.datePick == nil { note(hint, style: .secondary) }
                    if model.datePick != nil {
                        TimePickerDatePick(model: model)
                    } else {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                            rowView(row, isCursor: index == model.cursor)
                        }
                    }
                }
                .padding(.vertical, OverlayMetrics.listPaddingY)
                if model.datePick == nil, model.offersOnlyIfNoReply {
                    Divider()
                    onlyIfNoReply
                }
                Divider()
                OverlayFooter { Text(model.footer).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .task { focused = true }
    }

    private var input: some View {
        OverlayFieldRow(symbol: Self.symbol(model.kind)) {
            TextField(model.title, text: Binding(get: { model.text }, set: { model.text = $0 }),
                      prompt: Text(model.placeholder))
                .overlayField()
                .focused($focused)
                .onSubmit { model.confirm() }
                .onKeyPress(.upArrow) { model.datePick == nil ? (model.moveCursor(by: -1), .handled).1 : (model.moveDay(by: -7), .handled).1 }
                .onKeyPress(.downArrow) { model.datePick == nil ? (model.moveCursor(by: 1), .handled).1 : (model.moveDay(by: 7), .handled).1 }
                .onKeyPress(.leftArrow) { model.datePick == nil ? .ignored : (model.moveDay(by: -1), .handled).1 }
                .onKeyPress(.rightArrow) { model.datePick == nil ? .ignored : (model.moveDay(by: 1), .handled).1 }
                .onKeyPress(.escape) {
                    if model.datePick != nil { model.closeDatePick() } else { dismiss() }
                    return .handled
                }
                .onKeyPress(characters: .decimalDigits, phases: .down) { press in
                    guard let digit = press.characters.first.flatMap({ Int(String($0)) }) else { return .ignored }
                    return model.chooseNumber(digit) ? .handled : .ignored
                }
                .accessibilityLabel(model.title)
        }
    }

    static func symbol(_ kind: TimePickerKind) -> String {
        kind == .remind ? "bell" : kind == .sendLater ? "paperplane" : "clock"
    }

    /// The SF Symbol in front of each row, by what the row does.
    static func symbol(_ kind: TimePickerModel.Row.Kind, id: String) -> String {
        switch kind {
        case .parsed: return "calendar.badge.checkmark"
        case .pickDate: return "calendar.badge.plus"
        case .clearReminder: return "bell.slash"
        case .wakeNow: return "alarm"
        case .snoozeAgain: return "moon.zzz"
        case .someday: return "infinity"
        case .preset:
            switch id {
            case "laterToday": return "clock"
            case "thisEvening": return "moon"
            case "tomorrowMorning": return "sunrise"
            case "tomorrowAfternoon": return "sun.max"
            case "weekend": return "beach.umbrella"
            case "nextWeek", "monday": return "calendar.badge.clock"
            case "inAMonth": return "calendar.circle"
            case "inAnHour": return "hourglass"
            default: return "calendar"
            }
        }
    }

    private func note(_ text: String, style: HierarchicalShapeStyle) -> some View {
        Text(text)
            .font(.system(size: NativeMetrics.Text.secondary))
            .foregroundStyle(style)
            .lineLimit(2)
            .padding(.horizontal, OverlayMetrics.panelInsetX)
            .frame(maxWidth: .infinity, minHeight: OverlayMetrics.rowHeight, alignment: .leading)
    }

    private func rowView(_ row: TimePickerModel.Row, isCursor: Bool) -> some View {
        let parsed = isParsed(row)
        return OverlayRow(isSelected: isCursor) { model.choose(row) } label: {
            HStack(spacing: OverlayMetrics.rowSpacing) {
                OverlayRowSymbol(symbol: Self.symbol(row.kind, id: row.id))
                Text(row.title)
                    .font(.system(size: NativeMetrics.Text.body, weight: parsed ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: OverlayMetrics.rowSpacing)
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(size: NativeMetrics.Text.secondary))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Group {
                    if let number = row.number {
                        OverlayShortcutHint("\(number)")
                    } else if parsed {
                        OverlayShortcutHint("↵")
                    }
                }
                .frame(width: OverlayMetrics.hintColumn, alignment: .trailing)
            }
        }
        .accessibilityLabel(row.title)
        .accessibilityValue(Self.accessibilityValue(row))
    }

    static func accessibilityValue(_ row: TimePickerModel.Row) -> String {
        [row.detail, row.number.map { "shortcut \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }

    private func isParsed(_ row: TimePickerModel.Row) -> Bool {
        if case .parsed = row.kind { true } else { false }
    }

    private var onlyIfNoReply: some View {
        OnlyIfNoReplyRow(isOn: Binding(get: { model.onlyIfNoReply }, set: { model.onlyIfNoReply = $0 }))
    }
}

/// "Pick a date…": the system calendar and a time field. The arrows in the picker's field move the day, Return
/// confirms, Escape goes back to the list.
struct TimePickerDatePick: View {
    let model: TimePickerModel

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = model.timeZone
        calendar.locale = model.locale
        calendar.firstWeekday = 2
        return calendar
    }

    var body: some View {
        if let pick = model.datePick {
            VStack(alignment: .leading, spacing: OverlayMetrics.rowSpacing) {
                dateGrid(pick)
                timeRow(pick)
            }
            .padding(.horizontal, OverlayMetrics.panelInsetX)
            .padding(.vertical, OverlayMetrics.listPaddingY)
        }
    }

    func dateGrid(_ pick: TimePickerModel.DatePick) -> some View {
        let calendar = self.calendar
        let day = Binding(get: { pick.day }, set: { model.selectDay(calendar.startOfDay(for: $0)) })
        return DatePicker("Date", selection: day, in: model.todayStart..., displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            .environment(\.calendar, calendar)
            .environment(\.timeZone, model.timeZone)
            .environment(\.locale, model.locale)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Date")
    }

    func timeRow(_ pick: TimePickerModel.DatePick) -> some View {
        HStack(spacing: OverlayMetrics.rowSpacing) {
            Text("Time")
                .font(.system(size: NativeMetrics.Text.body))
                .foregroundStyle(.secondary)
            TextField("Time", text: Binding(get: { pick.timeText }, set: { model.setTimeText($0) }), prompt: Text("9:00"))
                .textFieldStyle(.roundedBorder)
                .frame(width: OverlayMetrics.timeFieldWidth)
                .accessibilityLabel("Time")
                .onSubmit { model.confirm() }
            if let error = model.datePickError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: NativeMetrics.Text.secondary))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

struct OnlyIfNoReplyRow: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(TimePickerModel.onlyIfNoReplyLabel, isOn: $isOn)
            .ohCheckboxToggleStyle()
            .font(.system(size: NativeMetrics.Text.body))
            .padding(.horizontal, OverlayMetrics.panelInsetX)
            .frame(maxWidth: .infinity, minHeight: OverlayMetrics.rowHeight, alignment: .leading)
    }
}
