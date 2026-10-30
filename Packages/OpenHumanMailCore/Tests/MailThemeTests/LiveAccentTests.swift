import Foundation
import Testing
@testable import MailTheme

@Suite struct LiveAccentTests {
    let library = ThemeLibrary.builtIn

    static let samples: [(String, LiveAccent)] = [
        ("blue", LiveAccent(light: ThemeColor(hex: "#007AFF")!, dark: ThemeColor(hex: "#0A84FF")!)),
        ("purple", LiveAccent(light: ThemeColor(hex: "#953D96")!, dark: ThemeColor(hex: "#A550A7")!)),
        ("pink", LiveAccent(light: ThemeColor(hex: "#F74F9E")!, dark: ThemeColor(hex: "#F74F9E")!)),
        ("yellow", LiveAccent(light: ThemeColor(hex: "#FFC600")!, dark: ThemeColor(hex: "#FFC600")!)),
        ("green", LiveAccent(light: ThemeColor(hex: "#62BA46")!, dark: ThemeColor(hex: "#62BA46")!)),
        ("graphite", LiveAccent(light: ThemeColor(hex: "#8C8C8C")!, dark: ThemeColor(hex: "#8C8C8C")!)),
    ]

    @Test func everyLiveAccentPassesTheContrastChecks() {
        let themes: [(String, ThemeAppearance)] = [
            (BuiltinThemeID.systemLight, .light), (BuiltinThemeID.systemDark, .dark), (BuiltinThemeID.light, .light),
            (BuiltinThemeID.dark, .dark), (BuiltinThemeID.paper, .light), (BuiltinThemeID.midnight, .dark),
        ]
        for (name, live) in Self.samples {
            for (themeID, appearance) in themes {
                for increase in [false, true] {
                    let resolved = library.resolve(themeID: themeID, appearance: appearance,
                                                   preferences: ThemePreferences(accentID: "system"),
                                                   increaseContrast: increase, liveAccent: live)
                    let failing = ContrastLint.checks(for: resolved.tokens, accentID: "system").filter { !$0.passes }
                    #expect(failing.isEmpty, "\(name) on \(themeID) increaseContrast=\(increase): \(failing)")
                    #expect(resolved.issues.isEmpty, "\(name) on \(themeID): \(resolved.issues)")
                }
            }
        }
    }

    @Test func aContrastSafeAccentIsUsedAsIs() {
        let purple = Self.samples[1].1
        let light = library.resolve(ThemePreferences(), appearance: .light, liveAccent: purple)
        #expect(light.accentID == "system")
        #expect(light.accentFill == ThemeColor(hex: "#953D96") && light.accentOnFill == ThemeColor(hex: "#FFFFFF"))
        #expect(light.accentRing == ThemeColor(hex: "#953D96") && light.accentText == ThemeColor(hex: "#953D96"))
    }

    @Test func anAccentShortOfContrastIsDarkenedOnlyAsFarAsNeeded() {
        let blue = Self.samples[0].1
        let light = library.resolve(ThemePreferences(), appearance: .light, liveAccent: blue)
        #expect(light.accentFill != ThemeColor(hex: "#007AFF") && light.accentOnFill == ThemeColor(hex: "#FFFFFF"))
        #expect(light.accentOnFill.contrastRatio(on: light.accentFill) >= 4.5)
        #expect(light.accentFill.contrastRatio(on: ThemeColor(hex: "#007AFF")!) < 1.3, "still reads as the same blue")
    }

    @Test func aLightAccentGetsDarkTextOnItsFill() {
        let yellow = Self.samples[3].1
        let light = library.resolve(ThemePreferences(), appearance: .light, liveAccent: yellow)
        #expect(light.accentFill == ThemeColor(hex: "#FFC600") && light.accentOnFill == ThemeColor(hex: "#000000"))
        #expect(light.accentText != light.accentFill && light.accentText.contrastRatio(on: light.bgWindow) >= 4.5)
    }

    @Test func componentsThatReferToTheAccentFollowIt() {
        let pink = Self.samples[2].1
        let resolved = library.resolve(ThemePreferences(), appearance: .light, liveAccent: pink)
        #expect(resolved.component.row.bgCursor == resolved.accentSubtle)
        #expect(resolved.component.focus.ring == resolved.accentRing)
        #expect(resolved.accentSubtle != library.resolve(ThemePreferences(), appearance: .light).accentSubtle)
    }

    @Test func otherAccentsIgnoreTheLiveAccent() {
        let pink = Self.samples[2].1
        let iris = library.resolve(ThemePreferences(accentID: "iris"), appearance: .light, liveAccent: pink)
        #expect(iris.tokens == library.resolve(ThemePreferences(accentID: "iris"), appearance: .light).tokens)
        let paper = library.resolve(ThemePreferences(lightThemeID: BuiltinThemeID.paper), appearance: .light, liveAccent: pink)
        #expect(paper.tokens == ThemeTokens.paper)
    }

    @Test func withoutALiveAccentTheSystemAccentKeepsItsFile() {
        let resolved = library.resolve(ThemePreferences(), appearance: .light)
        #expect(resolved.accentID == "system" && resolved.accentFill == ThemeColor(hex: "#0060DF"))
    }

    @Test func eachAppearanceUsesItsOwnColor() {
        let purple = Self.samples[1].1
        #expect(purple.color(for: .light) == ThemeColor(hex: "#953D96") && purple.color(for: .dark) == ThemeColor(hex: "#A550A7"))
        let dark = library.resolve(ThemePreferences(), appearance: .dark, liveAccent: purple)
        #expect(dark.accentFill == ThemeColor(hex: "#A550A7"))
    }
}
