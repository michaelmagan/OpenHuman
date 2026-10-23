import AppKit
import MailActions
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized)
struct RowActionsOverlapTests {
    private static let now = Date(timeIntervalSince1970: 1_791_000_000)

    static let actions: [ThreadRowView.HoverAction] = [
        .init(action: .markDone, symbol: "checkmark", title: "Mark done"),
        .init(action: ThreadListActionIDs.snooze, symbol: "clock", title: "Snooze"),
        .init(action: .remind, symbol: "bell", title: "Remind me"),
        .init(action: ThreadListActionIDs.label, symbol: "tag", title: "Label"),
        .init(action: .trash, symbol: "trash", title: "Trash"),
    ]
    static let fourActions = actions.filter { $0.action != ThreadListActionIDs.label }

    static let themeIDs = [BuiltinThemeID.light, BuiltinThemeID.paper, BuiltinThemeID.systemLight,
                           BuiltinThemeID.dark, BuiltinThemeID.midnight, BuiltinThemeID.systemDark]
    static let darkThemeIDs: Set<String> = [BuiltinThemeID.dark, BuiltinThemeID.midnight, BuiltinThemeID.systemDark]

    static func tokens(_ themeID: String, density: ThemeDensity = .default, zoom: Double = 1) -> ThemeTokens {
        var tokens = ThemeLibrary.builtIn.resolve(themeID: themeID,
                                                  appearance: darkThemeIDs.contains(themeID) ? .dark : .light,
                                                  preferences: ThemePreferences(density: density)).tokens
        tokens.density = density
        return tokens.listZoomed(zoom)
    }

    enum Content: CaseIterable {
        case long
        case unbreakable
        case chips
        case related
        case followUp
    }

    struct Shown {
        let texts: (sender: NSAttributedString, line: NSAttributedString)
        let row: ThreadRow
        let indicators: [ThreadRowIndicator]
    }

    static func shown(_ content: Content, style: ThreadRowStyle) -> Shown {
        var subject = String(repeating: "Quarterly planning notes and the venue shortlist ", count: 6)
        var snippet = String(repeating: "Agenda, the room list and the catering order for Thursday ", count: 6)
        var chips: [ThreadRowChip] = []
        var indicators: [ThreadRowIndicator] = []
        var match: SearchMatchKind?
        var reason: String?
        var location = MailLocation.system(.inbox)
        switch content {
        case .long:
            break
        case .unbreakable:
            subject = "Research"
            snippet = String(repeating: "+1-555-0100-", count: 40)
        case .chips:
            subject = "Venue options"
            chips = [ThreadRowChip(kind: .important, title: "Important"), ThreadRowChip(kind: .category, title: "Marketing"),
                     ThreadRowChip(kind: .label, title: "Clients", color: "#4a86e8"),
                     ThreadRowChip(kind: .label, title: "Travel"), ThreadRowChip(kind: .overflow, title: "+2")]
            indicators = [.attachment, .starred]
        case .related:
            match = .related
            indicators = [.attachment]
        case .followUp:
            location = .system(.reminders)
            reason = String(repeating: "Asked for the signed venue contract by Friday and has not replied ", count: 3)
            indicators = [.reminder]
        }
        let row = ThreadRow(id: ThreadKey(account: AccountID(1), rowID: 40, gmailThreadID: GmailThreadID("t40")),
                            subject: subject, snippet: snippet, participantsDisplay: "Robin Example-Longname, Sam, me",
                            participants: [], messageCount: 3, unreadCount: 1, draftCount: 0,
                            attachmentCount: indicators.contains(.attachment) ? 1 : 0, isUnread: true,
                            isStarred: indicators.contains(.starred), isImportant: content == .chips, userLabelIDs: [],
                            lastMessageAt: now, sortAt: now, searchMatch: match)
        let texts = style.texts(for: row, chips: chips, format: ThreadRowFormatting(), location: location,
                                followUpReason: reason)
        return Shown(texts: texts, row: row, indicators: indicators)
    }

    enum State: CaseIterable {
        case hovered, cursor, hoveredCursor, hoveredChecked
    }

    static func make(_ style: ThreadRowStyle, width: CGFloat, content: Content = .long, state: State,
                     rtl: Bool = false, actions: @escaping () -> [ThreadRowView.HoverAction] = { Self.fourActions })
        -> (cell: ThreadRowView, rowView: ThreadRowBackgroundView) {
        let rowView = ThreadRowBackgroundView(style: style)
        rowView.frame = NSRect(x: 0, y: 0, width: width, height: style.rowHeight)
        let cell = ThreadRowView(style: style)
        cell.frame = rowView.bounds
        if rtl { cell.userInterfaceLayoutDirection = .rightToLeft }
        cell.hoverActions = actions
        let shown = shown(content, style: style)
        cell.configure(shown.row, texts: shown.texts, date: style.date("1:33 PM", unread: true, upcoming: false),
                       indicators: shown.indicators, isChecked: state == .hoveredChecked)
        rowView.addSubview(cell)
        switch state {
        case .hovered: cell.setHovering(true)
        case .cursor: rowView.isSelected = true
        case .hoveredCursor:
            rowView.isSelected = true
            cell.setHovering(true)
        case .hoveredChecked:
            rowView.isChecked = true
            cell.setHovering(true)
        }
        cell.layoutSubtreeIfNeeded()
        return (cell, rowView)
    }

    static func paintedColumns(_ cell: ThreadRowView) -> [Bool] {
        let width = Int(cell.bounds.width.rounded(.up)), height = Int(cell.bounds.height.rounded(.up))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep), let data = rep.bitmapData else { return [] }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        cell.draw(cell.bounds)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        var painted = [Bool](repeating: false, count: width)
        let stride = rep.bytesPerRow, bytes = rep.bitsPerPixel / 8
        for y in 0..<height {
            for x in 0..<width where !painted[x] && data[y * stride + x * bytes + 3] != 0 { painted[x] = true }
        }
        return painted
    }

    static func redraws(_ cell: ThreadRowView) -> Bool {
        let before = cell.drawCount
        cell.layer?.displayIfNeeded()
        return cell.drawCount > before
    }

    static func expectClear(_ cell: ThreadRowView, style: ThreadRowStyle, rtl: Bool, _ what: String, pixels: Bool = true,
                            sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        guard let group = cell.actionGroupFrame else {
            Issue.record("\(what): the actions show", sourceLocation: sourceLocation)
            return false
        }
        let frames = cell.drawnFrames()
        guard let band = frames.actions else {
            Issue.record("\(what): the drawing knows the actions' band", sourceLocation: sourceLocation)
            return false
        }
        var clear = band.minX <= max(0, group.minX) && band.maxX >= group.maxX
        clear = clear && frames.date == nil && frames.indicators.isEmpty
        let gap = style.metrics.columnGap
        for frame in frames.contents {
            clear = clear && !frame.intersects(band) && (rtl ? frame.minX >= band.maxX + gap : frame.maxX <= band.minX - gap)
        }
        let painted = pixels ? paintedColumns(cell) : []
        let start = min(painted.count, max(0, Int(band.minX.rounded(.down))))
        let hit = (start..<max(start, min(painted.count, Int(band.maxX.rounded(.up))))).first { painted[$0] }
        if !clear || hit != nil {
            Issue.record("\(what): group \(group), band \(band), frames \(frames.contents), painted at x \(hit.map(String.init) ?? "-")",
                         sourceLocation: sourceLocation)
            return false
        }
        return true
    }

    @Test func noTextIsDrawnUnderTheActionsInAnyStateThemeOrDensity() async {
        var checked = 0, rendered = 0
        for themeID in Self.themeIDs {
            for (density, zoom) in [(ThemeDensity.compact, 1.0), (.default, 1), (.comfortable, 1), (.default, 1.5)] {
                let style = ThreadRowStyle(theme: Self.tokens(themeID, density: density, zoom: zoom))
                for width in [CGFloat(360), 520, 760, 1000, 1400] {
                    for content in Content.allCases {
                        for state in State.allCases {
                            for rtl in [false, true] {
                                let (cell, _) = Self.make(style, width: width, content: content, state: state, rtl: rtl)
                                let what = "\(themeID) \(density) x\(zoom) w\(Int(width)) \(content) \(state)\(rtl ? " RTL" : "")"
                                let pixels = rtl ? width == 760 : (width == 360 || width == 1000)
                                guard Self.expectClear(cell, style: style, rtl: rtl, what, pixels: pixels) else { return }
                                checked += 1
                                if pixels { rendered += 1 }
                            }
                        }
                        await Task.yield()
                    }
                }
            }
        }
        #expect(checked == 6 * 4 * 5 * 5 * 4 * 2)
        #expect(rendered == 6 * 4 * 3 * 5 * 4)
    }

    @Test func fiveButtonsAndTheIdleRowStayClear() {
        for density in ThemeDensity.allCases {
            let style = ThreadRowStyle(theme: Self.tokens(BuiltinThemeID.light, density: density))
            for width in [CGFloat(360), 760, 1400] {
                for content in Content.allCases {
                    let (cell, _) = Self.make(style, width: width, content: content, state: .hoveredCursor, actions: { Self.actions })
                    #expect(Self.expectClear(cell, style: style, rtl: false, "\(density) w\(Int(width)) \(content) five"))
                    let g = style.metrics.buttonGap
                    #expect(cell.actionGroupFrame.map { $0.width } == 5 * style.hoverTarget + 4 * g + 2 * g)

                    let idle = ThreadRowView(style: style)
                    idle.frame = NSRect(x: 0, y: 0, width: width, height: style.rowHeight)
                    let shown = Self.shown(content, style: style)
                    idle.configure(shown.row, texts: shown.texts, date: style.date("THU 12:46 AM", unread: false, upcoming: true),
                                   indicators: shown.indicators, isChecked: false)
                    let frames = idle.drawnFrames()
                    #expect(frames.actions == nil && frames.date != nil)
                    if let sender = frames.sender, let line = frames.line {
                        #expect(sender.maxX + style.metrics.senderGap <= line.minX)
                    }
                    #expect(frames.indicators.count == shown.indicators.count)
                    let line = frames.line?.maxX ?? 0
                    for icon in frames.indicators + [frames.date].compactMap({ $0 }) {
                        #expect(icon.minX >= line, "\(density) w\(Int(width)) \(content): icons and date after the line")
                    }
                }
            }
        }
    }

    @Test func aResizedListRedrawsTheCursorRowForItsNewWidth() async throws {
        let host = StubListHost(enabled: [.markDone, .trash, ThreadListActionIDs.snooze, .remind])
        let (controller, model, _, window) = try await ThreadListViewTests.list(threads: 6, host: host)
        defer { window.close() }
        model.moveCursor(by: 1)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let table = controller.tableView
        try #require(table.selectedRow >= 0)
        let cell = try #require(table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: false) as? ThreadRowView)
        #expect(cell.showsActions, "the cursor row shows its actions (V16)")
        _ = Self.redraws(cell)
        for width in [CGFloat(720), 980, 640] {
            let before = cell.frame.width
            window.setContentSize(NSSize(width: width, height: 700))
            window.contentView?.layoutSubtreeIfNeeded()
            try #require(cell.frame.width != before, "the cell follows the list's width")
            #expect(Self.redraws(cell), "width \(width): the row draws again instead of stretching its old drawing")
            cell.layoutSubtreeIfNeeded()
            let group = try #require(cell.actionGroupFrame)
            #expect(group.maxX == controller.style.columns(width: cell.bounds.width).date.upperBound)
            #expect(Self.expectClear(cell, style: controller.style, rtl: false, "list width \(width)"))
        }
    }

    @Test func aResizedRowDrawsAndLaysOutAgain() throws {
        let style = ThreadRowStyle(theme: .light)
        let (cell, rowView) = Self.make(style, width: 1000, state: .hoveredCursor)
        let window = ThreadListViewTests.window(NSView())
        defer { window.close() }
        window.contentView?.addSubview(rowView)
        _ = Self.redraws(cell)
        for width in [CGFloat(700), 1200, 480] {
            rowView.setFrameSize(NSSize(width: width, height: style.rowHeight))
            cell.setFrameSize(NSSize(width: width, height: style.rowHeight))
            #expect(cell.needsLayout, "width \(width)")
            cell.layoutSubtreeIfNeeded()
            #expect(Self.redraws(cell), "width \(width)")
            #expect(Self.expectClear(cell, style: style, rtl: false, "resized to \(width)"))
        }
        cell.setFrameSize(cell.frame.size)
        #expect(!Self.redraws(cell), "the same size draws nothing again")
    }

    @Test func aNewSetOfButtonsRedrawsTheRow() throws {
        let style = ThreadRowStyle(theme: .dark)
        var offered = Array(Self.actions.prefix(2))
        let (cell, rowView) = Self.make(style, width: 900, state: .cursor, actions: { offered })
        let window = ThreadListViewTests.window(NSView())
        defer { window.close() }
        window.contentView?.addSubview(rowView)
        let narrow = try #require(cell.actionGroupFrame)
        _ = Self.redraws(cell)
        offered = Self.actions
        cell.setHovering(true)
        #expect(Self.redraws(cell), "five buttons where there were two")
        cell.layoutSubtreeIfNeeded()
        let wide = try #require(cell.actionGroupFrame)
        #expect(wide.minX < narrow.minX)
        #expect(Self.expectClear(cell, style: style, rtl: false, "after the set changed"))
    }

    @Test func aDensityChangeLaysTheButtonsOutAgain() throws {
        let comfortable = ThreadRowStyle(theme: Self.tokens(BuiltinThemeID.light, density: .comfortable))
        let compact = ThreadRowStyle(theme: Self.tokens(BuiltinThemeID.light, density: .compact))
        #expect(comfortable.hoverTarget > compact.hoverTarget)
        let (cell, _) = Self.make(comfortable, width: 900, state: .hoveredCursor)
        cell.style = compact
        #expect(cell.needsLayout)
        cell.layoutSubtreeIfNeeded()
        let group = try #require(cell.actionGroupFrame)
        #expect(group.width == 4 * compact.hoverTarget + 5 * compact.metrics.buttonGap)
        #expect(Self.expectClear(cell, style: compact, rtl: false, "after the density change"))
        cell.style = comfortable
        cell.setFrameSize(NSSize(width: 900, height: comfortable.rowHeight))
        cell.layoutSubtreeIfNeeded()
        #expect(cell.actionGroupFrame?.width == 4 * comfortable.hoverTarget + 5 * comfortable.metrics.buttonGap)
        #expect(Self.expectClear(cell, style: comfortable, rtl: false, "back to comfortable"))
    }

    @Test func rowMetricsPerDensity() {
        let light = BuiltinThemeID.light
        let compact = ThreadRowStyle(theme: Self.tokens(light, density: .compact))
        let normal = ThreadRowStyle(theme: Self.tokens(light, density: .default))
        let comfortable = ThreadRowStyle(theme: Self.tokens(light, density: .comfortable))
        #expect(compact.rowHeight == 32 && normal.rowHeight == 40 && comfortable.rowHeight == 48)
        let designTen = ThreadRowStyle.Metrics(leading: 40, trailing: 24, dotCenterX: 21, senderGap: 16, columnGap: 16,
                                               senderMin: 160, senderMax: 240, senderPct: 0.22, indicatorWidth: 40,
                                               indicatorSize: 12, dateWidth: 72, buttonGap: 4, buttonGlyph: 14)
        for style in [compact, normal] {
            #expect(style.metrics == designTen)
            #expect(style.bodyFont.pointSize == 13 && style.lineHeight == 18 && style.plateRadius == 6)
        }
        #expect(comfortable.metrics == ThreadRowStyle.Metrics(
            leading: 48, trailing: 36, dotCenterX: 21, senderGap: 32, columnGap: 16, senderMin: 185, senderMax: 240,
            senderPct: 0.22, indicatorWidth: 46, indicatorSize: 14, dateWidth: 83, buttonGap: 12, buttonGlyph: 16))
        #expect(comfortable.bodyFont.pointSize == 15 && comfortable.strongFont.pointSize == 15 && comfortable.lineHeight == 20)
        #expect(comfortable.metaFont.pointSize == 14)
        #expect(comfortable.plateRadius == 6 && comfortable.plateInsetX == 8 && comfortable.plateInsetY == 1)
        #expect(comfortable.hoverTarget == 28)
        #expect(ThreadRowView.columns(width: 1000).sender == 40...260)
        let zoomed = ThreadRowStyle(theme: Self.tokens(light, density: .comfortable, zoom: 1.5))
        var columnsOnly = zoomed.metrics
        columnsOnly.dotCenterX = comfortable.metrics.dotCenterX
        #expect(zoomed.bodyFont.pointSize == 22.5 && columnsOnly == comfortable.metrics)
        #expect(zoomed.metrics.dotCenterX - zoomed.plateInsetX == comfortable.metrics.dotCenterX - comfortable.plateInsetX,
                "the box keeps its place on the zoomed plate")
        let header = ThreadGroupHeaderView(style: comfortable)
        header.frame = NSRect(x: 0, y: 0, width: 900, height: comfortable.rowHeight)
        header.configure(title: "Yesterday")
        header.layoutSubtreeIfNeeded()
        #expect(header.labelFrame.minX == 48 - ThreadGroupHeaderView.textInset)
    }

    @Test func theCheckboxGutterClearsTheBarAndTheSenderEverywhere() {
        for themeID in Self.themeIDs {
            for density in ThemeDensity.allCases {
                for zoom in [1.0, 1.5] {
                    let style = ThreadRowStyle(theme: Self.tokens(themeID, density: density, zoom: zoom))
                    let label = "\(themeID) \(density) zoom \(zoom)"
                    let side = ThreadRowView.checkboxSize
                    let box = (style.metrics.dotCenterX - side / 2)...(style.metrics.dotCenterX + side / 2)
                    #expect(side >= 14 && side <= 16, "\(label)")
                    #expect(box.lowerBound - style.plateInsetX >= 6, "inside the plate: \(label)")
                    #expect(style.metrics.leading - box.upperBound >= 10, "before the sender: \(label)")
                    for width in [CGFloat(500), 1000, 2000] {
                        let c = style.columns(width: width)
                        #expect(c.dotCenterX == style.metrics.dotCenterX && c.sender.lowerBound == style.metrics.leading,
                                "every row keeps the gutter: \(label) \(width)")
                    }
                }
            }
        }
    }

    @Test func chipsSitOnTheBaselineAndTakeTheirHuesTokens() throws {
        for themeID in Self.themeIDs {
            for density in ThemeDensity.allCases {
                let tokens = Self.tokens(themeID, density: density)
                let style = ThreadRowStyle(theme: tokens)
                let line = Self.shown(.chips, style: style).texts.line
                var bottoms: [CGFloat] = []
                line.enumerateAttribute(.attachment, in: NSRange(location: 0, length: line.length)) { value, _, _ in
                    if let attachment = value as? NSTextAttachment { bottoms.append(attachment.bounds.minY) }
                }
                #expect(bottoms == [-style.chipBaseline("important"), -style.chipBaseline("marketing", hue: .coral),
                                    -style.chipBaseline("+4")], "\(themeID) \(density)")
                #expect(bottoms.allSatisfy { $0 < 0 })
                let chips = [ThreadRowChip(kind: .important, title: "Important"), ThreadRowChip(kind: .category, title: "Marketing"),
                             ThreadRowChip(kind: .label, title: "Clients", color: "#4a86e8"), ThreadRowChip(kind: .overflow, title: "+2")]
                let shown = LabelChipRenderer.shown(chips, maximum: ThreadRowStyle.maximumFilledChips)
                #expect(shown.map(\.title) == ["important", "marketing", "+3"] && shown.map(\.hue) == [.neutral, .coral, .neutral])
                let label = "\(themeID) \(density)"
                func fill(_ title: String, _ hue: LabelChipHue) -> NSColor? {
                    Self.pixel(style.chips.image(title, hue: hue, muted: false).image)
                }
                for (title, hue) in [("marketing", LabelChipHue.coral), ("clients", .sky), ("important", .neutral)] {
                    let alpha = fill(title, hue)?.alphaComponent ?? 0
                    #expect(abs(alpha - NativeMetrics.Tag.fillOpacity) < 0.03, "\(title) is a tint, alpha \(alpha): \(label)")
                    #expect(style.chips.image(title, hue: hue, muted: false).image.size.height == style.chips.chipHeight)
                }
                let coral = style.chips.colors(hue: .coral, muted: false)
                #expect(coral.fill == LabelChipRenderer.tint(tokens.component.labelChip.coralText), "\(label)")
                #expect(coral.ink.contrastRatio(on: coral.fill.composited(over: tokens.bgWindow)) >= 4.5, "\(label)")
                #expect(style.chips.colors(hue: .coral, muted: true) == (LabelChipRenderer.tint(tokens.textTertiary), tokens.textTertiary),
                        "a fallback category is muted grey: \(label)")
            }
        }
    }

    static func pixel(_ image: NSImage) -> NSColor? {
        let view = NSImageView(image: image)
        view.imageScaling = .scaleNone
        view.frame = NSRect(origin: .zero, size: image.size)
        guard image.size.width > 2, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return rep.colorAt(x: Int(2 * scale), y: Int(view.bounds.height / 2 * scale))
    }

    static func near(_ color: NSColor?, _ token: ThemeColor) -> Bool {
        let swatch = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            token.nsColor.setFill()
            rect.fill()
            return true
        }
        guard let color, let reference = pixel(swatch), color.type == .componentBased, reference.type == .componentBased,
              let a = color.usingColorSpace(reference.colorSpace) else { return false }
        return abs(a.redComponent - reference.redComponent) < 0.01 && abs(a.greenComponent - reference.greenComponent) < 0.01
            && abs(a.blueComponent - reference.blueComponent) < 0.01
    }

    @Test func voiceOverOrderIsUnchanged() throws {
        let style = ThreadRowStyle(theme: .light)
        let (cell, _) = Self.make(style, width: 900, state: .hoveredCursor)
        cell.accessibilityContent = { ("Robin, Venue options", []) }
        #expect(cell.subviews.count == 1)
        let buttons = try #require(cell.subviews.first).subviews.compactMap { $0 as? NSButton }
        #expect(buttons.map { $0.accessibilityLabel() ?? "" } == Self.fourActions.map(\.title))
        #expect(buttons.map(\.frame.minX) == buttons.map(\.frame.minX).sorted(), "left to right in reading order")
        #expect(cell.accessibilityLabel() == "Robin, Venue options")
        #expect(cell.isAccessibilityElement())
    }
}
