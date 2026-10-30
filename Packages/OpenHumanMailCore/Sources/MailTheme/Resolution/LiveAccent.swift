import Foundation

/// The user's accent colour as the system reports it for each appearance. With the System accent selected, the
/// resolver derives every accent token from it, adjusted until the contrast checks pass.
public struct LiveAccent: Sendable, Hashable {
    public var light: ThemeColor
    public var dark: ThemeColor

    public init(light: ThemeColor, dark: ThemeColor) {
        self.light = light
        self.dark = dark
    }

    public func color(for appearance: ThemeAppearance) -> ThemeColor { appearance == .dark ? dark : light }

    public static let accentID = "system"
    static let textContrast = 4.5
    static let ringContrast = 3.0
    static let lightFillLuminance = 0.45

    private static let white = ThemeColor(red: 1, green: 1, blue: 1)
    private static let black = ThemeColor(red: 0, green: 0, blue: 0)

    struct Surfaces {
        let window: ThemeColor
        let selected: ThemeColor
        let text: ThemeColor
    }

    func colors(for appearance: ThemeAppearance, on surfaces: Surfaces) -> [String: ThemeColor] {
        let base = Self.opaque(color(for: appearance))
        let away = appearance == .dark ? Self.white : Self.black
        let backgrounds = [surfaces.window, surfaces.selected]

        let fill: ThemeColor
        let onFill: ThemeColor
        if base.relativeLuminance > Self.lightFillLuminance {
            fill = Self.adjusted(base, toward: Self.white) { Self.black.contrastRatio(on: $0) >= Self.textContrast }
            onFill = Self.black
        } else {
            fill = Self.adjusted(base, toward: Self.black) { Self.white.contrastRatio(on: $0) >= Self.textContrast }
            onFill = Self.white
        }
        let fillHover = Self.mix(fill, onFill == Self.white ? Self.black : Self.white, 0.12)
        let text = Self.adjusted(base, toward: away) { c in backgrounds.allSatisfy { c.contrastRatio(on: $0) >= Self.textContrast } }
        let ring = Self.adjusted(base, toward: away) { c in backgrounds.allSatisfy { c.contrastRatio(on: $0) >= Self.ringContrast } }
        var strength = appearance == .dark ? 0.24 : 0.14
        var subtle = Self.mix(surfaces.window, base, strength)
        while surfaces.text.contrastRatio(on: subtle) < Self.textContrast, strength > 0.02 {
            strength -= 0.02
            subtle = Self.mix(surfaces.window, base, strength)
        }
        return ["accent.fill": fill, "accent.fillHover": fillHover, "accent.text": text, "accent.subtle": subtle,
                "accent.onFill": onFill, "accent.ring": ring]
    }

    func overrides(for appearance: ThemeAppearance, on surfaces: Surfaces) -> [String: TokenSource] {
        Dictionary(uniqueKeysWithValues: colors(for: appearance, on: surfaces).map { name, color in
            ("accent/" + name, TokenSource.value(.color(color)))
        })
    }

    private static func opaque(_ c: ThemeColor) -> ThemeColor {
        c.alpha < 1 ? c.composited(over: white) : c
    }

    static func mix(_ a: ThemeColor, _ b: ThemeColor, _ amount: Double) -> ThemeColor {
        let t = min(max(amount, 0), 1)
        func channel(_ x: Double, _ y: Double) -> Double { ((x + (y - x) * t) * 255).rounded() / 255 }
        return ThemeColor(red: channel(a.red, b.red), green: channel(a.green, b.green), blue: channel(a.blue, b.blue))
    }

    private static func adjusted(_ color: ThemeColor, toward target: ThemeColor, until passes: (ThemeColor) -> Bool) -> ThemeColor {
        for step in 0...40 {
            let candidate = mix(color, target, Double(step) / 40)
            if passes(candidate) { return candidate }
        }
        return target
    }
}
