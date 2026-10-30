import MailFeatures
import MailTheme
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

enum OverlayMetrics {
    static let paletteListMaxHeight: CGFloat = 420
    static let windowMargin: CGFloat = 96
    static let rowIconSize: CGFloat = 16
    static let rowIconX: CGFloat = 16
    static let cursorInset: CGFloat = 4
    static let labelPickerWidth: CGFloat = 400
    static let timePickerWidth: CGFloat = 420
    static let shortcutHelpWidth: CGFloat = 880
    static let paletteTop: CGFloat = 96
    static let paletteTopRatio: CGFloat = 0.22
    static let pickerTop: CGFloat = 120
    static let pickerInputHeight: CGFloat = 52
    static let footerHeight: CGFloat = 32

    /// Content starts this far from the panel's edge: the field, headers, row text and the footer line up.
    static let panelInsetX: CGFloat = 16
    static let plateInsetX: CGFloat = 6
    static let rowPaddingX: CGFloat = panelInsetX - plateInsetX
    static let plateRadius: CGFloat = 8
    static let rowHeight: CGFloat = 32
    static let paletteRowHeight: CGFloat = NativeMetrics.Overlay.paletteRowHeight
    static let headerHeight: CGFloat = 28
    static let sectionHeaderHeight: CGFloat = 26
    static let sectionHeaderBottom: CGFloat = 4
    static let listPaddingY: CGFloat = 6
    static let symbolColumn: CGFloat = 24
    static let rowSymbolSize: CGFloat = 14
    static let rowSpacing: CGFloat = 8
    static let fieldSpacing: CGFloat = 8
    static let scopeMaxWidth: CGFloat = 220
    static let footerSpacing: CGFloat = 14
    static let footerKeyGap: CGFloat = 4
    static let footerPaddingY: CGFloat = 8
    static let hintColumn: CGFloat = 20
    static let labelDotSize: CGFloat = 8
    static let timeFieldWidth: CGFloat = 96
    static let materialShadowOpacity: Double = 0.18
    static let materialShadowRadius: CGFloat = 18
    static let materialShadowY: CGFloat = 8

    #if canImport(AppKit)
    @MainActor private static var fieldLineHeights: [TypeStyle: CGFloat] = [:]

    @MainActor static func fieldLineHeight(_ style: TypeStyle) -> CGFloat {
        if let height = fieldLineHeights[style] { return height }
        let field = NSTextField(string: "Ag")
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.font = style.fieldFont
        let height = ceil(field.intrinsicContentSize.height)
        fieldLineHeights[style] = height
        return height
    }
    #endif
}

#if canImport(AppKit)
private extension TypeStyle {
    var fieldFont: NSFont {
        let weight: NSFont.Weight = switch swiftUIWeight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        let design: NSFontDescriptor.SystemDesign? = switch family {
        case .system, .named: nil
        case .systemSerif: .serif
        case .systemRounded: .rounded
        case .systemMono: .monospaced
        }
        if case .named(let name) = family { return NSFont(name: name, size: size) ?? system }
        if let design, let descriptor = system.fontDescriptor.withDesign(design),
           let designed = NSFont(descriptor: descriptor, size: size) {
            return designed
        }
        return system
    }
}
#endif

extension View {
    @MainActor func overlayInputLine(_ style: TypeStyle) -> some View {
        #if canImport(AppKit)
        frame(height: OverlayMetrics.fieldLineHeight(style))
        #else
        fixedSize(horizontal: false, vertical: true)
        #endif
    }
}

extension EnvironmentValues {
    @Entry var overlaySheet: Bool = false
}

@MainActor
enum OverlaySheet {
    private static var twins: [String: ResolvedTheme] = [:]

    static func theme(for theme: ResolvedTheme) -> ResolvedTheme {
        guard theme.appearance != .dark else { return theme }
        let key = "\(theme.accentID)|\(theme.tokens.density)|\(theme.tokens.reduceMotion)"
        if let twin = twins[key] { return twin }
        let resolved = ThemeLibrary.builtIn.resolve(themeID: BuiltinThemeID.dark, appearance: .dark,
                                                    preferences: ThemePreferences(accentID: theme.accentID,
                                                                                  density: theme.tokens.density))
        var tokens = resolved.tokens
        tokens.reduceMotion = theme.tokens.reduceMotion
        let twin = ResolvedTheme(themeID: resolved.themeID, themeName: resolved.themeName, accentID: resolved.accentID,
                                 appearance: .dark, tokens: tokens, emailColors: resolved.emailColors, issues: resolved.issues)
        twins[key] = twin
        return twin
    }
}

/// A keycap beside a row or field that already names its action, so it is hidden from accessibility. It draws as
/// `NativeKeycap`.
struct KeycapView: View {
    let text: String

    var body: some View {
        NativeKeycap(text)
            .accessibilityHidden(true)
    }
}

struct KeycapRow: View {
    let keycaps: [String]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: keycaps.count > 1 ? 6 : 2) {
            ForEach(Array(keycaps.enumerated()), id: \.offset) { _, cap in KeycapView(text: cap) }
        }
    }
}

struct CursorRowBackground: View {
    let isCursor: Bool
    @Environment(\.theme) private var theme
    @Environment(\.overlaySheet) private var onSheet

    var body: some View {
        if isCursor, onSheet {
            let palette = theme.component.palette
            RoundedRectangle(cornerRadius: palette.cursorInset > 0 ? theme.radiusMD : 0)
                .fill(palette.band.color)
                .padding(.horizontal, palette.cursorInset)
        } else if isCursor {
            RoundedRectangle(cornerRadius: theme.radiusMD)
                .fill(theme.bgRowSelected.color)
                .overlay(alignment: .leading) {
                    Capsule().fill(theme.component.row.cursorBar.color).frame(width: theme.component.row.cursorBarWidth)
                        .padding(.vertical, 6)
                }
                .padding(.horizontal, OverlayMetrics.cursorInset)
        }
    }
}

extension View {
    func overlayKeys(up: @escaping () -> Void, down: @escaping () -> Void, escape: @escaping () -> Void) -> some View {
        onKeyPress(.upArrow) { up(); return .handled }
            .onKeyPress(.downArrow) { down(); return .handled }
            .onKeyPress(.escape) { escape(); return .handled }
    }
}
