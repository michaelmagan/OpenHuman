import Foundation
import Testing
@testable import MailTheme

@Suite struct BuiltinThemeTests {
    let library = ThemeLibrary.builtIn

    @Test func builtInsLoadWithZeroIssues() {
        let summaries = library.summaries
        #expect(summaries.count == 13)
        #expect(summaries.filter(\.isBuiltIn).count == 13)
        for summary in summaries {
            #expect(summary.issues.isEmpty, "\(summary.id): \(summary.issues)")
            #expect(summary.isUsable)
        }
        #expect(summaries.filter(\.isSelectable).map(\.id) == ["openhuman.light", "openhuman.dark", "openhuman.paper", "openhuman.midnight",
                                                                  "openhuman.system.light", "openhuman.system.dark"])
        #expect(library.accentIDs == ["periwinkle", "blue", "iris", "pine", "graphite", "system"])
    }

    @Test func everyRegistryTokenResolvesInEveryBuiltInAndAccent() {
        for theme in [BuiltinThemeID.light, BuiltinThemeID.dark, BuiltinThemeID.paper, BuiltinThemeID.midnight,
                      BuiltinThemeID.systemLight, BuiltinThemeID.systemDark] {
            for accent in BuiltinThemeID.accents {
                for appearance in ThemeAppearance.allCases {
                    #expect(library.completeTokens(themeID: theme, accentID: accent, appearance: appearance) != nil,
                            "\(theme) \(accent) \(appearance)")
                }
            }
        }
    }

    @Test func builtInsDefineOnlyRegistryTokens() throws {
        let registry = TokenRegistry.v1
        for (name, json) in BuiltinThemeSources.themes {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            for (section, value) in object {
                guard let dict = value as? [String: Any], section != "primitives" else { continue }
                if section == "light" || section == "dark" {
                    for key in dict.keys { #expect(registry.entry(named: key)?.layer == .accent, "\(name) \(section).\(key)") }
                    continue
                }
                func walk(_ node: [String: Any], _ path: [String]) {
                    for (key, child) in node {
                        let p = path + [key]
                        if registry.entry(at: p) != nil { continue }
                        if let next = child as? [String: Any], registry.isSection(p) { walk(next, p) } else {
                            Issue.record("\(name): \(p.joined(separator: ".")) is not in the registry")
                        }
                    }
                }
                walk(dict, [section])
            }
        }
    }

    @Test func registryDefaultsMatchBase() throws {
        let base = try #require(BuiltinThemeSources.themes.first { $0.name == "base.json" })
        let object = try #require(try JSONSerialization.jsonObject(with: Data(base.json.utf8)) as? [String: Any])
        for entry in TokenRegistry.v1.entries {
            guard let expected = entry.default else { continue }
            var node: Any? = object
            for key in entry.path { node = (node as? [String: Any])?[key] }
            switch expected {
            case .string(let s): #expect(node as? String == s, "\(entry.name)")
            case .number(let n): #expect((node as? NSNumber)?.doubleValue == n, "\(entry.name)")
            }
        }
    }

    @Test func systemThemesPassTheLintWithTheSystemAccentAndKeepDensity() {
        for (id, appearance) in [(BuiltinThemeID.systemLight, ThemeAppearance.light), (BuiltinThemeID.systemDark, .dark)] {
            let resolved = library.resolve(themeID: id, appearance: appearance)
            #expect(resolved.themeID == id && resolved.accentID == "system", "\(id)")
            #expect(resolved.issues.isEmpty, "\(id): \(resolved.issues)")
            #expect(ContrastLint.checks(for: resolved.tokens, accentID: "system").filter { !$0.passes }.isEmpty, "\(id)")
            let base = library.resolve(themeID: appearance == .dark ? BuiltinThemeID.dark : BuiltinThemeID.light, appearance: appearance).tokens
            #expect([resolved.tokens.densityCompactRow, resolved.tokens.densityDefaultRow, resolved.tokens.densityComfortableRow]
                    == [base.densityCompactRow, base.densityDefaultRow, base.densityComfortableRow])
            #expect(resolved.tokens.typeBody.size == 13 && resolved.tokens.typeBody.family == .system)
            #expect(resolved.tokens.typeMeta.size == 11 && resolved.tokens.typeCaption.size == 10)
        }
    }

    @Test func registryNamesAreUnique() {
        let entries = TokenRegistry.v1.entries
        #expect(entries.count == 303)
        #expect(Set(entries.map(\.key)).count == entries.count)
        #expect(Set(entries.filter { $0.layer != .component }.map(\.name)).count == entries.filter { $0.layer != .component }.count)
        #expect(Set(entries.filter { $0.layer != .component }.map(\.swift)).count == entries.filter { $0.layer != .component }.count)
    }

    @Test func embeddedSourcesMatchTheFiles() throws {
        let registry = try Repo.text(Repo.module.appendingPathComponent("Schema/tokens.v1.json"))
        #expect(BuiltinThemeSources.registry == registry, "run Tools/ThemeCodegen/run.sh")
        let names = try FileManager.default.contentsOfDirectory(atPath: Repo.module.appendingPathComponent("Themes").path)
            .filter { $0.hasSuffix(".json") }.count
            + FileManager.default.contentsOfDirectory(atPath: Repo.module.appendingPathComponent("Themes/accents").path)
            .filter { $0.hasSuffix(".json") }.count
        #expect(BuiltinThemeSources.themes.count == names)
        for (name, json) in BuiltinThemeSources.themes {
            #expect(json == (try Repo.text(Repo.module.appendingPathComponent("Themes/" + name))), "\(name): run Tools/ThemeCodegen/run.sh")
        }
    }

    @Test func generatedTokensCoverTheRegistry() {
        let tokens = ThemeTokens.light
        let registry = TokenRegistry.v1
        for entry in registry.entries {
            #expect(tokens.value(forKey: entry.key) != nil, "\(entry.key) has no accessor: run Tools/ThemeCodegen/run.sh")
        }
        let properties = Set(Mirror(reflecting: tokens).children.compactMap(\.label))
        let flat = Set(registry.entries.filter { $0.layer != .component }.map(\.swift))
        #expect(properties == flat.union(["component", "density", "reduceMotion", "increaseContrast"]))
        let groups = Set(Mirror(reflecting: tokens.component).children.compactMap(\.label))
        #expect(groups == Set(registry.entries.compactMap(\.groupSwift)))
        #expect(ColorToken.allCases.count == registry.entries.filter { $0.type == .color && ($0.layer == .semantic || $0.layer == .accent) }.count)
        #expect(TypeToken.allCases.count == 18)
    }

    @Test func semanticColorsMatchDesignTable() throws {
        let spec = try Repo.text(Repo.designSpec)
        let rows = markdownTable(in: spec, after: "### 2.1 Semantic color tokens")
        #expect(rows.count == 35)
        let tables: [ThemeTokens] = [.light, .dark, .paper, .midnight]
        for row in rows {
            let name = unticked(row[0])
            for (index, tokens) in tables.enumerated() {
                let cell = unticked(row[index + 1])
                guard let value = tokens.value(forKey: "semantic/color/" + name) else {
                    Issue.record("\(name) missing")
                    continue
                }
                switch value {
                case .color(let color): #expect(color == ThemeColor(literal: cell), "\(name) theme \(index): \(color.literal) vs \(cell)")
                case .shadow(let shadow): #expect(shadow == ThemeShadow(literal: cell), "\(name) theme \(index)")
                default: Issue.record("\(name) has an unexpected type")
                }
            }
        }
    }

    @Test func accentsMatchDesignTable() throws {
        let spec = try Repo.text(Repo.designSpec)
        let rows = markdownTable(in: spec, after: "### 2.2 Accent tokens")
        #expect(rows.count == 10)
        for row in rows {
            let appearance = ThemeAppearance(rawValue: row[1])!
            let resolved = library.resolve(themeID: appearance == .dark ? BuiltinThemeID.dark : BuiltinThemeID.light,
                                           appearance: appearance, preferences: ThemePreferences(accentID: row[0]))
            let expected = row[2...7].map { ThemeColor(literal: unticked($0)) }
            let actual = [resolved.accentFill, resolved.accentFillHover, resolved.accentText, resolved.accentSubtle,
                          resolved.accentOnFill, resolved.accentRing]
            #expect(actual == expected.compactMap { $0 }, "\(row[0]) \(row[1])")
        }
    }

    @Test func typographyMatchesDesignTable() throws {
        let spec = try Repo.text(Repo.designSpec)
        let rows = markdownTable(in: spec, after: "### 2.4 Typography")
        #expect(rows.count == 18)
        for row in rows {
            let token = try #require(TypeToken(rawValue: unticked(row[0])))
            let style = ThemeTokens.light.type(token)
            #expect(style.size == Double(row[1]) && style.lineHeight == Double(row[2]), "\(token)")
            #expect(row[3].hasPrefix(String(style.weight)), "\(token)")
            #expect(style.trackingEm == Double(row[4]), "\(token)")
            #expect(style.monospacedDigits == row[3].contains("tabular") || (token == .caption && style.monospacedDigits), "\(token)")
        }
        #expect(ThemeTokens.light.typeMono.family == .systemMono && ThemeTokens.light.typeMono.role == .mono)
        #expect(ThemeTokens.light.typeReader.role == .reader)
    }

    @Test func spacingRadiiDensityAndMotionMatchDesign() {
        let t = ThemeTokens.light
        #expect(t.space == [0, 2, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64])
        #expect([t.radiusXS, t.radiusSM, t.radiusMD, t.radiusLG, t.radiusXL, t.radiusPill] == [3, 4, 6, 8, 12, 999])
        #expect([t.densityCompactRow, t.densityDefaultRow, t.densityComfortableRow] == [32, 40, 48])
        #expect(t.motionEnterFast == ThemeMotion(durationMs: 100, easing: .cubicBezier(0.2, 0, 0, 1)))
        #expect(t.motionReveal == ThemeMotion(durationMs: 80, easing: .linear))
        #expect(t.motionInstant == ThemeMotion(durationMs: 0))
        #expect(t.motionToastAction == 6000)
        #expect(t.component.row.unreadDot == ThemeColor(hex: "#1F7FC8"))
        #expect(t.component.palette.radius == t.radiusSM)
        #expect(t.component.compose.shadow == t.shadow2)
        #expect(t.component.chipAI.borderSelected == t.textAI)
        #expect(t.readerEmailColors == .adaptWhenSafe && t.readerMaxImageWidth == 100)
        #expect(t.readerDesignedEmailCardBg == ThemeColor(r8: 255, g8: 255, b8: 255))
    }

    @Test func surfacesAndEdgesFollowTheElevationModel() {
        for t in [ThemeTokens.light, .paper] {
            #expect(t.component.thread.cardBg == t.bgCard && t.component.compose.bg == t.bgCard)
            #expect(t.component.thread.cardShadow == t.shadow1)
            #expect(t.bgCanvas == t.bgSunken)
        }
        #expect(ThemeTokens.light.bgCard == ThemeTokens.light.bgWindow)
        for t in [ThemeTokens.dark, .midnight] {
            #expect(t.bgCard == t.bgElevated && t.bgCard != t.bgWindow)
            #expect(t.component.thread.cardShadow.layers.count == 1)
            #expect(t.bgCanvas == t.bgSunken)
        }
        let t = ThemeTokens.light
        #expect([t.component.row.cursorInsetX, t.component.row.cursorInsetY, t.component.row.cursorBarWidth] == [6, 2, 3])
        #expect(t.component.row.cursorRadius == t.radiusMD && t.component.thread.focusEdgeWidth == 4)
        #expect(t.borderWidthCursorBar == 2 && t.readerQuoteBarWidth == 2, "the quote bar keeps 2 pt")
        #expect(t.component.avatar.size == 28 && t.component.avatar.bg == t.bgSunken && t.component.avatar.text == t.textSecondary)
        #expect(t.component.footer.height == 28 && t.component.footer.bg == t.bgWindow && t.component.footer.divider == t.borderHairline)
    }

    @Test func newSurfacesKeepTheirContrast() {
        let library = ThemeLibrary.builtIn
        let darkThemes = [BuiltinThemeID.dark, BuiltinThemeID.midnight, BuiltinThemeID.systemDark]
        for themeID in [BuiltinThemeID.light, BuiltinThemeID.paper, BuiltinThemeID.systemLight] + darkThemes {
            for accent in BuiltinThemeID.accents {
                for increase in [false, true] {
                    let appearance: ThemeAppearance = darkThemes.contains(themeID) ? .dark : .light
                    let t = library.resolve(themeID: themeID, appearance: appearance, preferences: ThemePreferences(accentID: accent),
                                            increaseContrast: increase).tokens
                    let label = "\(themeID) \(accent) increaseContrast=\(increase)"
                    let card = t.component.thread.cardBg
                    #expect(t.textPrimary.contrastRatio(on: card) >= 4.5, "text.primary on the card: \(label)")
                    #expect(t.textSecondary.contrastRatio(on: card) >= 4.5, "text.secondary on the card: \(label)")
                    #expect(t.textTertiary.contrastRatio(on: card) >= 4.5, "text.tertiary on the card: \(label)")
                    #expect(t.textPrimary.contrastRatio(on: t.bgCanvas) >= 4.5, "text.primary on the canvas: \(label)")
                    #expect(t.component.avatar.text.contrastRatio(on: t.component.avatar.bg) >= 4.5, "avatar initials: \(label)")
                    #expect(t.component.row.cursorBar.contrastRatio(on: card) >= 3, "focused edge on the card: \(label)")
                }
            }
        }
    }
}
