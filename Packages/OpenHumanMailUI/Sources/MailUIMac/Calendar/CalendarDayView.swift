import AppKit
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI

struct CalendarDayView: View {
    @Bindable var model: CalendarSidebarModel
    let day: CalendarSidebarModel.Day
    var strikesConflicts = false
    var showsHeader = true
    var takeKeys: () -> Void = {}
    var compact = false
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let hourHeight: CGFloat = 44
    static let axisWidth: CGFloat = 46
    static let focusAnchor = "calendar.day.focus"
    static let eventAnchor = "calendar.day.event"
    static let labelRoom: CGFloat = 8
    static let hoursMinHeight: CGFloat = 220
    static let hoursIdealHeight: CGFloat = 360
    static let hoursMaxHeight: CGFloat = 420
    // How much of their ideal height the hours give up in the sidebar so the free times under them stay in view
    static let hoursGiveUp: CGFloat = hoursIdealHeight - hoursMinHeight
    // With a clicked time over events, the events keep this share of the column on the left
    static let besidePickedShare: CGFloat = 0.42

    var body: some View {
        let timeline = model.timeline(for: day)
        VStack(alignment: .leading, spacing: theme.space2) {
            if showsHeader { header }
            if let progress = model.progress {
                Text(progress.text).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                    .accessibilityIdentifier("calendar.day.updating")
            }
            if let note = model.refreshNote {
                Text(note).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                    .accessibilityIdentifier("calendar.day.couldNotRefresh")
            }
            if !timeline.allDay.isEmpty { allDayBars(timeline.allDay) }
            if showsPicked, timeline.focus == nil, let picked = model.pickedTime {
                CalendarPickedTimeChip(model: model, picked: picked, takeKeys: takeKeys)
            }
            axis(timeline)
            if let note = day.note {
                Text(note).themeFont(theme.typeMeta).foregroundStyle(theme.textWarning.color)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.dayHeader(day))
        .accessibilityIdentifier("calendar.dayView")
    }

    private var header: some View {
        HStack(spacing: theme.space2) {
            Button { takeKeys(); model.moveDayInstantly(by: -1) } label: {
                Image(systemName: "chevron.left").frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(theme.textSecondary.color)
            .dayKeyTip(.previousDay).accessibilityLabel("Previous day")
            Text(model.dayHeader(day)).themeFont(theme.typeBodyStrong).foregroundStyle(theme.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
            Button { takeKeys(); model.moveDayInstantly(by: 1) } label: {
                Image(systemName: "chevron.right").frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(theme.textSecondary.color)
            .dayKeyTip(.nextDay).accessibilityLabel("Next day")
            if day.isMentioned {
                Image(systemName: "text.bubble").font(.system(size: 11)).foregroundStyle(theme.textTertiary.color)
                    .help("Mentioned in this conversation").accessibilityLabel("Mentioned in this conversation")
            }
            Spacer(minLength: 0)
            Button("Today") { takeKeys(); model.goToTodayInstantly() }
                .buttonStyle(.borderless).themeFont(theme.typeMeta).dayKeyTip(.today)
        }
        .accessibilityIdentifier("calendar.dayView.header")
    }

    private func allDayBars(_ events: [CalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(events) { event in
                let opened = model.isOpened(event)
                let colors = CalendarPalette.block(CalendarDayTimeline.colorIndex(for: event),
                                                   state: opened ? .selected : .normal, tokens: theme.tokens)
                Text(event.title).themeFont(theme.typeCaption).fontWeight(.semibold)
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, theme.space2).padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: theme.radiusSM).fill(colors.fill.color))
                    .overlay { if model.isFocused(event) { focusRing } }
                    .contentShape(Rectangle())
                    .onTapGesture { open(event) }
                    .help(event.title)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(event.title), all day")
                    .accessibilityHint("Shows the event's details")
                    .accessibilityAddTraits(opened ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { open(event) }
                    .accessibilityIdentifier("calendar.dayView.allDayEvent")
            }
        }
        .padding(.leading, Self.axisWidth)
        .accessibilityIdentifier("calendar.dayView.allDay")
    }

    private func open(_ event: CalendarEvent) {
        takeKeys()
        model.openEvent(event)
    }

    private var focusRing: some View {
        RoundedRectangle(cornerRadius: 5).strokeBorder(theme.accentFill.color, lineWidth: 2).padding(-1)
            .allowsHitTesting(false)
    }

    private func axis(_ timeline: CalendarDayTimeline) -> some View {
        let height = Self.hourHeight * CGFloat(CalendarDayTimeline.hours.count)
        return VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: timeline.zoneLabel)
                .themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                .frame(width: Self.axisWidth - theme.space2, alignment: .trailing)
                .help(model.zonesText)
                .accessibilityLabel(model.zonesText)
                .accessibilityIdentifier("calendar.dayView.zone")
            axisScroll(timeline, height: height)
        }
        .accessibilityIdentifier("calendar.dayView.axis")
    }

    private func axisScroll(_ timeline: CalendarDayTimeline, height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    scrollMarker(timeline, height: height)
                        .overlay(alignment: .top) { eventMarker(timeline, height: height) }
                    hourLabels(timeline, height: height)
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        ZStack(alignment: .topLeading) {
                            hourLines(timeline, width: width, height: height)
                            let beside = showsPicked && !timeline.conflicts.isEmpty
                            if let focus = timeline.focus, !showsPicked { focusSlot(focus, width: width, height: height) }
                            ForEach(timeline.blocks) { block in
                                eventBlock(block, width: beside && block.isConflict ? eventLane(width) : width,
                                           height: height)
                            }
                            if let now = timeline.now { nowLine(at: now, width: width, height: height) }
                            if let focus = timeline.focus, showsPicked {
                                pickedBlock(focus, beside: beside, width: width, height: height)
                                    .transition(pickedTransition)
                            }
                        }
                    }
                    .frame(height: height)
                }
                .padding(.top, Self.labelRoom)
                .padding(.bottom, theme.space2)
                .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.18), value: model.pickedTime)
            }
            .frame(minHeight: compact ? 132 : Self.hoursMinHeight,
                   idealHeight: compact ? 176 : Self.hoursIdealHeight,
                   maxHeight: compact ? 176 : Self.hoursMaxHeight)
            .onAppear { scrollToFocus(timeline, proxy) }
            .onChange(of: timeline.focus) { scrollToFocus(timeline, proxy) }
            .onChange(of: day.start) { scrollToFocus(timeline, proxy) }
            .onChange(of: model.focusedEventKey) {
                // Why: a clicked event is already in view, and an open card covers the day
                guard model.openedEvent == nil, focusedBlock(timeline) != nil else { return }
                DispatchQueue.main.async { proxy.scrollTo(Self.eventAnchor, anchor: .center) }
            }
        }
    }

    private func focusedBlock(_ timeline: CalendarDayTimeline) -> CalendarDayTimeline.Block? {
        timeline.blocks.first { model.isFocused($0.event) }
    }

    private func eventMarker(_ timeline: CalendarDayTimeline, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            if let chosen = focusedBlock(timeline) {
                Color.clear.frame(width: 1, height: CGFloat(chosen.top) * height)
                Color.clear.frame(width: 1, height: max(CGFloat(chosen.height) * height, 1)).id(Self.eventAnchor)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 1, height: height, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func scrollMarker(_ timeline: CalendarDayTimeline, height: CGFloat) -> some View {
        let span: (top: Double, height: Double)? = timeline.focus.map { ($0.top, $0.height) } ?? timeline.now.map { ($0, 0) }
        return VStack(spacing: 0) {
            if let span {
                Color.clear.frame(width: 1, height: CGFloat(span.top) * height)
                Color.clear.frame(width: 1, height: max(CGFloat(span.height) * height, 1)).id(Self.focusAnchor)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 1, height: height, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func scrollToFocus(_ timeline: CalendarDayTimeline, _ proxy: ScrollViewProxy) {
        guard timeline.focus != nil || timeline.now != nil else { return }
        DispatchQueue.main.async { proxy.scrollTo(Self.focusAnchor, anchor: .center) }
    }

    private func hourLabels(_ timeline: CalendarDayTimeline, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(timeline.hourMarks, id: \.date) { mark in
                Text(mark.date.formatted(Date.FormatStyle(timeZone: model.timeZone).hour()))
                    .themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                    .frame(width: Self.axisWidth - theme.space2, alignment: .trailing)
                    .offset(y: CGFloat(mark.offset) * height - 7)
            }
        }
        .frame(width: Self.axisWidth, height: height, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func hourLines(_ timeline: CalendarDayTimeline, width: CGFloat, height: CGFloat) -> some View {
        ForEach(timeline.hourMarks, id: \.date) { mark in
            Rectangle().fill(theme.borderHairline.color)
                .frame(width: width, height: theme.borderWidthHairline)
                .offset(y: CGFloat(mark.offset) * height)
        }
    }

    private func focusSlot(_ focus: CalendarDayTimeline.Span, width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(theme.accentSubtle.color)
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(theme.accentFill.color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            .frame(width: width, height: max(CGFloat(focus.height) * height, 12))
            .offset(y: CGFloat(focus.top) * height)
            .help(model.timeText(focus.start, focus.end))
            .accessibilityLabel("Proposed time, \(model.timeText(focus.start, focus.end))")
            .accessibilityIdentifier("calendar.dayView.focus")
    }

    private var showsPicked: Bool { !compact && model.showsPickedTime }

    private var pickedTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .center).combined(with: .opacity)
    }

    private static let laneGap: CGFloat = 3

    private func eventLane(_ width: CGFloat) -> CGFloat {
        (width * Self.besidePickedShare).rounded(.down)
    }

    // The clicked time, drawn as a finished block: it reads as a new event and creates one when clicked.
    // Over events it takes the free right part of the column, and those events move to the left part, so no
    // title sits under it.
    private func pickedBlock(_ focus: CalendarDayTimeline.Span, beside: Bool, width: CGFloat,
                             height: CGFloat) -> some View {
        let blockHeight = max(CGFloat(focus.height) * height - 1, 22)
        let blockWidth = beside ? width - eventLane(width) - Self.laneGap : width
        let time = model.timeText(focus.start, focus.end)
        return CalendarPickedBlock(time: time, tall: blockHeight >= 38,
                                   create: { takeKeys(); Task { await model.createEventAtPickedTime() } },
                                   dismiss: { takeKeys(); model.dismissPickedTime() })
            .frame(width: blockWidth, height: blockHeight)
            .offset(x: width - blockWidth, y: CGFloat(focus.top) * height)
            .accessibilityIdentifier("calendar.dayView.pickedTime")
    }

    private func eventBlock(_ block: CalendarDayTimeline.Block, width: CGFloat, height: CGFloat) -> some View {
        let gap: CGFloat = 2
        let columnWidth = (width - gap * CGFloat(block.columns - 1)) / CGFloat(max(block.columns, 1))
        let struck = strikesConflicts && block.isConflict
        let opened = model.isOpened(block.event)
        let event = block.event
        let state = CalendarPalette.state(isSelected: opened, isDeclined: event.myResponse == .declined,
                                          needsAnswer: event.canRespond && event.myResponse == .needsAction,
                                          isTentative: false, isPast: event.end <= model.now())
        let colors = CalendarPalette.block(block.colorIndex, state: state, tokens: theme.tokens)
        let ink = struck ? theme.textTertiary : colors.text
        let blockHeight = max(CGFloat(block.height) * height - 1, 14)
        let shape = RoundedRectangle(cornerRadius: theme.radiusSM)
        return HStack(alignment: .top, spacing: theme.space1) {
            Rectangle().fill(colors.bar.color).frame(width: 3)
            VStack(alignment: .leading, spacing: 0) {
                Text(block.event.title)
                    .themeFont(theme.typeCaption).fontWeight(.semibold)
                    .foregroundStyle(ink.color)
                    .strikethrough(struck || event.myResponse == .declined)
                    .lineLimit(blockHeight > 30 ? 2 : 1)
                if blockHeight > 26 {
                    Text(model.timeText(block.event.start, block.event.end))
                        .themeFont(theme.typeCaption).fontWeight(.regular).foregroundStyle(ink.color)
                        .strikethrough(struck)
                        .lineLimit(1)
                }
                if let account = block.event.account, blockHeight > 40 {
                    Text(verbatim: account).themeFont(theme.typeCaption).fontWeight(.regular).foregroundStyle(ink.color)
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityLabel("Calendar of \(account)")
                }
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
            if let link = block.event.meetLink, blockHeight > 18 {
                Button { openURL(link) } label: { Image(systemName: "video").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(ink.color)
                    .padding(.top, 2)
                    .help("Join Google Meet").accessibilityLabel("Join Google Meet")
                    .accessibilityIdentifier("calendar.event.meet")
            }
        }
        .padding(.trailing, theme.space1)
        .frame(width: max(columnWidth, 8), height: blockHeight, alignment: .topLeading)
        .background(colors.fill.color)
        .clipShape(shape)
        .overlay {
            if block.isConflict {
                shape.strokeBorder(theme.textDanger.color, lineWidth: 1.5)
            } else if let border = colors.border {
                shape.strokeBorder(border.color, style: StrokeStyle(lineWidth: 1, dash: colors.dashedBorder ? [3, 2] : []))
            }
        }
        .overlay { if model.isFocused(block.event) { focusRing } }
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .onTapGesture { open(block.event) }
        .offset(x: CGFloat(block.column) * (columnWidth + gap), y: CGFloat(block.top) * height)
        .help(block.event.title + "\n" + model.timeText(block.event.start, block.event.end)
              + (block.event.account.map { "\n" + $0 } ?? ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(block.isConflict
            ? "\(block.event.title), \(model.timeText(block.event.start, block.event.end)), conflicts with the proposed time"
            : "\(block.event.title), \(model.timeText(block.event.start, block.event.end))")
        .accessibilityHint("Shows the event's details")
        .accessibilityAddTraits(opened ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { open(block.event) }
        .accessibilityActions {
            if let link = block.event.meetLink {
                Button("Join Google Meet") { openURL(link) }
            }
        }
        .accessibilityIdentifier(block.isConflict ? "calendar.dayView.conflict" : "calendar.dayView.event")
    }

    private func nowLine(at offset: Double, width: CGFloat, height: CGFloat) -> some View {
        let y = CGFloat(offset) * height
        return ZStack(alignment: .leading) {
            Rectangle().fill(theme.textDanger.color).frame(width: width, height: 1.5)
            Circle().fill(theme.textDanger.color).frame(width: 8, height: 8).offset(x: -4)
        }
        .frame(width: width, height: 8)
        .offset(y: y - 4)
        .accessibilityLabel("Now")
        .accessibilityIdentifier("calendar.dayView.now")
    }

    static func calendarColor(_ index: Int, theme: ResolvedTheme) -> Color {
        CalendarPalette.ink(index, tokens: theme.tokens).color
    }
}

struct CalendarPickedBlock: View {
    let time: String
    let tall: Bool
    let create: () -> Void
    let dismiss: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        let accent = theme.accentFill.color
        let shape = RoundedRectangle(cornerRadius: theme.radiusSM + 1, style: .continuous)
        Button(action: create) {
            HStack(alignment: tall ? .top : .center, spacing: theme.space2) {
                Capsule().fill(accent).frame(width: 3).padding(.vertical, 3)
                if tall {
                    VStack(alignment: .leading, spacing: 1) {
                        title
                        Text(verbatim: time).themeFont(theme.typeCaption).foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1)
                    }
                    .padding(.top, 3)
                } else {
                    HStack(spacing: theme.space2) {
                        title
                        Text(verbatim: time).themeFont(theme.typeCaption).foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1).layoutPriority(-1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.trailing, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(shape.fill(accent.opacity(hovered ? 0.22 : 0.14)))
            .background(shape.fill(theme.component.sidebar.bg.color))
            .overlay(shape.strokeBorder(accent.opacity(hovered ? 0.9 : 0.6), lineWidth: 1))
            .clipShape(shape)
            .shadow(color: accent.opacity(hovered ? 0.28 : 0.16), radius: hovered ? 8 : 5, y: hovered ? 3 : 2)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay(alignment: tall ? .topTrailing : .trailing) {
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 2).padding(.top, tall ? 2 : 0)
            .help("Hide this time")
            .accessibilityLabel("Hide this time")
            .accessibilityIdentifier("calendar.dayView.pickedTime.dismiss")
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovered = inside }
        }
        .help("Create an event at \(time)  ↵")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Create event, \(time)")
        .accessibilityHint("Opens a new event at this time, filled in from the conversation")
    }

    private var title: some View {
        Label {
            Text("Create event").themeFont(theme.typeCaption).fontWeight(.semibold)
                .foregroundStyle(theme.textPrimary.color)
        } icon: {
            Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.accentFill.color)
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
    }
}

// The clicked time when it falls outside the hours the day view draws
struct CalendarPickedTimeChip: View {
    let model: CalendarSidebarModel
    let picked: CalendarSidebarModel.PickedTime
    var takeKeys: () -> Void = {}
    @Environment(\.theme) private var theme

    var body: some View {
        let time = model.timeText(picked.start, picked.end)
        CalendarPickedBlock(time: time, tall: false,
                            create: { takeKeys(); Task { await model.createEventAtPickedTime() } },
                            dismiss: { takeKeys(); model.dismissPickedTime() })
            .frame(height: 26)
            .padding(.leading, CalendarDayView.axisWidth)
            .accessibilityIdentifier("calendar.dayView.pickedTime")
    }
}

struct CalendarSidebarBottomBar: View {
    let model: CalendarSidebarModel
    let router: AppRouter
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space3) {
            Image(systemName: "person.crop.circle").foregroundStyle(theme.textSecondary.color)
                .help(model.calendarLine)
                .accessibilityLabel(model.calendarLine)
            Text(model.calendarLine).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button {
                _ = router.environment.actions.perform(.settingsPage("calendar"), source: .toolbar, host: router)
            } label: {
                Image(systemName: "gearshape").foregroundStyle(theme.textSecondary.color).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Calendar settings")
            .accessibilityLabel("Calendar settings")
            .accessibilityIdentifier("calendar.settings")
        }
        .padding(.horizontal, theme.space5)
        .padding(.vertical, theme.space3)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.borderHairline.color).frame(height: theme.borderWidthHairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.bottomBar")
    }
}
