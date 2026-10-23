import Foundation
import MailTheme

public enum CalendarPalette {
    public static let hues: [LabelChipHue] = [.sky, .lavender, .green, .tangerine, .teal, .rose]

    public static func hue(_ index: Int) -> LabelChipHue {
        hues[((index % hues.count) + hues.count) % hues.count]
    }

    public static func ink(_ index: Int, tokens: ThemeTokens) -> ThemeColor {
        tokens.labelChip(hue(index)).text
    }

    public enum BlockState: Sendable, Hashable {
        case normal, past, selected, outlined, invited, declined
    }

    public struct BlockColors: Sendable, Hashable {
        public let fill: ThemeColor
        public let text: ThemeColor
        public let bar: ThemeColor
        public let border: ThemeColor?
        public let dashedBorder: Bool
    }

    public static let pastFillStrength = 0.5

    public static func state(isSelected: Bool, isDeclined: Bool, needsAnswer: Bool, isTentative: Bool,
                             isPast: Bool) -> BlockState {
        if isSelected { return .selected }
        if isDeclined { return .declined }
        if needsAnswer { return .invited }
        if isTentative { return .outlined }
        return isPast ? .past : .normal
    }

    public static func block(_ index: Int, state: BlockState, tokens: ThemeTokens) -> BlockColors {
        let pair = tokens.labelChip(hue(index))
        let window = tokens.bgWindow
        switch state {
        case .normal:
            return BlockColors(fill: pair.bg, text: pair.text, bar: pair.text, border: nil, dashedBorder: false)
        case .past:
            let fill = mix(pair.bg, window, pastFillStrength)
            return BlockColors(fill: fill, text: readable(pair.text, on: fill, tokens: tokens), bar: mix(pair.text, window, 0.5),
                               border: nil, dashedBorder: false)
        case .selected:
            return BlockColors(fill: pair.text, text: pair.bg, bar: pair.text, border: nil, dashedBorder: false)
        case .outlined:
            return BlockColors(fill: window, text: readable(pair.text, on: window, tokens: tokens), bar: pair.text,
                               border: pair.text, dashedBorder: false)
        case .invited:
            return BlockColors(fill: window, text: readable(pair.text, on: window, tokens: tokens), bar: pair.text,
                               border: pair.text, dashedBorder: true)
        case .declined:
            return BlockColors(fill: window, text: tokens.textTertiary, bar: tokens.borderControl,
                               border: tokens.borderControl, dashedBorder: true)
        }
    }

    public static func readable(_ ink: ThemeColor, on fill: ThemeColor, tokens: ThemeTokens) -> ThemeColor {
        ink.contrastRatio(on: fill) >= 4.5 ? ink : tokens.textPrimary
    }

    public static func mix(_ a: ThemeColor, _ b: ThemeColor, _ amountOfA: Double) -> ThemeColor {
        let t = min(max(amountOfA, 0), 1)
        return ThemeColor(red: a.red * t + b.red * (1 - t), green: a.green * t + b.green * (1 - t),
                          blue: a.blue * t + b.blue * (1 - t), alpha: 1)
    }

    public enum BlockContent: Sendable, Hashable {
        case oneLine, titleAndTime, withPlace, withAccount
    }

    public static func content(height: Double) -> BlockContent {
        if height < 30 { return .oneLine }
        if height < 56 { return .titleAndTime }
        if height < 72 { return .withPlace }
        return .withAccount
    }
}
