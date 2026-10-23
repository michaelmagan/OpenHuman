import Foundation
import Testing
@testable import MailTheme

@Suite struct ResolutionTests {
    let library = ThemeLibrary.builtIn

    @Test func defaultsAreTheSystemThemesWithTheSystemAccentFollowingSystem() {
        let prefs = ThemePreferences()
        #expect(prefs.mode == .system && prefs.accentID == nil)
        let light = library.resolve(prefs, appearance: prefs.mode.effective(system: .light))
        #expect(light.themeID == BuiltinThemeID.systemLight && light.accentID == "system" && light.appearance == .light)
        #expect(light.issues.isEmpty)
        let dark = library.resolve(prefs, appearance: prefs.mode.effective(system: .dark))
        #expect(dark.themeID == BuiltinThemeID.systemDark && dark.accentID == "system" && dark.appearance == .dark)
        #expect(dark.issues.isEmpty)
        #expect(ResolvedTheme.light.tokens == ThemeTokens.light && ResolvedTheme.dark.tokens == ThemeTokens.dark)
    }

    @Test func theSystemThemesUseAPlainWindowCanvas() {
        let light = library.resolve(ThemePreferences(), appearance: .light)
        #expect(light.bgCanvas == ThemeColor(hex: "#FFFFFF") && light.bgCanvas == light.bgWindow)
        let dark = library.resolve(ThemePreferences(), appearance: .dark)
        #expect(dark.bgCanvas == ThemeColor(hex: "#1E1E1E") && dark.bgCanvas == dark.bgWindow)
    }

    @Test func fixedModesIgnoreTheSystem() {
        #expect(AppearanceMode.light.effective(system: .dark) == .light)
        #expect(AppearanceMode.dark.effective(system: .light) == .dark)
        #expect(AppearanceMode.system.effective(system: .dark) == .dark)
    }

    @Test func slotsPickTheThemes() {
        let prefs = ThemePreferences(lightThemeID: BuiltinThemeID.paper, darkThemeID: BuiltinThemeID.midnight)
        #expect(library.resolve(prefs, appearance: .light).tokens == ThemeTokens.paper)
        #expect(library.resolve(prefs, appearance: .dark).tokens == ThemeTokens.midnight)
        #expect(ThemeTokens.paper.bgWindow == ThemeColor(hex: "#FBF8F2"))
        #expect(ThemeTokens.midnight.bgWindow == ThemeColor(hex: "#0E1116"))
        #expect(ThemeTokens.paper.shadow2 == ThemeTokens.light.shadow2)
        #expect(ThemeTokens.midnight.shadow3 == ThemeTokens.dark.shadow3)
    }

    @Test func accentPreferenceOverridesTheThemeDefault() {
        let iris = library.resolve(ThemePreferences(accentID: "iris"), appearance: .light)
        #expect(iris.accentID == "iris")
        #expect(iris.accentRing == ThemeColor(hex: "#5B45E0"))
        #expect(iris.component.row.unreadDot == ThemeColor(hex: "#1F7FC8"))
        #expect(iris.component.link.text == iris.textLink && iris.textLink == ThemeColor(hex: "#2272AE"))
        let missing = library.resolve(ThemePreferences(accentID: "sunset"), appearance: .light)
        #expect(missing.accentID == "periwinkle")
        #expect(missing.issues.contains { $0.code == .unknownAccent })
    }

    @Test func densityReaderSizeAndFonts() {
        var prefs = ThemePreferences(density: .compact, readerTextSize: 17, uiFont: .named("Inter"), readerFont: .systemSerif)
        var resolved = library.resolve(prefs, appearance: .light)
        #expect(resolved.rowHeight == 32 && resolved.splitRowHeight == 48)
        #expect(resolved.typeReader.size == 17 && resolved.typeReader.lineHeight == 27)
        #expect(resolved.typeBody.family == .named("Inter"))
        #expect(resolved.typeReader.family == .systemSerif)
        #expect(resolved.typeMono.family == .systemMono)
        #expect(resolved.typeTitle.effectiveTracking == -0.2)
        #expect(ThemeTokens.light.typeTitle.effectiveTracking == 0)
        prefs.readerTextSize = 40
        resolved = library.resolve(prefs, appearance: .light)
        #expect(resolved.typeReader.size == 20)
        prefs.density = .comfortable
        #expect(library.resolve(prefs, appearance: .light).rowHeight == 48)
    }

    @Test func emailColorsPreferenceWins() {
        #expect(library.resolve(ThemePreferences(), appearance: .light).emailColors == .adaptWhenSafe)
        #expect(library.resolve(ThemePreferences(emailColors: .alwaysOriginal), appearance: .dark).emailColors == .alwaysOriginal)
    }

    @Test func increaseContrastMapsBordersAndTertiaryText() {
        let resolved = library.resolve(ThemePreferences(lightThemeID: BuiltinThemeID.light), appearance: .light, increaseContrast: true)
        #expect(resolved.borderHairline == ThemeTokens.light.borderControl)
        #expect(resolved.textTertiary == ThemeTokens.light.textSecondary)
        #expect(resolved.component.toolbar.divider == ThemeTokens.light.borderControl)
        #expect(resolved.component.row.groupHeader == ThemeTokens.light.textSecondary)
        #expect(resolved.component.row.chipBg == ThemeTokens.light.textDisabled)
        #expect(resolved.component.row.chipText == ThemeTokens.light.textPrimary)
        #expect(resolved.component.tab.text == ThemeTokens.light.textSecondary)
        #expect(resolved.component.tab.count == ThemeTokens.light.textSecondary)
    }

    @Test func unavailableThemeFallsBackToTheBuiltInForTheSlot() {
        let resolved = library.resolve(ThemePreferences(lightThemeID: "me.gone"), appearance: .light)
        #expect(resolved.themeID == BuiltinThemeID.light)
        #expect(resolved.issues.contains { $0.code == .themeUnavailable })
        #expect(library.resolve(ThemePreferences(lightThemeID: BuiltinThemeID.base), appearance: .light).themeID == BuiltinThemeID.light)
    }

    @Test func userThemeOverridesAndInheritsAndFallsBack() throws {
        var library = library
        let object = userTheme(id: "me.solar", name: "Solar", appearance: "light", extends: "openhuman.light", extra: [
            "defaultAccent": "pine",
            "primitives": ["color": ["sun.980": "#FFFBF0", "gray.102": "#202020"]],
            "semantic": ["color": ["bg.window": "{sun.980}", "bg.sidebar": "not-a-color-at-all"]],
            "components": ["row": ["paddingX": 20, "bgCursor": "{bg.sunken}"]],
        ])
        let summary = library.add(data: themeJSON(object), source: .user(URL(fileURLWithPath: "/tmp/solar.json")))
        #expect(summary.isSelectable)
        #expect(summary.issues.contains { $0.code == .invalidValue && $0.path == "semantic.color.bg.sidebar" })
        let resolved = library.resolve(ThemePreferences(lightThemeID: "me.solar"), appearance: .light)
        #expect(resolved.themeID == "me.solar" && resolved.themeName == "Solar")
        #expect(resolved.bgWindow == ThemeColor(hex: "#FFFBF0"))
        #expect(resolved.bgSidebar == ThemeTokens.light.bgSidebar)
        #expect(resolved.textPrimary == ThemeColor(hex: "#202020"))
        #expect(resolved.component.row.paddingX == 20)
        #expect(resolved.component.row.bgCursor == ThemeTokens.light.bgSunken)
        #expect(resolved.component.row.bgHover == ThemeTokens.light.bgRowHover)
        #expect(resolved.accentID == "pine")
        #expect(resolved.typeBody == ThemeTokens.light.typeBody)
    }

    @Test func rootThemeWithoutParentFallsBackForMissingTokens() {
        var library = library
        let object = userTheme(id: "me.tiny", appearance: "dark", extends: NSNull(), extra: [
            "semantic": ["color": ["bg.window": "#101010", "text.primary": "#F0F0F0"]],
        ])
        let summary = library.add(data: themeJSON(object), source: .user(URL(fileURLWithPath: "/tmp/tiny.json")))
        #expect(summary.isUsable)
        #expect(summary.issues.contains { $0.code == .missingToken })
        let resolved = library.resolve(ThemePreferences(darkThemeID: "me.tiny"), appearance: .dark)
        #expect(resolved.bgWindow == ThemeColor(hex: "#101010"))
        #expect(resolved.bgSidebar == ThemeTokens.dark.bgSidebar)
        #expect(resolved.component.palette.width == 680)
    }

    @Test func anyAppearanceThemeFollowsTheSlot() {
        var library = library
        let object = userTheme(id: "me.both", appearance: "any", extends: "openhuman.base", extra: [
            "semantic": ["color": ["bg.window": "#808080"]],
        ])
        library.add(data: themeJSON(object), source: .user(URL(fileURLWithPath: "/tmp/both.json")))
        let dark = library.resolve(ThemePreferences(darkThemeID: "me.both"), appearance: .dark)
        #expect(dark.appearance == .dark)
        #expect(dark.accentRing == ThemeTokens.dark.accentRing)
        #expect(dark.textPrimary == ThemeTokens.dark.textPrimary)
    }

    @Test func preferencesSurviveACorruptStore() throws {
        let json = #"{"mode":"sideways","lightThemeID":"BAD ID","accentID":"iris","density":"compact","uiFont":"Inter;x","readerTextSize":"big"}"#
        let prefs = try JSONDecoder().decode(ThemePreferences.self, from: Data(json.utf8))
        #expect(prefs.mode == .system && prefs.lightThemeID == BuiltinThemeID.systemLight)
        #expect(prefs.accentID == "iris" && prefs.density == .compact)
        #expect(prefs.uiFont == nil && prefs.readerTextSize == nil)
        let store = MemoryThemePreferencesStore()
        store.save(prefs)
        #expect(store.load() == prefs)
        let roundTrip = try JSONDecoder().decode(ThemePreferences.self, from: JSONEncoder().encode(
            ThemePreferences(mode: .dark, accentID: "pine", readerTextSize: 16, uiFont: .named("IBM Plex Sans"), emailColors: .alwaysAdapt)))
        #expect(roundTrip.uiFont == .named("IBM Plex Sans") && roundTrip.readerTextSize == 16 && roundTrip.emailColors == .alwaysAdapt)
    }
}
