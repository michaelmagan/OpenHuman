import AppKit
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI

struct CalendarTimeGridView: View {
    @Bindable var model: CalendarWindowModel
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: GridDrag?
    @State private var userScrolled = false
    @State private var hoveredBlock: String?

    static let hourHeight: CGFloat = 44
    static let blockRadius: CGFloat = 5
    static let axisWidth: CGFloat = 56
    static let laneHeight: CGFloat = 20
    static let scrollAnchor = "calendar.window.scroll"
    static let gridSpace = "calendar.window.gridSpace"

    struct GridDrag: Equatable {
        enum Kind: Equatable {
            case create(dayIndex: Int, from: Double)
            case move(blockID: String)
            case resize(blockID: String)
            case movePending
            case resizePending
        }

        var kind: Kind
        var translation: CGSize = .zero
        var to: Double = 0
    }

    private var height: CGFloat { Self.hourHeight * 24 }

    var body: some View {
        let grid = model.timeGrid
        VStack(spacing: 0) {
            dayHeaders(grid)
            if grid.allDayLanes > 0 { allDayRow(grid) }
            Rectangle().fill(theme.borderHairline.color).frame(height: theme.borderWidthHairline)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        scrollMarker(grid)
                        hourLabels
                        GeometryReader { geometry in
                            let columnWidth = geometry.size.width / CGFloat(max(grid.days.count, 1))
                            ZStack(alignment: .topLeading) {
                                hourLines(width: geometry.size.width, grid: grid, columnWidth: columnWidth)
                                emptySlots(grid, columnWidth: columnWidth)
                                if let placement = model.pendingPlacement {
                                    pendingSlot(placement, grid: grid, columnWidth: columnWidth)
                                }
                                ForEach(grid.blocks) { block in
                                    eventBlock(block, grid: grid, columnWidth: columnWidth)
                                }
                                createPreview(columnWidth: columnWidth)
                                if let now = grid.now { nowLine(now, columnWidth: columnWidth) }
                            }
                            .coordinateSpace(.named(Self.gridSpace))
                        }
                        .frame(height: height)
                    }
                    .padding(.top, theme.space2)
                    .padding(.bottom, theme.space4)
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting || phase == .tracking { userScrolled = true }
                }
                .onAppear { scroll(proxy) }
                .onChange(of: model.period) {
                    userScrolled = false
                    scroll(proxy)
                }
                .onChange(of: model.state) { _, state in
                    // Why: the first read lands after the grid appeared; keep the opening hour until the user scrolls
                    if state == .loaded, !userScrolled { scroll(proxy) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.window.grid")
    }

    private func dayHeaders(_ grid: CalendarTimeGrid) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            Text(verbatim: grid.zoneLabel)
                .themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                .frame(width: Self.axisWidth - theme.space2, alignment: .trailing)
                .padding(.trailing, theme.space2)
                .accessibilityLabel("Times in \(model.timeZone.identifier)")
                .accessibilityIdentifier("calendar.window.zone")
            ForEach(grid.days, id: \.self) { day in
                let today = model.isToday(day)
                let header = model.dayHeader(day)
                Button {
                    if model.kind != .day { Task { await model.show(day: day, as: .day) } }
                } label: {
                    VStack(spacing: 2) {
                        Text(verbatim: header.weekday).themeFont(theme.typeCaption)
                            .foregroundStyle((today ? theme.accentText : theme.textTertiary).color)
                        Text(verbatim: header.number).themeFont(theme.typeHeadline)
                            .foregroundStyle((today ? theme.accentOnFill : theme.textPrimary).color)
                            .frame(minWidth: 28, minHeight: 28)
                            .background { if today { Circle().fill(theme.accentFill.color) } }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.kind == .day ? "" : String(localized: "Show this day  D"))
                .accessibilityLabel(day.formatted(Date.FormatStyle(timeZone: model.timeZone).weekday(.wide).month(.wide).day()))
                .accessibilityAddTraits(today ? [.isHeader, .isSelected] : .isHeader)
            }
        }
        .padding(.vertical, theme.space2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("calendar.window.dayHeaders")
    }

    private func allDayRow(_ grid: CalendarTimeGrid) -> some View {
        HStack(spacing: 0) {
            Text("all-day").themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                .frame(width: Self.axisWidth - theme.space2, alignment: .trailing)
                .padding(.trailing, theme.space2)
            GeometryReader { geometry in
                let columnWidth = geometry.size.width / CGFloat(max(grid.days.count, 1))
                ZStack(alignment: .topLeading) {
                    ForEach(grid.allDay) { bar in
                        let selected = model.selectedEventID == bar.event.copyKey
                        let colors = CalendarPalette.block(bar.colorIndex, state: selected ? .selected : .normal,
                                                           tokens: theme.tokens)
                        let span = CGFloat(bar.lastDay - bar.firstDay + 1)
                        let hovered = hoveredBlock == "allDay.\(bar.id)"
                        Button { model.openEvent(bar.event) } label: {
                            Text(bar.event.title).themeFont(theme.typeCaption).fontWeight(.semibold)
                                .foregroundStyle(colors.text.color)
                                .lineLimit(1).truncationMode(.tail)
                                .padding(.horizontal, theme.space2)
                                .frame(width: max(span * columnWidth - 4, 8), height: Self.laneHeight - 2, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: Self.blockRadius, style: .continuous)
                                    .fill(colors.fill.color))
                                .overlay {
                                    if hovered, !selected {
                                        RoundedRectangle(cornerRadius: Self.blockRadius, style: .continuous)
                                            .fill(theme.textPrimary.color.opacity(Self.hoverOpacity))
                                            .allowsHitTesting(false)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in hover("allDay.\(bar.id)", inside) }
                        .calendarPopoverAnchor(!bar.event.id.isEmpty && model.card?.event.copyKey == bar.event.copyKey)
                        .offset(x: CGFloat(bar.firstDay) * columnWidth + 2, y: CGFloat(bar.lane) * Self.laneHeight + 1)
                        .help(bar.event.title)
                        .accessibilityLabel("\(bar.event.title), all day")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            .frame(height: CGFloat(grid.allDayLanes) * Self.laneHeight + 2)
        }
        .padding(.bottom, theme.space1)
        .accessibilityIdentifier("calendar.window.allDay")
    }

    private func scrollMarker(_ grid: CalendarTimeGrid) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: 1, height: max(CGFloat(grid.openingHour) * Self.hourHeight
                                                    - CGFloat(CalendarTimeGrid.openingLead) * Self.hourHeight, 0))
            Color.clear.frame(width: 1, height: 1).id(Self.scrollAnchor)
            Spacer(minLength: 0)
        }
        .frame(width: 1, height: height, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async { proxy.scrollTo(Self.scrollAnchor, anchor: .top) }
    }

    private var hourLabels: some View {
        ZStack(alignment: .topLeading) {
            ForEach(1..<24, id: \.self) { hour in
                Text(Self.hourText(hour, timeZone: model.timeZone))
                    .themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                    .frame(width: Self.axisWidth - theme.space3, alignment: .trailing)
                    .offset(y: CGFloat(hour) * Self.hourHeight - 7)
            }
        }
        .frame(width: Self.axisWidth - 1, height: height, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    static func hourText(_ hour: Int, timeZone: TimeZone) -> String {
        let calendar = CalendarDateMentions.calendar(timeZone)
        let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: hour)) ?? Date()
        return date.formatted(Date.FormatStyle(timeZone: timeZone).hour())
    }

    private func hourLines(width: CGFloat, grid: CalendarTimeGrid, columnWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<25, id: \.self) { hour in
                Rectangle().fill(theme.borderHairline.color)
                    .frame(width: width, height: theme.borderWidthHairline)
                    .offset(y: CGFloat(hour) * Self.hourHeight)
            }
            ForEach(0...grid.days.count, id: \.self) { index in
                Rectangle().fill(theme.borderHairline.color)
                    .frame(width: theme.borderWidthHairline, height: height)
                    .offset(x: CGFloat(index) * columnWidth)
            }
        }
        .allowsHitTesting(false)
    }

    private func emptySlots(_ grid: CalendarTimeGrid, columnWidth: CGFloat) -> some View {
        ForEach(Array(grid.days.enumerated()), id: \.offset) { index, day in
            Rectangle().fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: columnWidth, height: height)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        drag = GridDrag(kind: .create(dayIndex: index, from: Double(value.startLocation.y / height)),
                                        to: Double(value.location.y / height))
                    }
                    .onEnded { value in
                        drag = nil
                        let (start, end) = slot(on: day, from: value.startLocation.y, to: value.location.y,
                                                moved: abs(value.translation.height) > 4)
                        Task { await model.newEvent(start: start, end: end) }
                    })
                .offset(x: CGFloat(index) * columnWidth)
                .accessibilityElement()
                .accessibilityLabel("Empty time on \(day.formatted(Date.FormatStyle(timeZone: model.timeZone).weekday(.wide)))")
                .accessibilityAddTraits(.isButton)
        }
    }

    private func slot(on day: Date, from a: CGFloat, to b: CGFloat, moved: Bool) -> (Date, Date) {
        let calendar = CalendarDateMentions.calendar(model.timeZone)
        guard moved else {
            let halfHour = (Double(a / height) * 48).rounded(.down) / 48
            let start = CalendarDragMath.time(atFraction: halfHour, on: day, calendar: calendar)
            return (start, start.addingTimeInterval(30 * 60))
        }
        let slot = CalendarDragMath.slot(from: CalendarDragMath.time(atFraction: Double(a / height), on: day, calendar: calendar),
                                         to: CalendarDragMath.time(atFraction: Double(b / height), on: day, calendar: calendar))
        return (slot.start, slot.end)
    }

    @ViewBuilder
    private func createPreview(columnWidth: CGFloat) -> some View {
        if let drag, case .create(let index, let from) = drag.kind, abs(drag.to - from) * Double(height) > 4 {
            let top = CGFloat(min(from, drag.to)) * height
            let span = max(CGFloat(abs(drag.to - from)) * height, 12)
            RoundedRectangle(cornerRadius: Self.blockRadius, style: .continuous)
                .fill(theme.accentSubtle.color)
                .overlay(RoundedRectangle(cornerRadius: Self.blockRadius, style: .continuous)
                    .strokeBorder(theme.accentFill.color, lineWidth: 1.5))
                .frame(width: columnWidth - 4, height: span)
                .offset(x: CGFloat(index) * columnWidth + 2, y: top)
                .allowsHitTesting(false)
        }
    }

    static let pendingID = "pending"

    // The event being prepared moves and stretches like a saved one; the editor beside it follows it
    private func pendingSlot(_ placement: (dayIndex: Int, top: Double, height: Double), grid: CalendarTimeGrid,
                             columnWidth: CGFloat) -> some View {
        let title = model.sidebar.draft?.title ?? ""
        let movable = model.sidebar.draft?.isAllDay == false
        var x = CGFloat(placement.dayIndex) * columnWidth + 2
        var y = CGFloat(placement.top) * height
        var slotHeight = max(CGFloat(placement.height) * height - 1, 16)
        if let drag {
            switch drag.kind {
            case .movePending:
                x += CGFloat(Self.dayIndex(placement.dayIndex, shiftedBy: drag.translation.width, columnWidth: columnWidth,
                                           days: grid.days.count) - placement.dayIndex) * columnWidth
                y += Self.snapped(drag.translation.height)
            case .resizePending:
                slotHeight = max(slotHeight + Self.snapped(drag.translation.height), Self.hourHeight / 4)
            default:
                break
            }
        }
        let shape = RoundedRectangle(cornerRadius: Self.blockRadius, style: .continuous)
        let dragging = drag?.kind == .movePending || drag?.kind == .resizePending
        return Text(title.isEmpty ? String(localized: "New event") : title)
            .themeFont(theme.typeCaption).fontWeight(.medium).foregroundStyle(theme.textPrimary.color)
            .lineLimit(2)
            .padding(theme.space1)
            .frame(width: columnWidth - 4, height: slotHeight, alignment: .topLeading)
            .background(shape.fill(theme.accentSubtle.color))
            .overlay(shape.strokeBorder(theme.accentFill.color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            .contentShape(shape)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("The event you're preparing")
            .accessibilityIdentifier("calendar.window.pendingSlot")
            .overlay(alignment: .bottom) {
                if movable {
                    resizeHandle(.resizePending, label: "Change when the event you're preparing ends",
                                 shown: hoveredBlock == Self.pendingID && slotHeight >= 24) { dy in
                        let calendar = CalendarDateMentions.calendar(model.timeZone)
                        let fraction = placement.top + placement.height + Double(dy / height)
                        let end = CalendarDragMath.time(atFraction: fraction, on: grid.days[placement.dayIndex], calendar: calendar)
                        settle { model.resizePending(to: end) }
                    }
                }
            }
            .onHover { inside in hover(Self.pendingID, inside) }
            .calendarPopoverAnchor(model.showsPendingCard)
            .gesture(pendingMoveGesture(placement, grid: grid, columnWidth: columnWidth, enabled: movable))
            .offset(x: x, y: y)
            .transaction { transaction in if drag != nil { transaction.animation = nil } }
            .zIndex(dragging ? 1 : 0)
    }

    // A click without a drag keeps the editor open; a drag of 4 points or more moves the event by quarter hours,
    // across days too, and keeps its length
    private func pendingMoveGesture(_ placement: (dayIndex: Int, top: Double, height: Double), grid: CalendarTimeGrid,
                                    columnWidth: CGFloat, enabled: Bool) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                guard enabled else { return }
                drag = GridDrag(kind: .movePending, translation: value.translation)
            }
            .onEnded { value in
                guard enabled else {
                    drag = nil
                    return
                }
                let calendar = CalendarDateMentions.calendar(model.timeZone)
                let dayIndex = Self.dayIndex(placement.dayIndex, shiftedBy: value.translation.width, columnWidth: columnWidth,
                                             days: grid.days.count)
                let fraction = placement.top + Double(value.translation.height / height)
                let start = CalendarDragMath.time(atFraction: fraction, on: grid.days[dayIndex], calendar: calendar)
                settle { model.movePending(to: start) }
            }
    }

    // The block lands where it was dropped and the editor moves with it, without animation when motion is reduced
    private func settle(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            drag = nil
            change()
        }
    }

    static func dayIndex(_ index: Int, shiftedBy dx: CGFloat, columnWidth: CGFloat, days: Int) -> Int {
        let shift = columnWidth > 0 ? Int((dx / columnWidth).rounded()) : 0
        return min(max(index + shift, 0), max(days - 1, 0))
    }

    private func eventBlock(_ block: CalendarTimeGrid.Block, grid: CalendarTimeGrid, columnWidth: CGFloat) -> some View {
        let gap: CGFloat = 2
        let inner = columnWidth - 4
        let width = (inner - gap * CGFloat(block.columns - 1)) / CGFloat(max(block.columns, 1))
        var x = CGFloat(block.dayIndex) * columnWidth + 2 + CGFloat(block.column) * (width + gap)
        var y = CGFloat(block.top) * height
        var blockHeight = max(CGFloat(block.height) * height - 1, 14)
        if let drag {
            switch drag.kind {
            case .move(let id) where id == block.id:
                x += (drag.translation.width / columnWidth).rounded() * columnWidth
                y += Self.snapped(drag.translation.height)
            case .resize(let id) where id == block.id:
                blockHeight = max(blockHeight + Self.snapped(drag.translation.height), Self.hourHeight / 4)
            default:
                break
            }
        }
        let movable = block.event.isMovableByMe && !block.startsBefore && !block.endsAfter
        let hovered = hoveredBlock == block.id
        return CalendarEventBlockView(block: block, isSelected: model.selectedEventID == block.event.copyKey,
                                      isHovered: hovered, height: blockHeight, model: model)
            .frame(width: max(width, 8), height: blockHeight)
            .overlay(alignment: .bottom) {
                if movable {
                    resizeHandle(.resize(blockID: block.id), label: "Change when \(block.event.title) ends",
                                 shown: hovered && blockHeight >= 24) { dy in
                        drag = nil
                        let calendar = CalendarDateMentions.calendar(model.timeZone)
                        let fraction = block.top + block.height + Double(dy / height)
                        let end = CalendarDragMath.time(atFraction: fraction, on: grid.days[block.dayIndex], calendar: calendar)
                        let resized = CalendarDragMath.resized(block.event, to: end)
                        dragEnded(block.event, proposedStart: resized.start, proposedEnd: resized.end)
                    }
                }
            }
            .onHover { inside in hover(block.id, inside) }
            .calendarPopoverAnchor(!block.event.id.isEmpty && model.card?.event.copyKey == block.event.copyKey)
            .onTapGesture { model.openEvent(block.event) }
            .gesture(moveGesture(block, grid: grid, columnWidth: columnWidth, enabled: movable))
            .offset(x: x, y: y)
            .transaction { transaction in if drag != nil { transaction.animation = nil } }
            .zIndex(drag.map { $0.kind == .move(blockID: block.id) || $0.kind == .resize(blockID: block.id) } == true ? 1 : 0)
    }

    static let hoverOpacity = 0.07

    private func hover(_ id: String, _ inside: Bool) {
        if inside { hoveredBlock = id } else if hoveredBlock == id { hoveredBlock = nil }
    }

    static func snapped(_ dy: CGFloat) -> CGFloat {
        CalendarDragState.snapped(dy, hourHeight: hourHeight)
    }

    private func dragEnded(_ event: CalendarEvent, proposedStart: Date, proposedEnd: Date) {
        Task { await model.moveEvent(event, to: proposedStart, end: proposedEnd) }
    }

    private func moveGesture(_ block: CalendarTimeGrid.Block, grid: CalendarTimeGrid, columnWidth: CGFloat,
                             enabled: Bool) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                guard enabled else { return }
                drag = GridDrag(kind: .move(blockID: block.id), translation: value.translation)
            }
            .onEnded { value in
                drag = nil
                guard enabled else { return }
                let calendar = CalendarDateMentions.calendar(model.timeZone)
                let dayDelta = Int((value.translation.width / columnWidth).rounded())
                let dayIndex = min(max(block.dayIndex + dayDelta, 0), grid.days.count - 1)
                let fraction = block.top + Double(value.translation.height / height)
                let start = CalendarDragMath.time(atFraction: fraction, on: grid.days[dayIndex], calendar: calendar)
                let moved = CalendarDragMath.moved(block.event, to: start)
                dragEnded(block.event, proposedStart: moved.start, proposedEnd: moved.end)
            }
    }

    // The bottom edge drags the end; a grip shows there while the pointer is over the event
    private func resizeHandle(_ kind: GridDrag.Kind, label: LocalizedStringKey, shown: Bool,
                              ended: @escaping (CGFloat) -> Void) -> some View {
        Rectangle().fill(Color.clear)
            .frame(height: 6)
            .overlay {
                if shown {
                    Capsule().fill(theme.textPrimary.color.opacity(0.35))
                        .frame(width: 18, height: 3)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.gridSpace))
                .onChanged { value in drag = GridDrag(kind: kind, translation: value.translation) }
                .onEnded { value in ended(value.translation.height) })
            .accessibilityLabel(label)
    }

    private func nowLine(_ now: CalendarTimeGrid.NowMark, columnWidth: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(theme.textDanger.color).frame(width: columnWidth, height: 1.5)
            Circle().fill(theme.textDanger.color).frame(width: 9, height: 9).offset(x: -4.5)
        }
        .frame(width: columnWidth, height: 9)
        .offset(x: CGFloat(now.dayIndex) * columnWidth, y: CGFloat(now.offset) * height - 4.5)
        .allowsHitTesting(false)
        .accessibilityLabel("Now")
        .accessibilityIdentifier("calendar.window.now")
    }
}

struct CalendarEventBlockView: View {
    let block: CalendarTimeGrid.Block
    let isSelected: Bool
    var isHovered = false
    let height: CGFloat
    let model: CalendarWindowModel
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        let event = block.event
        let state = CalendarPalette.state(isSelected: isSelected, isDeclined: block.isDeclined,
                                          needsAnswer: event.canRespond && event.myResponse == .needsAction,
                                          isTentative: block.isTentative, isPast: block.isPast)
        let colors = CalendarPalette.block(block.colorIndex, state: state, tokens: theme.tokens)
        let content = CalendarPalette.content(height: Double(height))
        let shape = RoundedRectangle(cornerRadius: CalendarTimeGridView.blockRadius, style: .continuous)
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(colors.bar.color).frame(width: 3)
            Group {
                if content == .oneLine {
                    oneLine(event, ink: colors.text)
                } else {
                    stacked(event, ink: colors.text, content: content)
                }
            }
            .padding(.leading, theme.space1 + 2)
            .padding(.top, content == .oneLine ? 1 : 3)
            Spacer(minLength: 0)
            if let link = event.meetLink, height > 20 {
                Button { openURL(link) } label: { Image(systemName: "video").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(colors.text.color)
                    .padding(.top, 3).padding(.trailing, theme.space1)
                    .help("Join Google Meet").accessibilityLabel("Join Google Meet")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.fill.color)
        .overlay {
            if isHovered, !isSelected {
                theme.textPrimary.color.opacity(CalendarTimeGridView.hoverOpacity).allowsHitTesting(false)
            }
        }
        .clipShape(shape)
        .overlay {
            if let border = colors.border {
                shape.strokeBorder(border.color, style: StrokeStyle(lineWidth: 1, dash: colors.dashedBorder ? [3, 2] : []))
            }
        }
        .overlay {
            // A hairline of the window's colour keeps two touching events apart
            shape.strokeBorder(theme.bgWindow.color.opacity(0.9), lineWidth: 0.5).allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(isSelected ? 0.22 : 0), radius: isSelected ? 3 : 0, y: isSelected ? 1 : 0)
        .contentShape(Rectangle())
        .help(event.title + "\n" + model.timeText(event) + (event.location.map { "\n" + $0 } ?? "")
              + (event.account.map { "\n" + $0 } ?? ""))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title), \(model.timeText(event))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("calendar.window.event")
    }

    private func title(_ event: CalendarEvent, ink: ThemeColor) -> Text {
        Text(event.title)
            .font(theme.typeCaption.swiftUIFont)
            .fontWeight(.semibold)
            .foregroundStyle(ink.color)
            .strikethrough(block.isDeclined)
    }

    private func startText(_ event: CalendarEvent) -> String {
        event.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: model.timeZone))
    }

    private func oneLine(_ event: CalendarEvent, ink: ThemeColor) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: theme.space1) {
                title(event, ink: ink).lineLimit(1).fixedSize()
                Text(verbatim: startText(event)).themeFont(theme.typeCaption).fontWeight(.regular)
                    .foregroundStyle(ink.color).lineLimit(1).fixedSize()
            }
            title(event, ink: ink).lineLimit(1)
        }
    }

    private func stacked(_ event: CalendarEvent, ink: ThemeColor, content: CalendarPalette.BlockContent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // A single word gets one line, so a narrow block ends it with an ellipsis rather than breaking it
            title(event, ink: ink).lineLimit(height >= 44 && event.title.contains(where: \.isWhitespace) ? 2 : 1)
            Text(model.timeText(event)).themeFont(theme.typeCaption).fontWeight(.regular)
                .foregroundStyle(ink.color).lineLimit(1)
            if content == .withPlace || content == .withAccount, let place = event.location {
                Text(place).themeFont(theme.typeCaption).fontWeight(.regular).foregroundStyle(ink.color).lineLimit(1)
            }
            if content == .withAccount, let account = event.account {
                Text(verbatim: account).themeFont(theme.typeCaption).fontWeight(.regular).foregroundStyle(ink.color)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }
}
