import MailTheme
import SwiftUI

extension ThemeColor {
    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

extension Color {
    public init(token: ThemeColor) { self = token.color }
}

extension ResolvedTheme {
    public var usesSystemAccent: Bool { accentID == LiveAccent.accentID }

    /// The tint for native controls: none with the System accent, so they follow the live system accent.
    public var controlTint: Color? { usesSystemAccent ? nil : tokens.accentFill.color }
}

extension TypeStyle {
    public var swiftUIWeight: Font.Weight {
        switch weight {
        case ..<150: return .ultraLight
        case ..<250: return .thin
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        case ..<850: return .heavy
        default: return .black
        }
    }

    public var swiftUIFont: Font {
        let font: Font = switch family {
        case .system: .system(size: size, weight: swiftUIWeight)
        case .systemSerif: .system(size: size, weight: swiftUIWeight, design: .serif)
        case .systemRounded: .system(size: size, weight: swiftUIWeight, design: .rounded)
        case .systemMono: .system(size: size, weight: swiftUIWeight, design: .monospaced)
        case .named(let name): .custom(name, fixedSize: size).weight(swiftUIWeight)
        }
        return monospacedDigits ? font.monospacedDigit() : font
    }
}

extension Font {
    public init(token: TypeStyle) { self = token.swiftUIFont }
}

extension View {
    public func themeFont(_ style: TypeStyle) -> some View {
        font(style.swiftUIFont).tracking(style.effectiveTracking)
    }

    public func themeShadow(_ shadow: ThemeShadow) -> some View {
        modifier(ThemeShadowModifier(shadow: shadow))
    }
}

private struct ThemeShadowModifier: ViewModifier {
    let shadow: ThemeShadow

    func body(content: Content) -> some View {
        shadow.layers.reduce(AnyView(content)) { view, layer in
            AnyView(view.shadow(color: layer.color.color, radius: layer.blur / 2, x: layer.x, y: layer.y))
        }
    }
}

extension MotionSpec {
    public var animation: Animation? {
        guard animates else { return nil }
        return switch easing {
        case .none, .linear: Animation.linear(duration: seconds)
        case let .cubicBezier(a, b, c, d): Animation.timingCurve(a, b, c, d, duration: seconds)
        }
    }
}

extension AnyTransition {
    public static func motion(_ spec: MotionSpec, offset: CGFloat) -> AnyTransition {
        spec.allowsTransform && offset != 0 ? .opacity.combined(with: .offset(y: offset)) : .opacity
    }

    public static func motion(_ spec: MotionSpec, scale: CGFloat, offset: CGFloat) -> AnyTransition {
        guard spec.allowsTransform else { return .opacity }
        return .opacity.combined(with: .scale(scale: scale)).combined(with: .offset(y: offset))
    }
}
