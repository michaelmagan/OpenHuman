import CoreGraphics
import MailTheme
import Testing
@testable import MailUI

@Suite struct NativeMetricsTests {
    @Test func theChromeSizesMatchTheDesign() {
        #expect(NativeMetrics.Text.body == 13)
        #expect(NativeMetrics.Toolbar.symbolSize == 15 && NativeMetrics.Toolbar.maxSplitSegments == 6)
        #expect(NativeMetrics.HintLine.height == 26 && NativeMetrics.HintLine.textSize == 11)
        #expect([NativeMetrics.Sidebar.minWidth, NativeMetrics.Sidebar.idealWidth, NativeMetrics.Sidebar.maxWidth] == [180, 220, 320])
        #expect([NativeMetrics.Search.fieldWidth, NativeMetrics.Search.focusedFieldWidth] == [260, 420])
        #expect([NativeMetrics.Settings.minWidth, NativeMetrics.Settings.minHeight] == [800, 560])
        #expect(NativeMetrics.Overlay.cornerRadius == 16 && NativeMetrics.Overlay.paletteWidth == 640)
        #expect(NativeMetrics.Overlay.paletteFieldTextSize == 17 && NativeMetrics.Overlay.paletteRowHeight == 40)
    }

    @Test func theListAndReaderSizesMatchTheDesign() {
        #expect(NativeMetrics.List.plateCornerRadius == 6)
        #expect(NativeMetrics.List.plateInsetX == 8 && NativeMetrics.List.plateInsetY == 1)
        #expect(NativeMetrics.List.selectedAlpha == 0.18 && NativeMetrics.List.inactiveSelectedAlpha == 0.08)
        #expect(NativeMetrics.List.hoverAlpha == 0.05 && NativeMetrics.List.checkedAlpha == 0.12)
        #expect(NativeMetrics.List.dateTextSize == 12 && NativeMetrics.List.unreadDotSize == 8)
        #expect(NativeMetrics.Tag.textSize == 11 && NativeMetrics.Tag.height == 18 && NativeMetrics.Tag.fillOpacity == 0.14)
        #expect(NativeMetrics.Reader.maxColumnWidth == 720 && NativeMetrics.Reader.subjectSize == 22)
        #expect(NativeMetrics.Reader.metaSize == 12 && NativeMetrics.Reader.collapsedRowHeight == 36)
        #expect(NativeMetrics.Reader.monogramSize == 32 && NativeMetrics.Reader.senderSize == 13)
    }

    @Test func theControlAndPillSizesMatchTheDesign() {
        #expect(NativeMetrics.Controls.iconPointSize == 13 && NativeMetrics.Controls.iconButtonSize == 28)
        #expect(NativeMetrics.Pill.height == 28 && NativeMetrics.Pill.paddingX == 12 && NativeMetrics.Pill.spacing == 6)
        #expect(NativeMetrics.Controls.iconPointSize < NativeMetrics.Controls.iconButtonSize)
        #expect(NativeMetrics.Pill.height <= NativeMetrics.Banner.height)
        #expect(NativeMetrics.Controls.iconButtonSize <= NativeMetrics.Pill.height, "an icon button fits inside a pill")
    }

    @Test func theSizesFitTogether() {
        #expect(NativeMetrics.Sidebar.minWidth < NativeMetrics.Sidebar.idealWidth)
        #expect(NativeMetrics.Sidebar.idealWidth < NativeMetrics.Sidebar.maxWidth)
        #expect(NativeMetrics.Search.fieldWidth < NativeMetrics.Search.focusedFieldWidth)
        #expect(NativeMetrics.List.inactiveSelectedAlpha < NativeMetrics.List.checkedAlpha)
        #expect(NativeMetrics.List.checkedAlpha < NativeMetrics.List.selectedAlpha)
        #expect(NativeMetrics.List.hoverAlpha < NativeMetrics.List.inactiveSelectedAlpha)
        #expect(NativeMetrics.Keycap.height < NativeMetrics.HintLine.height)
        #expect(NativeMetrics.Tag.height < NativeMetrics.Banner.height)
    }

    @Test func rowsLeaveRoomForThePlateAndChipsAtEveryDensity() {
        var tokens = ThemeTokens.light
        #expect([tokens.densityCompactRow, tokens.densityDefaultRow, tokens.densityComfortableRow] == [32, 40, 48])
        for density in ThemeDensity.allCases {
            tokens.density = density
            let plate = CGFloat(tokens.rowHeight) - 2 * NativeMetrics.List.plateInsetY
            #expect(plate > NativeMetrics.Tag.height, "\(density)")
            #expect(plate > NativeMetrics.List.unreadDotSize, "\(density)")
        }
    }
}
