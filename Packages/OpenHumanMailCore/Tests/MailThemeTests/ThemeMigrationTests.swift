import Foundation
import Testing
@testable import MailTheme

@Suite struct ThemeMigrationTests {
    private func legacy(_ fields: String) throws -> ThemePreferences {
        try JSONDecoder().decode(ThemePreferences.self, from: Data("{\(fields)}".utf8))
    }

    @Test func newPreferencesAreCurrentAndUseTheSystemThemes() {
        let prefs = ThemePreferences()
        #expect(prefs.version == ThemePreferences.currentVersion)
        #expect(prefs.lightThemeID == BuiltinThemeID.systemLight && prefs.darkThemeID == BuiltinThemeID.systemDark)
        #expect(prefs.accentID == nil && prefs.mode == .system)
        #expect(prefs.migrated() == prefs)
    }

    @Test func builtInLightAndDarkMoveToTheSystemThemes() throws {
        let old = try legacy(#""mode":"system","lightThemeID":"openhuman.light","darkThemeID":"openhuman.dark","density":"compact""#)
        #expect(old.version == 0)
        let moved = old.migrated()
        #expect(moved.lightThemeID == BuiltinThemeID.systemLight && moved.darkThemeID == BuiltinThemeID.systemDark)
        #expect(moved.density == .compact && moved.mode == .system)
        #expect(moved.version == ThemePreferences.currentVersion)
    }

    @Test func paperMidnightAndCustomThemesStay() throws {
        let paper = try legacy(#""lightThemeID":"openhuman.paper","darkThemeID":"openhuman.midnight""#).migrated()
        #expect(paper.lightThemeID == BuiltinThemeID.paper && paper.darkThemeID == BuiltinThemeID.midnight)
        let custom = try legacy(#""lightThemeID":"me.solar","darkThemeID":"openhuman.dark""#).migrated()
        #expect(custom.lightThemeID == "me.solar" && custom.darkThemeID == BuiltinThemeID.systemDark)
    }

    @Test func aChosenAccentAndOtherSettingsSurvive() throws {
        let moved = try legacy(#""lightThemeID":"openhuman.light","accentID":"pine","readerTextSize":16,"emailColors":"alwaysAdapt""#)
            .migrated()
        #expect(moved.lightThemeID == BuiltinThemeID.systemLight)
        #expect(moved.accentID == "pine" && moved.readerTextSize == 16 && moved.emailColors == .alwaysAdapt)
    }

    @Test func theMoveHappensOnce() throws {
        var moved = try legacy(#""lightThemeID":"openhuman.light""#).migrated()
        moved.lightThemeID = BuiltinThemeID.light
        let saved = try JSONDecoder().decode(ThemePreferences.self, from: JSONEncoder().encode(moved))
        #expect(saved.version == ThemePreferences.currentVersion)
        #expect(saved.migrated().lightThemeID == BuiltinThemeID.light, "Light picked after the move is kept")
    }

    @Test func aLaterVersionIsLeftAlone() throws {
        let future = try legacy(#""lightThemeID":"openhuman.light","version":7"#)
        #expect(future.migrated().lightThemeID == BuiltinThemeID.light && future.migrated().version == 7)
        let negative = try legacy(#""lightThemeID":"openhuman.light","version":-3"#)
        #expect(negative.version == 0 && negative.migrated().lightThemeID == BuiltinThemeID.systemLight)
    }
}
