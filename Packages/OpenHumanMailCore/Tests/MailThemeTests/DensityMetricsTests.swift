import Testing
@testable import MailTheme

@Suite struct DensityMetricsTests {
    private func tokens(_ density: ThemeDensity, _ base: ThemeTokens = .light) -> ThemeTokens {
        var t = base
        t.density = density
        return t
    }

    @Test func theDesignTableHoldsAtEveryDensity() {
        let table: [(ThemeDensity, [Double])] = [
            (.compact, [32, 1, 6, 22, 36, 12, 12, 32, 28, 32, 24]),
            (.default, [40, 2, 6, 24, 40, 16, 16, 36, 32, 36, 28]),
            (.comfortable, [48, 4, 8, 28, 44, 20, 20, 40, 36, 40, 28]),
        ]
        for (density, expected) in table {
            for base in [ThemeTokens.light, .dark, .paper, .midnight] {
                let t = tokens(density, base)
                let actual = [t.rowHeight, t.listPlateInsetY, t.listPlateInsetX, t.listHoverTarget, t.collapsedMessageRow,
                              t.cardContentInsetY, t.cardGap, t.messageHeaderHeight,
                              t.composerFieldHeight(default: 32), t.composerFieldHeight(default: 36), t.footerHeight]
                #expect(actual == expected, "\(density)")
                #expect(t.listGroupHeaderRow == t.rowHeight, "a header row is a row (fixed-height table)")
            }
        }
    }

    @Test func theDefaultDensityKeepsTheTokensAsTheyAre() {
        let t = ThemeTokens.light
        #expect(t.densityDelta == 0)
        #expect(t.listPlateInsetY == t.component.row.cursorInsetY && t.listPlateInsetX == t.component.row.cursorInsetX)
        #expect(t.collapsedMessageRow == t.component.thread.collapsedRow && t.cardGap == t.component.thread.messageGap)
        #expect(t.cardContentInsetY == t.space5 && t.footerHeight == t.component.footer.height)
    }

    @Test func theHoverTargetFitsInsideThePlateAtEveryDensity() {
        for density in ThemeDensity.allCases {
            let t = tokens(density)
            #expect(t.listHoverTarget <= t.rowHeight - 2 * t.listPlateInsetY, "\(density)")
        }
    }
}
