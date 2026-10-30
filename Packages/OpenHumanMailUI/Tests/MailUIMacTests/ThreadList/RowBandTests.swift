import AppKit
import MailActions
import MailFeatures
import MailTheme
import MailUI
import Testing
@testable import MailUIMac

@MainActor
@Suite struct RowBandTests {
    static let darkThemes = [BuiltinThemeID.dark, BuiltinThemeID.midnight, BuiltinThemeID.systemDark]

    static func everyTheme() -> [(String, ThemeTokens)] {
        var result: [(String, ThemeTokens)] = []
        for themeID in [BuiltinThemeID.light, BuiltinThemeID.paper, BuiltinThemeID.systemLight] + darkThemes {
            for accent in BuiltinThemeID.accents {
                let t = ThemeLibrary.builtIn.resolve(themeID: themeID, appearance: darkThemes.contains(themeID) ? .dark : .light,
                                                     preferences: ThemePreferences(accentID: accent)).tokens
                result.append(("\(themeID) \(accent)", t))
            }
        }
        return result
    }

    static func tint(_ color: ThemeColor, _ alpha: CGFloat, over theme: ThemeTokens) -> ThemeColor {
        ThemeColor(red: color.red, green: color.green, blue: color.blue, alpha: Double(alpha)).composited(over: theme.bgWindow)
    }

    @Test func theCursorFillIsAnAccentTintThatKeepsSecondaryTextReadable() {
        for theme in [ThemeTokens.light, ThemeTokens.dark] {
            let tint = Self.tint(theme.accentRing, NativeMetrics.List.selectedAlpha, over: theme)
            #expect(ThreadRowStyle.cursorFill(theme) == tint)
            #expect(RenderReviewFixTests.same(ThreadRowStyle(theme: theme).cursor, tint.nsColor))
            #expect(ThreadRowStyle.inactiveCursorFill(theme)
                == Self.tint(theme.textPrimary, NativeMetrics.List.inactiveSelectedAlpha, over: theme))
            #expect(ThreadRowStyle.hoverFill(theme) == Self.tint(theme.textPrimary, NativeMetrics.List.hoverAlpha, over: theme))
            #expect(ThreadRowStyle.checkedFill(theme) == Self.tint(theme.accentRing, NativeMetrics.List.checkedAlpha, over: theme))
        }
        var synthetic = ThemeTokens.light
        synthetic.accentRing = ThemeColor(hex: "#1A1A1A")!
        let thinned = ThreadRowStyle.cursorFill(synthetic)
        #expect(thinned != Self.tint(synthetic.accentRing, NativeMetrics.List.selectedAlpha, over: synthetic),
                "a dark accent is thinned")
        #expect(synthetic.textSecondary.contrastRatio(on: thinned) >= 4.5)
        for (label, t) in Self.everyTheme() {
            for plate in [ThreadRowStyle.cursorFill(t), ThreadRowStyle.inactiveCursorFill(t), ThreadRowStyle.checkedFill(t),
                          ThreadRowStyle.hoverFill(t)] {
                #expect(t.textSecondary.contrastRatio(on: plate) >= 4.5 || t.textSecondary.contrastRatio(on: t.bgWindow) < 4.5,
                        "\(label)")
                #expect(plate != t.bgWindow, "every plate shows: \(label)")
            }
        }
    }

    @Test func theGlyphTintIsTheAccentWhereItReads() {
        for (label, t) in Self.everyTheme() {
            let tint = ThreadRowStyle.glyphTint(t)
            let plates = [ThreadRowStyle.cursorFill(t), ThreadRowStyle.inactiveCursorFill(t), ThreadRowStyle.hoverFill(t)]
            if plates.allSatisfy({ t.accentText.contrastRatio(on: $0) >= 3 }) {
                #expect(tint == t.accentText, "\(label)")
            } else {
                #expect(tint == t.textSecondary, "\(label)")
            }
            #expect(RenderReviewFixTests.same(ThreadRowStyle(theme: t).actionTint, tint.nsColor), "\(label)")
        }
    }

    @Test func theHoverGroupIsDoneSnoozeAndRemindMe() {
        #expect(ThreadListViewController(theme: .light).hoverActions == [.markDone, ThreadListActionIDs.snooze, .remind])
    }

    @Test func aButtonAtRestTakesTheGlyphTintAndNoFill() {
        for theme in [ThemeTokens.light, ThemeTokens.dark] {
            let style = ThreadRowStyle(theme: theme)
            let button = RowActionButton(image: NSImage(), style: style)
            #expect(RenderReviewFixTests.same(button.contentTintColor, style.actionTint))
            #expect(button.layer?.backgroundColor == nil)
        }
    }

    @Test func thePlateEdgeShowsOnlyUnderIncreaseContrast() {
        for increase in [false, true] {
            let t = ThemeLibrary.builtIn.resolve(themeID: BuiltinThemeID.light, appearance: .light,
                                                 increaseContrast: increase).tokens
            let view = ThreadRowBackgroundView(style: ThreadRowStyle(theme: t))
            #expect(view.drawsEdge == t.increaseContrast && view.drawsEdge == increase)
        }
    }
}
