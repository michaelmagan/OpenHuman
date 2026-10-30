import MailTheme
import SwiftUI
import UniformTypeIdentifiers

public struct AppearanceSettingsView: View {
    @Bindable var store: ThemeStore
    let fontFamilies: [String]
    let onRevealFolder: (() -> Void)?
    let extraRows: (() -> AnyView)?
    @State private var thumbnails = ThemeThumbnailCache()
    @State private var importing = false
    @State private var exporting = false
    @State private var exportName = ""
    @State private var message: String?
    @Environment(\.theme) private var theme

    public init(store: ThemeStore, fontFamilies: [String] = [], onRevealFolder: (() -> Void)? = nil,
                extraRows: (() -> AnyView)? = nil) {
        self.store = store
        self.fontFamilies = fontFamilies
        self.onRevealFolder = onRevealFolder
        self.extraRows = extraRows
    }

    private var selectable: [ThemeSummary] { store.available.filter(\.isSelectable) }
    private var lightThemes: [ThemeSummary] { selectable.filter { $0.appearance != .dark } }
    private var darkThemes: [ThemeSummary] { selectable.filter { $0.appearance != .light } }
    private var problemFiles: [ThemeSummary] { store.available.filter { !$0.isBuiltIn && (!$0.isUsable || !$0.issues.isEmpty) } }

    public var body: some View {
        SettingsPageScaffold(title: "Appearance") {
            SettingsSection(footnote: Self.chromeNote) {
                modeRow
                accentRow
            }
            SettingsSection("Mail theme", footnote: Self.themeNote) {
                SettingsRow("Theme when light", selection: $store.preferences.lightThemeID) {
                    ForEach(lightThemes) { Text($0.name).tag($0.id) }
                }
                SettingsRow("Theme when dark", selection: $store.preferences.darkThemeID) {
                    ForEach(darkThemes) { Text($0.name).tag($0.id) }
                }
                gallery.settingsRowPadding()
            }
            SettingsSection("Preview") {
                previews.settingsRowPadding()
            }
            SettingsSection("Density and text") {
                densityRow
                readerSizeRow
                emailColorsRow
                SettingsRow("UI font", selection: $store.preferences.uiFont) {
                    fontOptions(systemAlternative: .systemRounded, altName: "System Rounded")
                }
                SettingsRow("Reader font", selection: $store.preferences.readerFont) {
                    fontOptions(systemAlternative: .systemSerif, altName: "New York")
                }
            }
            if let extraRows {
                SettingsSection { extraRows() }
            }
            SettingsSection("Theme files", footnote: message) {
                folderRows
            }
            if !issueLines.isEmpty {
                Section { issuesList }
            }
        }
        .tint(theme.controlTint)
        .transaction { $0.animation = nil }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            Task { await importTheme(url) }
        }
        .alert("Export as Theme", isPresented: $exporting) {
            TextField("Name", text: $exportName)
            Button("Export") { Task { await exportTheme() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves your accent, fonts, reader size and email colors as a theme that builds on \(store.resolved.themeName).")
        }
    }

    static let chromeNote = "The window, sidebar and toolbar follow macOS. The accent colours selections, buttons and "
        + "switches; System follows the accent in System Settings."
    static let themeNote = "The theme colours the mail itself: the list, the reader and the composer."

    private var modeRow: some View {
        SettingsRow("Appearance", labelsControl: true) {
            Picker("Appearance", selection: $store.preferences.mode) {
                Text("System").tag(AppearanceMode.system)
                Text("Light").tag(AppearanceMode.light)
                Text("Dark").tag(AppearanceMode.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
        }
    }

    private var gallery: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 168), spacing: theme.space4, alignment: .top)],
                  alignment: .leading, spacing: theme.space4) {
            ForEach(selectable) { summary in
                card(summary)
            }
        }
    }

    private func card(_ summary: ThemeSummary) -> some View {
        let appearance: ThemeAppearance = summary.appearance == .dark ? .dark : .light
        var prefs = store.preferences
        if appearance == .dark { prefs.darkThemeID = summary.id } else { prefs.lightThemeID = summary.id }
        let candidate = store.resolve(prefs, appearance: appearance)
        let isSelected = (appearance == .dark ? store.preferences.darkThemeID : store.preferences.lightThemeID) == summary.id
        return Button {
            if appearance == .dark { store.preferences.darkThemeID = summary.id } else { store.preferences.lightThemeID = summary.id }
        } label: {
            VStack(alignment: .leading, spacing: theme.space2) {
                Group {
                    if let image = thumbnails.thumbnail(for: candidate) {
                        Image(decorative: image, scale: 2)
                    } else {
                        ThemePreviewView(theme: candidate, scale: thumbnails.scale)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusLG))
                .overlay(RoundedRectangle(cornerRadius: theme.radiusLG).stroke(theme.borderHairline.color, lineWidth: theme.borderWidthHairline))
                .overlay(RoundedRectangle(cornerRadius: theme.radiusLG + theme.borderWidthFocusOffset)
                    .stroke(isSelected ? theme.accentRing.color : .clear, lineWidth: theme.borderWidthFocus)
                    .padding(-theme.borderWidthFocusOffset))
                HStack(spacing: theme.space1) {
                    Text(summary.name).font(.system(size: NativeMetrics.Text.secondary, weight: .medium))
                    if isSelected {
                        Image(systemName: "checkmark").font(.system(size: NativeMetrics.Text.caption, weight: .semibold))
                            .foregroundStyle(.tint)
                    }
                    if !summary.issues.isEmpty {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: NativeMetrics.Text.caption))
                            .foregroundStyle(theme.textWarning.color)
                            .help(summary.issueLines.joined(separator: "\n"))
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(summary.name) theme")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var previews: some View {
        let both = store.preferences.mode == .system
        let scale: CGFloat = both ? 0.56 : 0.8
        return HStack(spacing: theme.space4) {
            if store.preferences.mode != .dark {
                ThemePreviewView(theme: store.resolve(store.preferences, appearance: .light), scale: scale)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusLG))
            }
            if store.preferences.mode != .light {
                ThemePreviewView(theme: store.resolve(store.preferences, appearance: .dark), scale: scale)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusLG))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(both ? "Preview of the light and dark themes" : "Preview of the theme")
    }

    private var accentRow: some View {
        SettingsRow("Accent") {
            HStack(spacing: theme.space3) {
                ForEach(store.library.accentIDs, id: \.self) { id in
                    let accentTheme = store.resolve(ThemePreferences(lightThemeID: store.resolved.themeID,
                                                                     darkThemeID: store.resolved.themeID, accentID: id),
                                                    appearance: store.resolved.appearance)
                    let isSelected = store.resolved.accentID == id
                    let name = Self.accentName(id)
                    Button { store.preferences.accentID = id } label: {
                        HStack(spacing: theme.space2) {
                            Circle().fill(accentTheme.accentFill.color).frame(width: 24, height: 24)
                                .overlay(Circle().stroke(isSelected ? theme.accentRing.color : .clear, lineWidth: theme.borderWidthFocus)
                                    .padding(-theme.borderWidthFocusOffset))
                            Text(name)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(name) accent")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private var densityRow: some View {
        SettingsRow("Density", detail: "Rows, message cards and the footer tighten or open up together.",
                    labelsControl: true) {
            Picker("Density", selection: $store.preferences.density) {
                Text("Compact").tag(ThemeDensity.compact)
                Text("Default").tag(ThemeDensity.default)
                Text("Comfortable").tag(ThemeDensity.comfortable)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 300)
        }
    }

    private var readerSizeRow: some View {
        SettingsRow("Reader text") {
            HStack(spacing: theme.space3) {
                Text("A").font(.system(size: 11)).accessibilityHidden(true)
                Slider(value: Binding(get: { store.resolved.typeReader.size },
                                      set: { store.preferences.readerTextSize = $0.rounded() }),
                       in: ThemePreferences.readerTextSizeRange, step: 1)
                    .frame(width: 160)
                    .accessibilityLabel("Reader text size")
                    .accessibilityValue("\(Int(store.resolved.typeReader.size)) points")
                Text("A").font(.system(size: 17)).accessibilityHidden(true)
                Text("\(Int(store.resolved.typeReader.size)) pt").font(.system(size: NativeMetrics.Text.secondary))
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var emailColorsRow: some View {
        SettingsRow("Email colors", selection: Binding(get: { store.resolved.emailColors },
                                                       set: { store.preferences.emailColors = $0 })) {
            Text("Adapt when safe").tag(EmailColors.adaptWhenSafe)
            Text("Always original").tag(EmailColors.alwaysOriginal)
            Text("Always adapt").tag(EmailColors.alwaysAdapt)
        }
    }

    @ViewBuilder
    private func fontOptions(systemAlternative: FontFamily, altName: String) -> some View {
        Text("System").tag(FontFamily?.none)
        Text(altName).tag(Optional(systemAlternative))
        ForEach(fontFamilies.filter(FontFamily.isValidName), id: \.self) { Text($0).tag(Optional(FontFamily.named($0))) }
    }

    @ViewBuilder
    private var folderRows: some View {
        SettingsRow("Themes folder", detail: "Theme files you import or export are kept here.") {
            HStack(spacing: theme.space3) {
                if let onRevealFolder { Button("Open Folder", action: onRevealFolder) }
                Button("Reload") { Task { await store.reloadThemes() } }.disabled(store.folder == nil)
            }
        }
        SettingsRow("Import or export a theme") {
            HStack(spacing: theme.space3) {
                Button("Import Theme…") { importing = true }.disabled(store.folder == nil)
                Button("Export as Theme…") {
                    exportName = "My \(store.resolved.themeName)"
                    exporting = true
                }
                .disabled(store.folder == nil)
            }
        }
        SettingsRow("Reset", detail: "Puts every choice on this page back to its default.") {
            Button("Reset") { store.resetPreferences() }
        }
    }

    static func accentName(_ id: String) -> String {
        id.prefix(1).uppercased() + id.dropFirst()
    }

    private struct IssueLine: Hashable {
        let text: String
        let isProblem: Bool
    }

    private var issueLines: [IssueLine] {
        store.notices.filter { $0.code != .contrast }.map { IssueLine(text: $0.description, isProblem: false) }
            + problemFiles.flatMap { summary in summary.issueLines.map { IssueLine(text: $0, isProblem: !summary.isUsable) } }
    }

    private var issuesList: some View {
        VStack(alignment: .leading, spacing: theme.space1) {
            ForEach(issueLines, id: \.self) { line in
                Text(line.text)
                    .font(.system(size: NativeMetrics.Text.secondary).monospaced())
                    .foregroundStyle((line.isProblem ? theme.textDanger : theme.textWarning).color)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func importTheme(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let summary = try await store.importTheme(from: url)
            message = "Imported \(summary.name)."
        } catch ThemeFileError.refused(let issues) {
            message = "\(url.lastPathComponent) was not imported: " + issues.filter { $0.severity == .refused }.map(\.description).joined(separator: "; ")
        } catch {
            message = "\(url.lastPathComponent) could not be imported."
        }
    }

    private func exportTheme() async {
        let name = exportName.trimmingCharacters(in: .whitespaces)
        do {
            let url = try await store.exportCustomizations(named: name.isEmpty ? "Custom" : name)
            message = "Saved \(url.lastPathComponent) in the themes folder."
        } catch {
            message = "The theme could not be saved."
        }
    }
}
