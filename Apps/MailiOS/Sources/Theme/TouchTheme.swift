import MailTheme
import MailUI
import SwiftUI
import UIKit

// Why: the type tokens carry the Mac's point sizes; the phone keeps their family and weight and takes sizes from Dynamic Type
struct TouchTheme: Sendable {
    let resolved: ResolvedTheme

    static let light = TouchTheme(resolved: .light)

    var tokens: ThemeTokens { resolved.tokens }
    var isDark: Bool { resolved.appearance == .dark }

    func font(_ style: TypeStyle, _ textStyle: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        let weight = weight ?? style.swiftUIWeight
        let font: Font = switch style.family {
        case .system: .system(textStyle, design: .default, weight: weight)
        case .systemSerif: .system(textStyle, design: .serif, weight: weight)
        case .systemRounded: .system(textStyle, design: .rounded, weight: weight)
        case .systemMono: .system(textStyle, design: .monospaced, weight: weight)
        case .named(let name): .custom(name, size: Self.baseSize(textStyle), relativeTo: textStyle).weight(weight)
        }
        return style.monospacedDigits ? font.monospacedDigit() : font
    }

    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
    }

    var sender: Font { font(tokens.typeBodyStrong, .body, weight: .medium) }
    var senderUnread: Font { font(tokens.typeBodyStrong, .body, weight: .semibold) }
    var subject: Font { font(tokens.typeBody, .subheadline) }
    var snippet: Font { font(tokens.typeMeta, .subheadline) }
    var date: Font { font(tokens.typeMeta, .footnote) }
    var chip: Font { font(tokens.typeCaption, .caption, weight: .medium) }
    var title: Font { font(tokens.typeTitle, .title2, weight: .bold) }
    var headline: Font { font(tokens.typeHeadline, .headline) }
    var body: Font { font(tokens.typeBody, .body) }
    var bodyStrong: Font { font(tokens.typeBodyStrong, .body, weight: .semibold) }
    var tab: Font { font(tokens.typeTab, .subheadline) }
    var tabActive: Font { font(tokens.typeTabActive, .subheadline, weight: .semibold) }
    var tabCount: Font { font(tokens.typeTabCount, .footnote) }
    var caption: Font { font(tokens.typeCaption, .caption) }
    var badge: Font { font(tokens.typeLabel, .caption2, weight: .bold) }
    var icon: Font { .system(.title3, weight: .medium) }
    var smallIcon: Font { .system(.body, weight: .medium) }

    var window: Color { tokens.bgWindow.color }
    var sunken: Color { tokens.bgSunken.color }
    var elevated: Color { tokens.bgElevated.color }
    var card: Color { tokens.component.thread.cardBg.color }
    var selected: Color { tokens.bgRowSelected.color }
    var hairline: Color { tokens.borderHairline.color }
    var elevatedBorder: Color { tokens.borderElevated.color }
    var textPrimary: Color { tokens.textPrimary.color }
    var textSecondary: Color { tokens.textSecondary.color }
    var textTertiary: Color { tokens.textTertiary.color }
    var textSuccess: Color { tokens.textSuccess.color }
    var textWarning: Color { tokens.textWarning.color }
    var textDanger: Color { tokens.textDanger.color }
    var textAI: Color { tokens.textAI.color }
    var textLink: Color { tokens.textLink.color }
    var accent: Color { tokens.accentFill.color }
    var accentSubtle: Color { tokens.accentSubtle.color }
    var onAccent: Color { tokens.accentOnFill.color }
    var unreadDot: Color { tokens.component.row.unreadDot.color }
    var swipeDone: Color { tokens.component.swipe.done.color }
    var swipeSnooze: Color { tokens.component.swipe.snooze.color }
    var swipeText: Color { tokens.component.swipe.text.color }
    var toastBackground: Color { tokens.component.toast.bg.color }
    var toastText: Color { tokens.component.toast.text.color }
    var toastAction: Color { tokens.component.toast.textSecondary.color }
    var toastDanger: Color { tokens.component.toast.danger.color }
    var scrim: Color { tokens.bgScrim.color }
    var sidebar: Color { tokens.bgSidebar.color }
    var warningSubtle: Color { tokens.bgWarningSubtle.color }
    var pill: Color { tokens.bgSunken.color }

    var gutter: CGFloat { tokens.space5 }
    var radiusCard: CGFloat { tokens.radiusXL }

    func labelColor(_ hex: String?) -> Color? {
        hex.flatMap { ThemeColor(hex: $0) }?.color
    }
}

extension EnvironmentValues {
    @Entry var touch: TouchTheme = .light
}

struct PhoneThemed: ViewModifier {
    let store: ThemeStore
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let resolved = store.resolved
        let forced: ColorScheme? = switch store.preferences.mode {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
        content
            .environment(\.theme, resolved)
            .environment(\.touch, TouchTheme(resolved: resolved))
            .environment(store)
            .preferredColorScheme(forced)
            .tint(resolved.accentFill.color)
            .onChange(of: systemScheme, initial: true) { _, scheme in
                guard store.preferences.mode == .system else { return }
                store.systemAppearance = scheme == .dark ? .dark : .light
            }
            .onChange(of: store.preferences.mode) { _, mode in
                guard mode == .system else { return }
                store.systemAppearance = systemScheme == .dark ? .dark : .light
            }
            .onChange(of: contrast, initial: true) { _, value in store.increaseContrast = value == .increased }
            .onChange(of: reduceMotion, initial: true) { _, value in store.reduceMotion = value }
    }
}

extension View {
    func phoneThemed(by store: ThemeStore) -> some View {
        modifier(PhoneThemed(store: store))
    }
}
