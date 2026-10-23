import MailFeatures
import MailModel
import MailTheme
import SwiftUI

public struct SettingsHosting {
    public var appearance: () -> AnyView
    public var notifications: () -> AnyView
    public var generalExtras: () -> AnyView
    public var advancedExtras: () -> AnyView
    public var aiProviders: (() -> AnyView)?
    public var modulePage: (String) -> AnyView?
    public var printText: (String) -> Void
    public var showsDeveloperItems: Bool
    public var offersDeveloperSettings: Bool
    public var build: BuildLabel?

    public init(appearance: @escaping () -> AnyView = { AnyView(EmptyView()) },
                notifications: @escaping () -> AnyView = { AnyView(EmptyView()) },
                generalExtras: @escaping () -> AnyView = { AnyView(EmptyView()) },
                advancedExtras: @escaping () -> AnyView = { AnyView(EmptyView()) },
                aiProviders: (() -> AnyView)? = nil, modulePage: @escaping (String) -> AnyView? = { _ in nil },
                printText: @escaping (String) -> Void = { _ in }, showsDeveloperItems: Bool = false,
                offersDeveloperSettings: Bool = false, build: BuildLabel? = nil) {
        self.appearance = appearance
        self.notifications = notifications
        self.generalExtras = generalExtras
        self.advancedExtras = advancedExtras
        self.aiProviders = aiProviders
        self.modulePage = modulePage
        self.printText = printText
        self.showsDeveloperItems = showsDeveloperItems
        self.offersDeveloperSettings = offersDeveloperSettings
        self.build = build
    }
}

public struct SettingsShellView: View {
    @State private var shell: SettingsShellModel
    let environment: AppEnvironment?
    let hosting: SettingsHosting

    public init(environment: AppEnvironment, hosting: SettingsHosting, defaults: UserDefaults = .standard) {
        self.environment = environment
        self.hosting = hosting
        _shell = State(initialValue: SettingsShellModel(environment: environment, defaults: defaults))
    }

    public init(standaloneHosting hosting: SettingsHosting) {
        environment = nil
        self.hosting = hosting
        let model = SettingsShellModel.standalone()
        model.selected = SettingsPageID.appearance.rawValue
        _shell = State(initialValue: model)
    }

    private var pages: [SettingsPageEntry] {
        environment == nil
            ? Self.standalonePages(shell.pages, showsAdvanced: hosting.showsDeveloperItems || hosting.offersDeveloperSettings)
            : shell.pages
    }

    static func standalonePages(_ pages: [SettingsPageEntry], showsAdvanced: Bool = true) -> [SettingsPageEntry] {
        pages.filter { $0.builtIn == .appearance || (showsAdvanced && $0.builtIn == .advanced) }
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            // Why: the split view grows to its columns' minimum heights, so a column without a bound (the footer's
            // text measured a word per line) pushed the list past the window's edge, out of reach of scrolling
            SettingsSidebar(pages: pages, selection: $shell.selected, build: hosting.build)
                .frame(minWidth: SettingsMetrics.sidebarWidth, idealWidth: SettingsMetrics.sidebarWidth)
                .frame(minHeight: 0, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: SettingsMetrics.sidebarWidth, ideal: SettingsMetrics.sidebarWidth,
                                                max: SettingsMetrics.sidebarMaxWidth)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            page
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle(shell.selectedEntry?.title ?? "Settings")
        .onAppear { followRequest() }
        .onChange(of: environment?.settingsNavigator.requestedPage) { followRequest() }
    }

    private func followRequest() {
        guard let navigator = environment?.settingsNavigator else { return }
        shell.takeRequest(from: navigator)
    }

    @ViewBuilder
    private var page: some View {
        if let entry = shell.selectedEntry {
            if let builtIn = entry.builtIn {
                builtInPage(builtIn)
            } else if let hosted = hosting.modulePage(entry.id) {
                hosted
            } else if entry.id == ImportanceSettingsModel.pageID, let environment {
                ImportanceSettingsPage(environment: environment)
            } else if entry.id == BlockedSettingsModel.pageID, let environment {
                BlockedSettingsPage(environment: environment)
            } else {
                SettingsPageScaffold(title: entry.title) {
                    SettingsFootnote("Nothing to set on this page yet.")
                }
            }
        }
    }

    @ViewBuilder
    private func builtInPage(_ page: SettingsPageID) -> some View {
        if let environment {
            builtInPage(page, environment: environment)
        } else if page == .appearance {
            hosting.appearance()
        } else {
            SettingsPageScaffold(title: page.title) {
                hosting.advancedExtras()
            }
        }
    }

    @ViewBuilder
    private func builtInPage(_ page: SettingsPageID, environment: AppEnvironment) -> some View {
        switch page {
        case .general: GeneralSettingsPage(environment: environment, extras: hosting.generalExtras)
        case .accounts: AccountsSettingsPage(environment: environment)
        case .appearance: hosting.appearance()
        case .splitInbox: SplitSettingsPage(environment: environment)
        case .sidebar: SidebarSettingsPage(environment: environment)
        case .shortcuts: ShortcutsSettingsPage(environment: environment, printText: hosting.printText)
        case .snippets: SnippetSettingsPage(environment: environment)
        case .search: SearchSettingsPage(environment: environment)
        case .ai: AISettingsPage(environment: environment, providers: hosting.aiProviders)
        case .notifications: hosting.notifications()
        case .calendar: CalendarSettingsPage(environment: environment)
        case .privacy: PrivacySettingsPage(environment: environment)
        case .advanced: AdvancedSettingsPage(environment: environment, extras: hosting.advancedExtras,
                                             showsDeveloperItems: hosting.showsDeveloperItems)
        case .platform: PlatformFeaturesPage(environment: environment, showsDeveloperItems: hosting.showsDeveloperItems)
        }
    }
}

struct SettingsSidebar: View {
    let pages: [SettingsPageEntry]
    @Binding var selection: String
    var build: BuildLabel?
    @FocusState private var focused: Bool

    var body: some View {
        List(selection: Binding<String?>(get: { selection }, set: { id in if let id { selection = id } })) {
            ForEach(pages) { entry in
                SettingsSidebarRow(entry: entry).tag(Optional(entry.id))
            }
        }
        .listStyle(.sidebar)
        .focused($focused)
        .onAppear { focused = true }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let build { SettingsBuildFooter(build: build) }
        }
        .accessibilityLabel("Settings pages")
    }
}

struct SettingsBuildFooter: View {
    let build: BuildLabel
    @Environment(\.theme) private var theme

    static func lines(_ build: BuildLabel) -> [String] {
        [build.versionLine] + (build.notice.map { [$0] } ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space1) {
            ForEach(Self.lines(build), id: \.self) { Text($0) }
        }
        .font(.system(size: NativeMetrics.Text.caption))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, theme.space6)
        .padding(.vertical, theme.space5)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.buildNotice")
    }
}

struct SettingsSidebarRow: View {
    let entry: SettingsPageEntry

    var body: some View {
        Label(entry.title, systemImage: entry.symbol)
            .lineLimit(1)
            .accessibilityIdentifier("settings.page.\(entry.id)")
    }
}
