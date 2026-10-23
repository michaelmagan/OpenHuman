import Foundation
import Testing
@testable import MailTheme

@Suite struct VisualDeltasTests {
    private static let darkThemes = [BuiltinThemeID.dark, BuiltinThemeID.midnight, BuiltinThemeID.systemDark]
    private static let themes = [BuiltinThemeID.light, BuiltinThemeID.paper, BuiltinThemeID.systemLight] + darkThemes

    private static func everyResolvedTheme() -> [(String, ThemeTokens)] {
        let library = ThemeLibrary.builtIn
        var result: [(String, ThemeTokens)] = []
        for themeID in themes {
            for accent in BuiltinThemeID.accents {
                for increase in [false, true] {
                    let appearance: ThemeAppearance = darkThemes.contains(themeID) ? .dark : .light
                    let tokens = library.resolve(themeID: themeID, appearance: appearance,
                                                 preferences: ThemePreferences(accentID: accent),
                                                 increaseContrast: increase).tokens
                    result.append(("\(themeID) \(accent) increaseContrast=\(increase)", tokens))
                }
            }
        }
        return result
    }

    @Test func periwinkleIsTheDefaultAccent() {
        #expect(BuiltinThemeID.defaultAccent == "periwinkle")
        #expect(BuiltinThemeID.accents.first == "periwinkle")
        let library = ThemeLibrary.builtIn
        for (id, appearance) in [(BuiltinThemeID.light, ThemeAppearance.light), (BuiltinThemeID.dark, .dark),
                                 (BuiltinThemeID.paper, .light), (BuiltinThemeID.midnight, .dark)] {
            #expect(library.resolve(themeID: id, appearance: appearance).accentID == "periwinkle", "\(id)")
        }
        #expect(library.resolve(themeID: BuiltinThemeID.systemLight, appearance: .light).accentID == "system")
        let light = ThemeTokens.light
        #expect(light.accentRing == ThemeColor(hex: "#6D72C0") && light.accentFill == ThemeColor(hex: "#5E64BA"))
        #expect(ThemeTokens.dark.accentRing == ThemeColor(hex: "#AEB1DD"))
    }

    @Test func periwinkleHoldsItsPairsEverywhere() {
        let library = ThemeLibrary.builtIn
        for themeID in Self.themes {
            for increase in [false, true] {
                let appearance: ThemeAppearance = Self.darkThemes.contains(themeID) ? .dark : .light
                let t = library.resolve(themeID: themeID, appearance: appearance,
                                        preferences: ThemePreferences(accentID: "periwinkle"), increaseContrast: increase).tokens
                let label = "\(themeID) increaseContrast=\(increase)"
                for (name, surface) in [("bg.window", t.bgWindow), ("bg.row.selected", t.bgRowSelected), ("bg.sidebar", t.bgSidebar),
                                        ("bg.card", t.bgCard), ("bg.row.hover", t.bgRowHover)] {
                    #expect(t.accentRing.contrastRatio(on: surface) >= 3, "accent.ring on \(name): \(label)")
                }
                #expect(t.accentText.contrastRatio(on: t.bgWindow) >= 4.5, "accent.text: \(label)")
                #expect(t.accentOnFill.contrastRatio(on: t.accentFill) >= 4.5, "accent.onFill on fill: \(label)")
                #expect(t.accentOnFill.contrastRatio(on: t.accentFillHover) >= 4.5, "accent.onFill on fillHover: \(label)")
                #expect(t.textPrimary.contrastRatio(on: t.accentSubtle) >= 4.5, "text.primary on accent.subtle: \(label)")
            }
        }
    }

    @Test func linksAreSkyBlueAndReadable() {
        for (label, t) in Self.everyResolvedTheme() {
            #expect(t.component.link.text == t.textLink, "link.text follows text.link: \(label)")
            for (name, surface) in [("bg.window", t.bgWindow), ("bg.card", t.bgCard), ("bg.elevated", t.bgElevated)] {
                #expect(t.textLink.contrastRatio(on: surface) >= 4.5, "text.link on \(name): \(label)")
            }
        }
        #expect(ThemeTokens.light.textLink == ThemeColor(hex: "#2272AE"))
        #expect(ThemeTokens.dark.textLink == ThemeColor(hex: "#7CC0F2"))
        #expect(ReaderCSSVariables.tokens.contains { $0.variable == "--oh-link" && $0.key == "semantic/color/text.link" })
        #expect(ContrastLint.checks(for: .light).contains { $0.label == "text.link on bg.window" })
    }

    @Test func unreadDotIsSkyBlueAndVisible() {
        for (label, t) in Self.everyResolvedTheme() {
            let dot = t.component.row.unreadDot
            for (name, surface) in [("bg.window", t.bgWindow), ("bg.row.hover", t.bgRowHover),
                                    ("bg.row.selected", t.bgRowSelected), ("bg.sidebar", t.bgSidebar)] {
                #expect(dot.contrastRatio(on: surface) >= 3, "row.unreadDot on \(name): \(label)")
            }
        }
        #expect(ThemeTokens.light.component.row.unreadDot == ThemeColor(hex: "#1F7FC8"))
        #expect(ThemeTokens.paper.component.row.unreadDot == ThemeColor(hex: "#1F7FC8"))
        #expect(ThemeTokens.dark.component.row.unreadDot == ThemeColor(hex: "#88CAFC"))
        #expect(ThemeTokens.midnight.component.row.unreadDot == ThemeColor(hex: "#88CAFC"))
    }

    @Test func listAndTabMetrics() {
        let t = ThemeTokens.light
        #expect(t.typeTab.size == 18 && t.typeTab.lineHeight == 24 && t.typeTab.weight == 400)
        #expect(t.typeTabActive.size == 19 && t.typeTabActive.lineHeight == 24 && t.typeTabActive.weight == 400)
        #expect(t.typeTabCount.size == 13 && t.typeTabCount.weight == 400 && t.typeTabCount.monospacedDigits)
        #expect([t.densityCompactRow, t.densityDefaultRow, t.densityComfortableRow] == [32, 40, 48])
        #expect(t.component.row.snippet == t.textTertiary && t.component.row.date == t.textTertiary)
        #expect(t.component.row.unreadWeight == 400)
        #expect(t.component.row.dateWidth == 72)
        let library = ThemeLibrary.builtIn
        for (id, appearance) in [(BuiltinThemeID.systemLight, ThemeAppearance.light), (BuiltinThemeID.systemDark, .dark)] {
            let s = library.resolve(themeID: id, appearance: appearance).tokens
            #expect(s.typeTab.size == 13 && s.typeTabActive.size == 14 && s.typeTabActive.weight == 400
                    && s.typeTabCount.size == 10, "\(id)")
        }
    }

    @Test func selectedSplitTabStandsApartByTextContrastOnly() {
        for (label, t) in Self.everyResolvedTheme() {
            let tab = t.component.tab
            let active = tab.textActive.contrastRatio(on: t.bgWindow)
            let inactive = tab.text.contrastRatio(on: t.bgWindow)
            let count = tab.count.contrastRatio(on: t.bgWindow)
            #expect(tab.textActive == t.textPrimary && tab.text == t.textTertiary, "\(label)")
            #expect(t.typeTabActive.weight == t.typeTab.weight && t.typeTabActive.size > t.typeTab.size, "\(label)")
            #expect(inactive >= 4.5 && active > inactive, "tab.text on bg.window: \(label)")
            #expect(count >= 3, "tab.count on bg.window: \(label)")
            if t.increaseContrast {
                #expect(count >= 4.5, "tab.count with Increase Contrast: \(label)")
            } else {
                #expect(count < inactive, "tab.count is lighter than an unselected tab: \(label)")
            }
        }
    }

    @Test func rowTextAndChipsKeepTheirContrast() {
        for (label, t) in Self.everyResolvedTheme() {
            let row = t.component.row
            #expect(row.snippet.contrastRatio(on: t.bgWindow) >= 4.5, "row.snippet on bg.window: \(label)")
            #expect(row.date.contrastRatio(on: t.bgRowHover) >= 4.5, "row.date on bg.row.hover: \(label)")
            #expect(t.textSecondary.contrastRatio(on: row.bgCursor) >= 4.5, "cursor-row metadata: \(label)")
            #expect(t.textSecondary.contrastRatio(on: t.listCursorFill) >= 4.5, "cursor-row metadata, drawn plate: \(label)")
            #expect(row.chipText.contrastRatio(on: row.chipBg) >= 4.5, "row.chipText on row.chipBg: \(label)")
        }
    }

    @Test func chipPlatesStandOffEveryRowFill() {
        for (label, t) in Self.everyResolvedTheme() {
            let row = t.component.row
            let increase = label.hasSuffix("increaseContrast=true")
            #expect(ThemeTokens.standApart(row.chipBg, t.listCursorFill, luminance: increase ? 1.4 : 1.1),
                    "chip vs cursor plate: \(label)")
            #expect(row.chipBg.contrastRatio(on: row.bgHover) >= (increase ? 1.5 : 1.15), "chip vs hover plate: \(label)")
            #expect(row.chipBg.contrastRatio(on: t.bgWindow) >= (increase ? 1.5 : 1.15), "chip vs window: \(label)")
        }
    }

    @Test func hoverAndCursorPlatesAreDifferentSteps() {
        for (label, t) in Self.everyResolvedTheme() {
            let hover = t.component.row.bgHover.composited(over: t.bgWindow)
            #expect(ThemeTokens.standApart(hover, t.listCursorFill, luminance: 1.06), "hover vs cursor: \(label)")
        }
    }

    @Test func keycapsAreFilledAndBorderless() {
        for (label, t) in Self.everyResolvedTheme() {
            let keycap = t.component.keycap
            #expect(keycap.text.contrastRatio(on: keycap.bg) >= 4.5, "keycap.text on keycap.bg: \(label)")
            #expect(keycap.border.alpha == 0, "keycap.border is transparent: \(label)")
        }
        #expect(ThemeTokens.light.keycapBg == ThemeColor(hex: "#6E7681") && ThemeTokens.light.keycapText == ThemeColor(hex: "#FFFFFF"))
        #expect(ThemeTokens.dark.keycapBg == ThemeColor(hex: "#3C3C3C") && ThemeTokens.dark.keycapText == ThemeColor(hex: "#C8C8C8"))
    }

    @Test func paletteSheetIsTheSameInEveryThemeAndReadable() {
        let light = ThemeTokens.light.component.palette
        for (label, t) in Self.everyResolvedTheme() {
            let p = t.component.palette
            #expect(p.bg == light.bg && p.text == light.text && p.band == light.band, "same sheet in every theme: \(label)")
        }
        let p = light
        #expect(p.bg == ThemeColor(hex: "#1A1A1A"))
        #expect(p.text.contrastRatio(on: p.bg) >= 4.5, "palette.text on palette.bg")
        #expect(p.textSelected.contrastRatio(on: p.band) >= 4.5, "palette.textSelected on palette.band")
        #expect(p.header.contrastRatio(on: p.bg) >= 4.5, "palette.header on palette.bg")
        #expect(p.icon.contrastRatio(on: p.bg) >= 3 && p.icon.contrastRatio(on: p.band) >= 3, "palette.icon")
        #expect(p.keycapText.contrastRatio(on: p.keycapBg) >= 4.5, "palette.keycapText on palette.keycapBg")
        #expect(p.scopeText.contrastRatio(on: p.scopeBg) >= 4.5, "palette.scopeText on palette.scopeBg")
        #expect(p.rowDisabled.contrastRatio(on: p.bg) >= 3, "palette.rowDisabled (informational)")
        #expect([p.width, p.rowHeight, p.titleHeight, p.cursorInset, p.topRatio] == [680, 48, 40, 0, 0.22])
        #expect(p.radius == ThemeTokens.light.radiusSM && ThemeTokens.light.component.picker.rowHeight == 48)
        #expect(ThemeTokens.light.typePaletteInput.family == .systemMono && ThemeTokens.light.typePaletteRow.family == .systemMono)
        #expect(ThemeTokens.light.typePaletteInput.size == 18 && ThemeTokens.light.typePaletteRow.size == 14)
    }

    @Test func sheetContentFromTheDarkTableReadsOnTheSheet() {
        let library = ThemeLibrary.builtIn
        for themeID in Self.darkThemes {
            for accent in BuiltinThemeID.accents {
                let t = library.resolve(themeID: themeID, appearance: .dark, preferences: ThemePreferences(accentID: accent)).tokens
                let sheet = t.component.palette.bg
                let label = "\(themeID) \(accent)"
                for (name, color) in [("text.primary", t.textPrimary), ("text.secondary", t.textSecondary),
                                      ("text.tertiary", t.textTertiary), ("text.warning", t.textWarning),
                                      ("text.danger", t.textDanger), ("accent.text", t.accentText), ("text.link", t.textLink)] {
                    #expect(color.contrastRatio(on: sheet) >= 4.5, "\(name) on palette.bg: \(label)")
                }
                #expect(t.accentRing.contrastRatio(on: sheet) >= 3, "accent.ring (input bar) on palette.bg: \(label)")
            }
        }
    }

    @Test func darkIsRebalancedAndModalsDimMore() {
        let d = ThemeTokens.dark
        #expect(d.bgWindow == ThemeColor(hex: "#26282C") && d.bgCard == ThemeColor(hex: "#34373C") && d.bgElevated == d.bgCard)
        #expect(d.bgSidebar == ThemeColor(hex: "#17191C"))
        #expect(d.textTertiary.contrastRatio(on: d.bgCard) >= 4.5)
        #expect(ThemeColor(hex: "#8F96A0")!.contrastRatio(on: d.bgCard) < 4.5, "why text.tertiary moved")
        #expect(d.bgRowSelected.contrastRatio(on: d.bgWindow) > 1.2, "the cursor fill stays visible on the lighter window")
        for t in [ThemeTokens.light, .paper] {
            #expect(abs(t.bgScrim.alpha - 0.48) < 0.001)
        }
    }
}
