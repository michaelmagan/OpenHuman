#if os(macOS)
import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI

private let fixedNow = Date(timeIntervalSince1970: 1_791_000_000)

private let pageWidth = SettingsMetrics.windowWidth - SettingsMetrics.sidebarWidth - 1

@MainActor
private func environment() -> AppEnvironment {
    AppEnvironment.fake(corpus: .rich(threadCount: 20, now: fixedNow), options: .init(remoteAck: .immediate),
                        featureFlags: FeatureFlags())
}

@MainActor
private func environmentWithSystem() async throws -> AppEnvironment {
    let env = environment()
    env.installPlatform(SystemPlatform(notifier: FakeSystemNotifier(authorization: .denied), dock: FakeDockBadge(),
                                       loginItem: FakeLoginItem(status: .requiresApproval), urlOpener: FakeURLOpener(),
                                       isAppActive: { false }))
    env.runLaunchTasks()
    try await until("the system modules") { env.system.notifications != nil && env.system.launchAtLogin != nil }
    return env
}

@MainActor
private func until(_ what: String, timeout: Duration = testBackstop, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting for \(what)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private final class Stage {
    let window: NSWindow
    let theme: ResolvedTheme

    init<V: View>(_ view: V, width: CGFloat, height: CGFloat, theme: ResolvedTheme) {
        self.theme = theme
        let scheme: ColorScheme = theme.appearance == .dark ? .dark : .light
        let hosting = NSHostingView(rootView: view.environment(\.theme, theme).environment(\.colorScheme, scheme)
            .tint(theme.accentFill.color))
        window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: width, height: height), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
    }

    func close() { window.orderOut(nil) }

    func render(_ name: String) throws -> (pixels: Pixels, scale: CGFloat, size: CGSize) {
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        try writeSnapshot(image, name)
        let pixels = try #require(Pixels(image))
        return (pixels, CGFloat(rep.pixelsWide) / max(rep.size.width, 1), rep.size)
    }

    /// The page's own background, read from its top-right corner: the grouped form draws a system colour there.
    func background(of shot: (pixels: Pixels, scale: CGFloat, size: CGSize)) -> ThemeColor {
        let pixel = shot.pixels.at(shot.size.width - 2, 2, scale: shot.scale)
        return ThemeColor(red: Double(pixel.0) / 255, green: Double(pixel.1) / 255, blue: Double(pixel.2) / 255)
    }

    func strays(in x: ClosedRange<CGFloat>, of shot: (pixels: Pixels, scale: CGFloat, size: CGSize),
                color: ThemeColor) -> [CGPoint] {
        var out: [CGPoint] = []
        var y: CGFloat = 1
        while y < shot.size.height - 1 {
            var px = x.lowerBound
            while px <= x.upperBound {
                if !matches(shot.pixels.at(px, y, scale: shot.scale), color, tolerance: 6) { out.append(CGPoint(x: px, y: y)) }
                px += 4
            }
            y += 2
        }
        return out
    }
}

@MainActor
@Suite(.serialized)
struct SettingsLayoutTests {
    @Test func aSectionWithoutRowsDrawsNothing() {
        let width = CGSize(width: 400, height: 1000)
        func height<V: View>(_ view: V) -> CGFloat {
            NSHostingController(rootView: view.environment(\.theme, .light)).sizeThatFits(in: width).height
        }
        #expect(height(SettingsSection("Empty") { EmptyView() }) == 0)
        #expect(height(SettingsSection("Hosted") { AnyView(EmptyView()) }) == 0, "an app-hosted extra that is off")
        #expect(height(SettingsSection("No rows", footnote: "Never shown.") { ForEach([Int](), id: \.self) { Text("\($0)") } }) == 0)
        let shown = false
        #expect(height(SettingsSection("Off") { if shown { SettingsRow("Hidden") } }) == 0)
        let one = height(SettingsSection("One") { SettingsRow("A row") })
        let two = height(SettingsSection("Two") { SettingsRow("A row"); SettingsRow("Another row") })
        #expect(one > SettingsMetrics.rowMinHeight)
        #expect(two - one >= SettingsMetrics.rowMinHeight, "every row keeps the row height")
        let hosted = height(SettingsSection("Two") { AnyView(Group { SettingsRow("A row"); SettingsRow("Another row") }) })
        #expect(hosted == two, "rows inside an AnyView are still separate rows")
    }

    @Test func hostedSectionsStaySeparateSectionsOfThePage() {
        let width = CGSize(width: 400, height: 1000)
        func height<V: View>(_ view: V) -> CGFloat {
            NSHostingController(rootView: view.environment(\.theme, .light)).sizeThatFits(in: width).height
        }
        let stacked = height(SettingsSectionStack {
            SettingsSection("One", footnote: "A note.") { SettingsRow("A row") }
            SettingsSection("Two", footnote: "A note.") { SettingsRow("A row") }
        })
        let loose = height(Group {
            SettingsSection("One", footnote: "A note.") { SettingsRow("A row") }
            SettingsSection("Two", footnote: "A note.") { SettingsRow("A row") }
        })
        #expect(abs(stacked - loose) < 1, "the stack adds no container of its own (\(stacked) vs \(loose))")
    }

    @Test func aRowWrapsItsTextAndKeepsTheControlInside() {
        let long = String(repeating: "A long setting title that has to wrap ", count: 4)
        let row = SettingsRow(long, detail: "And a detail line that also wraps when the row is narrow.", isOn: .constant(true))
        let size = NSHostingController(rootView: row.environment(\.theme, .light)).sizeThatFits(in: CGSize(width: 300, height: 1000))
        #expect(size.width <= 300)
        #expect(size.height > SettingsMetrics.rowMinHeight, "the title wrapped instead of pushing the switch out")
        let compact = SettingsSection(compact: true) { SettingsRow("Archive") { KeycapView(text: "E") } }
        let compactHeight = NSHostingController(rootView: compact.environment(\.theme, .light))
            .sizeThatFits(in: CGSize(width: 300, height: 1000)).height
        #expect(compactHeight < SettingsMetrics.rowMinHeight, "list-like sections drop the control-height floor")
    }

    @Test func theCleanupAddRowKeepsItsTitleOnOneLineAtThePageWidth() {
        let theme = ResolvedTheme.light
        let rowWidth = pageWidth - 2 * theme.space8 - 2 * theme.space4
        let model = CleanupRulesModel(settings: nil)
        func fitted(_ width: CGFloat) -> CGSize {
            NSHostingController(rootView: CleanupAddRow(model: model).environment(\.theme, theme))
                .sizeThatFits(in: CGSize(width: width, height: 1000))
        }
        let atPage = fitted(rowWidth)
        let wide = fitted(2000)
        #expect(atPage.width <= rowWidth + 0.5, "the field, menu and button fit the row (\(atPage.width) of \(rowWidth))")
        #expect(abs(atPage.height - wide.height) < 0.5,
                "“\(CleanupAddRow.title)” wraps at the page width: \(atPage.height) pt tall, \(wide.height) pt with room")
    }

    @Test func thePersonalWritingFieldsShareOneWidthWhateverTheyHold() {
        let theme = ResolvedTheme.light
        func width(_ prompt: String, _ text: String) -> CGFloat {
            let field = SettingsTextArea(title: "Field", prompt: prompt, text: .constant(text))
            return NSHostingController(rootView: field.environment(\.theme, theme))
                .sizeThatFits(in: CGSize(width: 1000, height: 1000)).width
        }
        let about = width(AISettingsPageModel.aboutMePrompt, "")
        #expect(about == SettingsTextArea.width)
        #expect(width(AISettingsPageModel.writingInstructionsPrompt, "") == about, "the two fields line up")
        #expect(width("", String(repeating: "Short and warm, first names, no sign-off. ", count: 8)) == about,
                "typing doesn't widen the field")
        let rowWidth = pageWidth - 2 * theme.space8 - 2 * theme.space4
        for (title, prompt) in [(AISettingsPageModel.aboutMeTitle, AISettingsPageModel.aboutMePrompt),
                                (AISettingsPageModel.writingInstructionsTitle, AISettingsPageModel.writingInstructionsPrompt)] {
            let row = SettingsRow(title, alignment: .firstTextBaseline, labelsControl: true) {
                SettingsTextArea(title: title, prompt: prompt, text: .constant(""))
            }
            let fitted = NSHostingController(rootView: row.environment(\.theme, theme))
                .sizeThatFits(in: CGSize(width: rowWidth, height: 1000))
            #expect(fitted.width <= rowWidth + 0.5, "\(title) fits the row (\(fitted.width) of \(rowWidth))")
        }
    }

    @Test func everyPageTitleFitsTheSidebar() {
        let theme = ResolvedTheme.light
        let pages = SettingsShellModel(environment: environment()).pages
        #expect(pages.contains { $0.id == ImportanceSettingsModel.pageID }, "the longest title is listed")
        let room = SettingsMetrics.sidebarWidth - 2 * theme.space6
        for entry in pages {
            let row = SettingsSidebarRow(entry: entry)
                .fixedSize()
                .environment(\.theme, theme)
            let needed = NSHostingController(rootView: row).sizeThatFits(in: CGSize(width: 1000, height: 100)).width
            #expect(needed <= room, "“\(entry.title)” needs \(needed) pt of \(room)")
        }
    }

    @Test(arguments: [("light", ResolvedTheme.light), ("dark", ResolvedTheme.dark)])
    func aSettingsFieldsPlaceholderIsTertiary(_ name: String, _ theme: ResolvedTheme) throws {
        let field = TextField("Search", text: .constant(""), prompt: Text("Search shortcuts").settingsPrompt(theme))
            .settingsTextField()
            .frame(width: 240)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.bgWindow.color)
        let stage = Stage(field, width: 300, height: 80, theme: theme)
        defer { stage.close() }
        let shot = try stage.render("settings-field-placeholder-\(name)")
        func luminance(_ pixel: (Int, Int, Int)) -> Int { (pixel.0 + pixel.1 + pixel.2) / 3 }
        func luminance(_ color: ThemeColor) -> Int { Int(((color.red + color.green + color.blue) / 3 * 255).rounded()) }
        let fill = luminance(theme.bgWindow)
        let tertiary = abs(luminance(theme.textTertiary) - fill)
        var strongest = 0
        var y: CGFloat = 23
        while y <= 41 {
            var x: CGFloat = 23
            while x <= 257 {
                strongest = max(strongest, abs(luminance(shot.pixels.at(x, y, scale: shot.scale)) - fill))
                x += 1 / shot.scale
            }
            y += 1 / shot.scale
        }
        #expect(strongest >= tertiary / 2, "the placeholder is drawn (\(name): \(strongest) of \(tertiary))")
        #expect(strongest <= tertiary + 14, "the placeholder is text.tertiary, not darker (\(name): \(strongest) > \(tertiary))")
    }

    @Test func theSidebarFooterShowsTheVersionAndTheEarlyDevelopmentNotice() {
        #expect(SettingsBuildFooter.lines(BuildLabel(version: "0.1.0", build: "1001", channel: "early-development"))
                == ["Version 0.1.0 (1001)", "Early development build — expect rough edges. Please send feedback."])
        #expect(SettingsBuildFooter.lines(BuildLabel(version: "1.0.0", build: "7", channel: "")) == ["Version 1.0.0 (7)"])
    }

    @Test func signedOutTheSameShellShowsOnlyAppearanceAndAdvanced() {
        let pages = SettingsShellView.standalonePages(SettingsShellModel.standalone().pages)
        #expect(pages.map(\.id) == [SettingsPageID.appearance.rawValue, SettingsPageID.advanced.rawValue])
        let publicPages = SettingsShellView.standalonePages(SettingsShellModel.standalone().pages, showsAdvanced: false)
        #expect(publicPages.map(\.id) == [SettingsPageID.appearance.rawValue])
        #expect(!SettingsHosting().showsDeveloperItems, "what a public build shows, unless the app says otherwise")
        #expect(!SettingsHosting().offersDeveloperSettings, "and no developer options switch")
    }

    @Test(arguments: [("light", ResolvedTheme.light), ("dark", ResolvedTheme.dark)])
    func theShellListsThePagesInANativeSidebar(_ name: String, _ theme: ResolvedTheme) throws {
        let env = environment()
        let pages = SettingsShellModel(environment: env).pages
        let stage = Stage(SettingsShellView(environment: env, hosting: SettingsHosting(), defaults: .standard),
                          width: SettingsMetrics.windowWidth, height: SettingsMetrics.windowHeight, theme: theme)
        defer { stage.close() }
        _ = try stage.render("settings-window-\(name)")
        let root = try #require(stage.window.contentView)
        let sidebar = try #require(Self.tables(in: root).first { $0.numberOfRows == pages.count },
                                   "the pages are the rows of a native list")
        #expect(sidebar.selectedRow >= 0, "the open page is selected in the list")
    }

    /// Shorter than the page list with the build notice under it, so the list has to scroll.
    static let shortWindow = CGSize(width: SettingsMetrics.windowWidth, height: 360)

    @Test(arguments: [("light", ResolvedTheme.light), ("dark", ResolvedTheme.dark)])
    func theSidebarScrollsToItsLastPageInAShortWindow(_ name: String, _ theme: ResolvedTheme) throws {
        let env = environment()
        let pages = SettingsShellModel(environment: env).pages
        let build = BuildLabel(version: "0.1.0", build: "1001", channel: BuildLabel.earlyDevelopmentChannel)
        let size = Self.shortWindow
        let stage = Stage(SettingsShellView(environment: env, hosting: SettingsHosting(build: build), defaults: .standard),
                          width: size.width, height: size.height, theme: theme)
        defer { stage.close() }
        _ = try stage.render("settings-window-short-\(name)")
        let root = try #require(stage.window.contentView)
        #expect(root.bounds.size == size, "the window keeps its size instead of growing to fit the list (\(root.bounds.size))")
        let sidebar = try #require(Self.tables(in: root).first { $0.numberOfRows == pages.count })
        let scroll = try #require(sidebar.enclosingScrollView, "the page list scrolls")
        let frame = scroll.convert(scroll.bounds, to: nil)
        #expect(Self.inside(size).contains(frame), "the list stays inside the window: \(frame)")
        #expect(frame.width >= SettingsMetrics.sidebarWidth - 0.5, "the sidebar keeps its width: \(frame.width)")
        let last = pages.count - 1
        let insets = scroll.contentInsets
        let shown = scroll.contentView.bounds.height - insets.top - insets.bottom
        #expect(sidebar.rect(ofRow: last).maxY > shown, "the pages need more room than the window has")
        sidebar.scrollRowToVisible(last)
        root.layoutSubtreeIfNeeded()
        let visible = scroll.contentView.bounds
        let row = sidebar.convert(sidebar.rect(ofRow: last), to: scroll.contentView)
        #expect(row.minY >= visible.minY + insets.top - 0.5 && row.maxY <= visible.maxY - insets.bottom + 0.5,
                "the last page scrolls into view above the build notice: \(row) in \(visible), insets \(insets)")
    }

    @Test func everyPageScrollsInsideAShortWindow() async throws {
        let env = environment()
        let themes = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: .system)))
        let notifications = NotificationsSettingsModel(environment: env)
        let hosting = SettingsHosting(
            appearance: { AnyView(AppearanceSettingsView(store: themes, fontFamilies: ["Inter"])) },
            notifications: { AnyView(NotificationsSettingsView(model: notifications)) },
            build: BuildLabel(version: "0.1.0", build: "1001", channel: BuildLabel.earlyDevelopmentChannel))
        let size = Self.shortWindow
        let pages = SettingsShellModel(environment: env).pages
        for (index, page) in pages.enumerated() {
            env.settingsNavigator.open(page.id)
            let stage = Stage(SettingsShellView(environment: env, hosting: hosting, defaults: .standard),
                              width: size.width, height: size.height, theme: .light)
            defer { stage.close() }
            let root = try #require(stage.window.contentView)
            // A row below the short sidebar's fold reports its selection once it has scrolled into view
            try await until("the \(page.id) page", timeout: .seconds(10)) {
                root.layoutSubtreeIfNeeded()
                guard let sidebar = Self.tables(in: root).first(where: { $0.numberOfRows == pages.count }) else {
                    return false
                }
                if sidebar.selectedRow != index { sidebar.scrollRowToVisible(index) }
                return sidebar.selectedRow == index
            }
            _ = try stage.render("settings-page-short-\(page.id)")
            #expect(root.bounds.size == size, "\(page.id) keeps the window's size (\(root.bounds.size))")
            let split = try #require(Self.splitViews(in: root).first { $0.isVertical && $0.arrangedSubviews.count >= 2 },
                                     "\(page.id) is in the split view")
            let pane = try #require(split.arrangedSubviews.last)
            let scrolls = Self.scrollViews(in: pane).filter { !$0.isHiddenOrHasHiddenAncestor }
            #expect(!scrolls.isEmpty, "\(page.id) scrolls its content")
            for scroll in scrolls {
                let frame = scroll.convert(scroll.bounds, to: nil)
                #expect(Self.inside(size).contains(frame), "\(page.id) scrolls inside the window: \(frame)")
            }
        }
    }

    @Test func advancedListsOnlyTheModulesThatNeedARestart() throws {
        let defaults = ScopedDefaults("openhuman.test.settings-layout")
        defer { defaults.cleanup() }
        let model = FeaturesSettingsModel(modules: ModuleList.all, registered: [], defaults: defaults)
        let ids = AdvancedSettingsPage.restartRows(model.rows).map(\.id)
        #expect(!ids.isEmpty)
        for live in FeatureModuleID.startsAtOnce { #expect(!ids.contains(live), "\(live) has its live switch elsewhere") }
        #expect(FeatureModuleID.startsAtOnce.contains(.appIntents) && FeatureModuleID.startsAtOnce.contains(.focusFilters))
        #expect(AdvancedSettingsPage.restartRows(model.rows).allSatisfy { !$0.detail.isEmpty && $0.title != $0.id.rawValue },
                "every row has a title and a line under it")
    }

    @Test func aPublicBuildListsOnlyTheUsersOwnFeatureSwitches() throws {
        let defaults = ScopedDefaults("openhuman.test.settings-layout")
        defer { defaults.cleanup() }
        let model = FeaturesSettingsModel(modules: ModuleList.all, registered: [], defaults: defaults)
        let developer = AdvancedSettingsPage.featureRows(model.rows, developer: true).map(\.id)
        #expect(developer == AdvancedSettingsPage.restartRows(model.rows).map(\.id))
        let shown = Set(AdvancedSettingsPage.featureRows(model.rows, developer: false).map(\.id))
        #expect(shown.isSubset(of: FeaturesSettingsModel.userFacing))
        #expect(shown.contains(.ai) && !shown.contains(.diagnostics) && !shown.contains(.snooze))
    }

    @Test func missingPlatformFeaturesAreOneLinePerRequirement() {
        let catalog = [PlatformFeature(id: "a", title: "Alpha", detail: ""), PlatformFeature(id: "b", title: "Beta", detail: ""),
                       PlatformFeature(id: "c", title: "Gamma", detail: "", requirement: "A paid account")]
        let rows = PlatformFeaturesModel(availability: PlatformFeatureAvailability(available: ["b"]), catalog: catalog).rows
        let groups = PlatformFeaturesPage.notYet(rows)
        #expect(groups == [PlatformFeaturesPage.MissingGroup(id: "A notarized build", titles: ["Alpha"]),
                           PlatformFeaturesPage.MissingGroup(id: "A paid account", titles: ["Gamma"])])
    }

    @Test(arguments: [("light", ResolvedTheme.light), ("dark", ResolvedTheme.dark)])
    func noPageRunsIntoTheMarginAtTheSmallestWindow(_ name: String, _ theme: ResolvedTheme) async throws {
        let env = try await environmentWithSystem()
        let extras: () -> AnyView = { AnyView(EmptyView()) }
        let privacy = PrivacySettingsModel(environment: env)
        privacy.start()
        let splits = SplitSettingsModel(environment: env)
        splits.start()
        let notifications = NotificationsSettingsModel(environment: env)
        notifications.start()
        try await until("the privacy settings") { privacy.policy != nil }
        try await until("the splits") { !splits.splits.isEmpty }
        try await until("the notification switches") { !notifications.accounts.isEmpty && notifications.showsPermissionWarning }
        let importance = ImportanceSettingsModel(environment: env)
        importance.start()
        try await until("the importance rules") { importance.hasLoaded }
        let rules = try #require(env.importance)
        let account = try #require(importance.account)
        let sender = "someone.with.a.long.name@mail.example.com"
        for change in [ImportanceChange(kind: .neverDomain, account: account, value: "example-company.com"),
                       ImportanceChange(kind: .alwaysSender, account: account, value: sender),
                       ImportanceChange(kind: .label, account: account, value: "Clients/Partners and suppliers"),
                       ImportanceChange(kind: .keyword, account: account, value: "quarterly board meeting"),
                       ImportanceChange(kind: .notPitch, account: account, value: sender)] {
            _ = try await rules.apply(change)
        }
        try await until("the importance list") { importance.rules.count == 5 }
        importance.beginAdd(.keyword)
        importance.draft?.value = "invoice"
        let themes = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: .system)))
        let pages: [(String, AnyView)] = [
            ("general", AnyView(GeneralSettingsPage(environment: env, extras: { AnyView(SystemGeneralSettingsView(environment: env)) }))),
            ("accounts", AnyView(AccountsSettingsPage(environment: env))),
            ("notifications", AnyView(NotificationsSettingsView(model: notifications))),
            ("splits", AnyView(SplitSettingsPage(model: splits))),
            ("shortcuts", AnyView(ShortcutsSettingsPage(environment: env, printText: { _ in }))),
            ("snippets", AnyView(SnippetSettingsPage(environment: env))),
            ("privacy", AnyView(PrivacySettingsPage(model: privacy))),
            ("ai", AnyView(AISettingsPage(environment: env, providers: nil))),
            ("advanced", AnyView(AdvancedSettingsPage(environment: env, extras: extras))),
            ("platform", AnyView(PlatformFeaturesPage(environment: env))),
            ("calendar", AnyView(CalendarSettingsPage(environment: env))),
            ("appearance", AnyView(AppearanceSettingsView(store: themes, fontFamilies: ["Inter"]))),
            ("importance", AnyView(ImportanceSettingsPage(model: importance))),
        ]
        for (page, view) in pages {
            let stage = Stage(view, width: pageWidth, height: 2400, theme: theme)
            defer { stage.close() }
            let shot = try stage.render("settings-page-\(page)-\(name)")
            let strays = stage.strays(in: Self.margin, of: shot, color: stage.background(of: shot))
            #expect(strays.isEmpty, "\(page) (\(name)) draws in the right margin at \(strays.prefix(3))")
        }
    }

    @Test func theMarginCheckSeesARowThatRunsOver() throws {
        let page = SettingsPageScaffold(title: "Too wide") {
            // Stacked, so the control is leading-aligned and runs out to the right; beside the title the form's
            // trailing alignment would push the overrun under the title instead
            SettingsSection { SettingsRow("Wide", stacked: true) { Color.red.frame(width: pageWidth, height: 20) } }
        }
        let stage = Stage(page, width: pageWidth, height: 400, theme: .light)
        defer { stage.close() }
        let shot = try stage.render("settings-page-too-wide")
        #expect(!stage.strays(in: Self.margin, of: shot, color: stage.background(of: shot)).isEmpty)
    }

    @Test(arguments: [("light", ResolvedTheme.light), ("dark", ResolvedTheme.dark)])
    func thePromptsTabStaysInsideThePage(_ name: String, _ theme: ResolvedTheme) async throws {
        let registry = PromptRegistry(provider: PromptLibraryProvider(bundled: .standard),
                                      store: InMemoryPromptOverrideStore(), now: { fixedNow })
        try await registry.save("autolabel.classify", body: "Pick the one category that fits this conversation best.",
                                note: "plainer wording")
        let model = PromptsSettingsModel(registry: registry)
        await model.load()
        func check(_ shot: String) throws {
            let page = SettingsPageScaffold(title: "AI") {
                AISettingsTabs(prompts: model, initialTab: .prompts) { EmptyView() }
            }
            let stage = Stage(page, width: pageWidth, height: 2400, theme: theme)
            defer { stage.close() }
            let rendered = try stage.render("settings-ai-prompts-\(shot)-\(name)")
            let strays = stage.strays(in: Self.margin, of: rendered, color: stage.background(of: rendered))
            #expect(strays.isEmpty, "prompts \(shot) (\(name)) draws in the right margin at \(strays.prefix(3))")
        }
        try check("list")
        await model.select("autolabel.classify")
        model.draft = "Pick the category."
        #expect(model.check.warnings == [.noJSONForm])
        for tab in PromptsSettingsModel.EditorTab.allCases {
            model.tab = tab
            try check("editor-\(tab.rawValue)")
        }
    }

    /// The AI page with its models and every feature row, at the smallest window and wider: no row reaches past the
    /// page's margin and nothing scrolls sideways.
    @Test(arguments: [("light", ResolvedTheme.light), ("dark", ResolvedTheme.dark)])
    func theAIPageStaysInsideItsPane(_ name: String, _ theme: ResolvedTheme) throws {
        let center = AICenter.make(registry: ProviderRegistry(providers: [FakeAIProvider(displayName: "On-device test model")]),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore()))
        let env = AppEnvironment.fake(corpus: .rich(threadCount: 20, now: fixedNow), options: .init(remoteAck: .immediate),
                                      featureFlags: FeatureFlags(), ai: center)
        for width in [pageWidth, pageWidth + 240] {
            let page = SettingsPageScaffold(title: "AI") {
                AISettingsTabs(prompts: nil) {
                    SettingsSectionStack {
                        AISettingsSection(center: center, environment: env, listsUnavailableModels: false)
                        ClassifierSettingsSection(center: center, port: nil, environment: env)
                    }
                }
            }
            let stage = Stage(page, width: width, height: 2400, theme: theme)
            defer { stage.close() }
            let shot = try stage.render("settings-ai-page-\(Int(width))-\(name)")
            let margin = (width - 12)...(width - 5)
            let strays = stage.strays(in: margin, of: shot, color: stage.background(of: shot))
            #expect(strays.isEmpty, "the AI page (\(name), \(width) pt) draws in the right margin at \(strays.prefix(3))")
            let root = try #require(stage.window.contentView)
            for scroll in Self.scrollViews(in: root) {
                guard let document = scroll.documentView else { continue }
                let shown = scroll.contentView.bounds.width
                #expect(document.frame.width <= shown + 0.5,
                        "the page is no wider than its pane (\(document.frame.width) of \(shown), \(name), \(width) pt)")
            }
        }
    }

    @Test func theSplitListShowsEveryRowWithoutScrollingInsideThePage() async throws {
        let splits = SplitSettingsModel(environment: environment())
        splits.start()
        try await until("the splits") { !splits.splits.isEmpty }
        let stage = Stage(SplitSettingsPage(model: splits), width: pageWidth, height: 1200, theme: .light)
        defer { stage.close() }
        _ = try stage.render("settings-splits-list")
        let root = try #require(stage.window.contentView)
        let table = try #require(Self.tables(in: root).last, "the split list is a table (inside the page's form)")
        let scroll = try #require(table.enclosingScrollView)
        let shown = scroll.contentView.bounds.height
        let rows = table.numberOfRows
        #expect(rows == splits.splits.count + 1, "every split and Other")
        let content = table.rect(ofRow: rows - 1).maxY
        #expect(content <= shown + 0.5, "the last row is inside the list (\(content) of \(shown))")
        #expect(shown - content < SplitSettingsPage.listRowHeight, "no empty row's worth of space under the list")
    }

    /// The strip between a grouped form's sections and the page's right edge.
    static let margin: ClosedRange<CGFloat> = (pageWidth - 12)...(pageWidth - 5)

    private static func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
    }

    private static func splitViews(in view: NSView) -> [NSSplitView] {
        ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splitViews)
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    private static func inside(_ size: CGSize) -> NSRect {
        NSRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
    }
}
#endif
