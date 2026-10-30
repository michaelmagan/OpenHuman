import Foundation

public enum ThemeSource: Sendable, Hashable {
    case builtIn(String)
    case user(URL)

    public var url: URL? { if case .user(let url) = self { url } else { nil } }
    public var fileName: String {
        switch self {
        case .builtIn(let name): name
        case .user(let url): url.lastPathComponent
        }
    }
}

public struct ThemeSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let author: String?
    public let kind: ThemeFile.Kind
    public let appearance: ThemeFile.Appearance
    public let source: ThemeSource
    public let issues: [ThemeIssue]
    public let isLoaded: Bool

    public init(id: String, name: String, author: String?, kind: ThemeFile.Kind, appearance: ThemeFile.Appearance,
                source: ThemeSource, issues: [ThemeIssue], isLoaded: Bool) {
        self.id = id
        self.name = name
        self.author = author
        self.kind = kind
        self.appearance = appearance
        self.source = source
        self.issues = issues
        self.isLoaded = isLoaded
    }

    public var isBuiltIn: Bool { if case .builtIn = source { true } else { false } }
    public var isUsable: Bool { isLoaded && !issues.isRefused }
    public var isSelectable: Bool { isUsable && kind == .theme && id != BuiltinThemeID.base }
    public var accentShortID: String? { kind == .accent ? id.split(separator: ".").last.map(String.init) : nil }

    public var issueLines: [String] { issues.map { "\(source.fileName): \($0.description)" } }
}

public struct ThemeLibrary: Sendable {
    struct Loaded: Sendable {
        let file: ThemeFile?
        let source: ThemeSource
        let fileIssues: [ThemeIssue]
        var derivedIssues: [ThemeIssue] = []

        var issues: [ThemeIssue] { fileIssues + derivedIssues }
        var isUsable: Bool { file != nil && !issues.isRefused }
    }

    public let registry: TokenRegistry
    private(set) var themes: [String: Loaded] = [:]
    private(set) var accents: [String: Loaded] = [:]
    private(set) var unloaded: [String: Loaded] = [:]

    static func key(_ source: ThemeSource) -> String {
        switch source {
        case .builtIn(let name): "builtin:" + name
        case .user(let url): url.standardizedFileURL.path
        }
    }

    public init(registry: TokenRegistry = .v1) {
        self.registry = registry
    }

    public static let builtIn: ThemeLibrary = {
        var library = builtInFiles()
        library.audit()
        return library
    }()

    static func builtInFiles() -> ThemeLibrary {
        var library = ThemeLibrary(registry: .v1)
        for (name, json) in BuiltinThemeSources.themes {
            let result = ThemeValidator.validate(data: Data(json.utf8), registry: library.registry, allowReservedIDs: true)
            library.insert(result, source: .builtIn(name))
        }
        return library
    }

    @discardableResult
    public mutating func add(data: Data, source: ThemeSource) -> ThemeSummary {
        add(ThemeValidator.validate(data: data, registry: registry), source: source)
    }

    @discardableResult
    public mutating func add(_ result: ValidationResult, source: ThemeSource) -> ThemeSummary {
        let key = insert(result, source: source)
        audit()
        return summary(forKey: key, source: source)
    }

    public mutating func replaceUserFiles(_ files: [(source: URL, result: ValidationResult)]) {
        themes = themes.filter { $0.value.source.url == nil }
        accents = accents.filter { $0.value.source.url == nil }
        unloaded = [:]
        for (url, result) in files.sorted(by: { $0.source.lastPathComponent < $1.source.lastPathComponent }) {
            insert(result, source: .user(url))
        }
        audit()
    }

    public mutating func remove(source url: URL) {
        themes = themes.filter { $0.value.source.url != url }
        accents = accents.filter { $0.value.source.url != url }
        unloaded = unloaded.filter { $0.value.source.url != url }
        audit()
    }

    @discardableResult
    private mutating func insert(_ result: ValidationResult, source: ThemeSource) -> String {
        guard let file = result.file else {
            unloaded[Self.key(source)] = Loaded(file: nil, source: source, fileIssues: result.issues)
            return "file:" + source.fileName
        }
        switch file.kind {
        case .theme:
            if let existing = themes[file.id] {
                var issues = result.issues
                issues.append(.refused(.duplicateID, "id", "\(existing.source.fileName) already uses the id \(file.id)"))
                unloaded[Self.key(source)] = Loaded(file: file, source: source, fileIssues: issues)
                return "file:" + source.fileName
            }
            themes[file.id] = Loaded(file: file, source: source, fileIssues: result.issues)
            return file.id
        case .accent:
            let short = file.accentShortID
            if let existing = accents[short] {
                var issues = result.issues
                issues.append(.warning(.accentShortIDConflict, "id",
                                       "\(existing.source.fileName) already provides the accent \(short); that one is used"))
                unloaded[Self.key(source)] = Loaded(file: file, source: source, fileIssues: issues)
                return "file:" + source.fileName
            }
            accents[short] = Loaded(file: file, source: source, fileIssues: result.issues)
            return file.id
        }
    }

    public var summaries: [ThemeSummary] {
        let order = [BuiltinThemeID.light, BuiltinThemeID.dark, BuiltinThemeID.paper, BuiltinThemeID.midnight,
                     BuiltinThemeID.systemLight, BuiltinThemeID.systemDark, BuiltinThemeID.base]
        let accentOrder = BuiltinThemeID.accents
        var all: [ThemeSummary] = []
        for (id, loaded) in themes { all.append(makeSummary(loaded, fallbackID: id, isLoaded: true)) }
        for (short, loaded) in accents { all.append(makeSummary(loaded, fallbackID: short, isLoaded: true)) }
        for loaded in unloaded.values {
            all.append(makeSummary(loaded, fallbackID: "file:" + loaded.source.fileName, isLoaded: false))
        }
        func rank(_ s: ThemeSummary) -> (Int, Int, String) {
            if s.isBuiltIn {
                if s.kind == .theme { return (0, order.firstIndex(of: s.id) ?? 99, s.id) }
                return (1, accentOrder.firstIndex(of: s.accentShortID ?? "") ?? 99, s.id)
            }
            return (s.kind == .theme ? 2 : 3, 0, s.name.lowercased() + s.source.fileName)
        }
        return all.sorted { rank($0) < rank($1) }
    }

    public func summary(id: String) -> ThemeSummary? { summaries.first { $0.id == id } }

    public var accentIDs: [String] {
        summaries.filter { $0.kind == .accent && $0.isUsable }.compactMap(\.accentShortID)
    }

    private func summary(forKey key: String, source: ThemeSource) -> ThemeSummary {
        summaries.first { $0.source == source } ?? ThemeSummary(id: key, name: source.fileName, author: nil, kind: .theme,
                                                                 appearance: .any, source: source, issues: [], isLoaded: false)
    }

    private func makeSummary(_ loaded: Loaded, fallbackID: String, isLoaded: Bool) -> ThemeSummary {
        ThemeSummary(id: loaded.file?.id ?? fallbackID, name: loaded.file?.name ?? loaded.source.fileName,
                     author: loaded.file?.author, kind: loaded.file?.kind ?? .theme,
                     appearance: loaded.file?.appearance ?? .any, source: loaded.source, issues: loaded.issues,
                     isLoaded: isLoaded && loaded.file != nil)
    }

    mutating func audit() {
        for (id, loaded) in themes {
            guard let file = loaded.file else { continue }
            var derived: [ThemeIssue] = []
            let (chain, chainIssues) = chain(for: file)
            derived += chainIssues
            if !derived.isRefused, id != BuiltinThemeID.base {
                let appearance: ThemeAppearance = file.appearance == .dark ? .dark : .light
                let accentID = chain.lazy.compactMap(\.defaultAccent).first ?? BuiltinThemeID.defaultAccent
                let accent = accents[accentID]?.file ?? accents[BuiltinThemeID.defaultAccent]?.file
                if accents[accentID] == nil {
                    derived.append(.warning(.unknownAccent, "defaultAccent", "accent \(accentID) is not installed; using \(BuiltinThemeID.defaultAccent)"))
                }
                let outcome = tokens(chain: chain, accent: accent, appearance: appearance, overrides: [:], typography: [:])
                derived += outcome.issues
                derived += ContrastLint.issues(for: outcome.tokens)
            }
            themes[id]?.derivedIssues = derived
        }
    }

    func chain(for file: ThemeFile) -> ([ThemeFile], [ThemeIssue]) {
        var chain = [file]
        var issues: [ThemeIssue] = []
        var current = file
        while let parentID = current.extends {
            if chain.contains(where: { $0.id == parentID }) {
                issues.append(.refused(.extendsCycle, "extends", "extends chain loops back to \(parentID)"))
                break
            }
            guard chain.count <= 3 else {
                issues.append(.refused(.extendsTooDeep, "extends", "extends chain is deeper than 3"))
                break
            }
            guard let parent = themes[parentID], let parentFile = parent.file else {
                issues.append(.warning(.unknownParent, "extends", "parent theme \(parentID) is not installed; missing tokens use the built-in values"))
                break
            }
            chain.append(parentFile)
            current = parentFile
        }
        return (chain, issues)
    }

    public func resolve(_ preferences: ThemePreferences, appearance effective: ThemeAppearance,
                        increaseContrast: Bool = false, liveAccent: LiveAccent? = nil) -> ResolvedTheme {
        resolve(themeID: preferences.themeID(for: effective), appearance: effective, preferences: preferences,
                increaseContrast: increaseContrast, liveAccent: liveAccent)
    }

    public func resolve(themeID requested: String, appearance effective: ThemeAppearance,
                        preferences: ThemePreferences = ThemePreferences(), increaseContrast: Bool = false,
                        liveAccent: LiveAccent? = nil) -> ResolvedTheme {
        var notes: [ThemeIssue] = []
        var themeID = requested
        if requested == BuiltinThemeID.base || !(themes[requested]?.isUsable ?? false) {
            themeID = effective == .dark ? BuiltinThemeID.dark : BuiltinThemeID.light
            notes.append(.warning(.themeUnavailable, "", "theme \(requested) is not available; using \(themeID == BuiltinThemeID.dark ? "Dark" : "Light")"))
        }
        guard let loaded = themes[themeID], let file = loaded.file else {
            let tokens = effective == .dark ? ThemeTokens.dark : ThemeTokens.light
            return ResolvedTheme(themeID: themeID, themeName: themeID, accentID: BuiltinThemeID.defaultAccent,
                                 appearance: effective, tokens: tokens, emailColors: preferences.emailColors, issues: notes)
        }
        let (chain, chainIssues) = chain(for: file)
        let appearance: ThemeAppearance = switch file.appearance {
        case .light: .light
        case .dark: .dark
        case .any: effective
        }
        var accentID = preferences.accentID ?? chain.lazy.compactMap(\.defaultAccent).first ?? BuiltinThemeID.defaultAccent
        if accents[accentID]?.file == nil {
            notes.append(.warning(.unknownAccent, "", "accent \(accentID) is not available; using \(BuiltinThemeID.defaultAccent)"))
            accentID = BuiltinThemeID.defaultAccent
        }
        var overrides: [String: TokenSource] = [:]
        var typography: [String: TypographySpec] = [:]
        if increaseContrast {
            overrides["semantic/color/border.hairline"] = .reference("border.control")
            overrides["semantic/color/text.tertiary"] = .reference("text.secondary")
            overrides["components/row/chipBg"] = .reference("text.disabled")
            overrides["components/row/chipText"] = .reference("text.primary")
            overrides["components/tab/count"] = .reference("text.secondary")
        }
        if let colors = preferences.emailColors { overrides["reader/emailColors"] = .value(.emailColors(colors)) }
        if let font = preferences.uiFont { overrides["typography/family/ui"] = .value(.fontFamily(font)) }
        if let font = preferences.readerFont { overrides["typography/family/reader"] = .value(.fontFamily(font)) }
        if let size = preferences.clampedReaderTextSize {
            typography["typography/styles/reader"] = TypographySpec(size: size, lineHeight: ThemePreferences.readerLineHeight(for: size))
        }
        var outcome = tokens(chain: chain, accent: accents[accentID]?.file, appearance: appearance,
                             overrides: overrides, typography: typography)
        if accentID == LiveAccent.accentID, let liveAccent {
            let surfaces = LiveAccent.Surfaces(window: outcome.tokens.bgWindow, selected: outcome.tokens.bgRowSelected,
                                               text: outcome.tokens.textPrimary)
            overrides.merge(liveAccent.overrides(for: appearance, on: surfaces)) { _, live in live }
            outcome = tokens(chain: chain, accent: accents[accentID]?.file, appearance: appearance,
                             overrides: overrides, typography: typography)
        }
        outcome.tokens.density = preferences.density
        outcome.tokens.increaseContrast = increaseContrast
        let issues = notes + loaded.fileIssues.warnings + chainIssues + outcome.issues + ContrastLint.issues(for: outcome.tokens)
        return ResolvedTheme(themeID: themeID, themeName: file.name, accentID: accentID, appearance: appearance,
                             tokens: outcome.tokens, emailColors: preferences.emailColors, issues: issues)
    }

    func completeTokens(themeID: String, accentID: String, appearance: ThemeAppearance) -> ThemeTokens? {
        guard let file = themes[themeID]?.file else { return nil }
        var resolver = ThemeResolver(registry: registry, chain: chain(for: file).0, accent: accents[accentID]?.file,
                                     accentMode: appearance)
        let (table, missing) = resolver.resolveTable()
        guard missing.isEmpty, resolver.issues.isEmpty, var tokens = ThemeTokens(table: table, density: .default) else { return nil }
        tokens.bakeFontFamilies()
        return tokens
    }

    func tokens(chain: [ThemeFile], accent: ThemeFile?, appearance: ThemeAppearance,
                overrides: [String: TokenSource], typography: [String: TypographySpec]) -> (tokens: ThemeTokens, issues: [ThemeIssue]) {
        var resolver = ThemeResolver(registry: registry, chain: chain, accent: accent, accentMode: appearance,
                                     overrides: overrides, typographyOverrides: typography)
        let (table, missing) = resolver.resolveTable()
        let fallback = appearance == .dark ? ThemeTokens.dark : ThemeTokens.light
        var issues = resolver.issues
        if !missing.isEmpty {
            let shown = missing.prefix(4).joined(separator: ", ") + (missing.count > 4 ? ", …" : "")
            issues.append(.warning(.missingToken, "", "\(missing.count) token(s) not defined (\(shown)); using the built-in \(appearance == .dark ? "Dark" : "Light") values"))
        }
        var tokens = ThemeTokens(table: table, fallback: fallback, density: .default)
        tokens.bakeFontFamilies()
        return (tokens, issues)
    }
}
