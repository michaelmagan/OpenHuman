import AppKit
import MailFeatures
import MailTheme
import MailUI

@MainActor
final class LabelChipRenderer {
    let theme: ThemeTokens
    let chipType: TypeStyle
    let chipFont: NSFont
    let chipHeight: CGFloat
    let paddingX: CGFloat
    let plates: [ThemeColor]
    static let minimumTextSize: Double = 11

    private struct Key: Hashable {
        let title: String
        let hue: LabelChipHue
        let muted: Bool
    }

    private var images: [Key: (image: NSImage, baseline: CGFloat)] = [:]

    init(theme: ThemeTokens) {
        self.theme = theme
        let scale = ThreadRowStyle.textScale(theme)
        var type = theme.typeCaption
        type.size = max(Self.minimumTextSize, Double((NativeMetrics.Tag.textSize * scale * 2).rounded() / 2))
        type.lineHeight = max(type.lineHeight, type.size)
        chipType = type
        chipFont = type.font
        chipHeight = (NativeMetrics.Tag.height * scale).rounded()
        paddingX = (NativeMetrics.Tag.paddingX * scale).rounded()
        plates = [theme.bgWindow, ThreadRowStyle.hoverFill(theme), ThreadRowStyle.checkedFill(theme),
                  ThreadRowStyle.cursorFill(theme), ThreadRowStyle.inactiveCursorFill(theme)]
    }

    // A tinted capsule: the ink at a low opacity, so one image sits on the window and on every row plate. The ink
    // is deepened where it would not read on the tint over one of the plates; a muted chip stays quiet.
    func colors(hue: LabelChipHue, muted: Bool) -> (fill: ThemeColor, ink: ThemeColor) {
        let base = muted ? theme.textTertiary : theme.labelChip(hue).text
        let fill = Self.tint(base)
        guard !muted else { return (fill, base) }
        return (fill, Self.readable(base, fill: fill, on: plates))
    }

    static func readable(_ ink: ThemeColor, fill: ThemeColor, on plates: [ThemeColor]) -> ThemeColor {
        let grounds = plates.map { fill.composited(over: $0) }
        let light = grounds.allSatisfy { $0.relativeLuminance > ink.relativeLuminance }
        let target = light ? ThemeColor(red: 0, green: 0, blue: 0) : ThemeColor(red: 1, green: 1, blue: 1)
        let steps = 20
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let candidate = ThemeColor(red: ink.red + (target.red - ink.red) * t, green: ink.green + (target.green - ink.green) * t,
                                       blue: ink.blue + (target.blue - ink.blue) * t)
            if grounds.allSatisfy({ candidate.contrastRatio(on: $0) >= ThreadRowStyle.minimumTextContrast }) { return candidate }
        }
        return target
    }

    static func tint(_ ink: ThemeColor) -> ThemeColor {
        ThemeColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: Double(NativeMetrics.Tag.fillOpacity))
    }

    func image(_ title: String, hue: LabelChipHue, muted: Bool) -> (image: NSImage, baseline: CGFloat) {
        let key = Key(title: title, hue: hue, muted: muted)
        if let cached = images[key] { return cached }
        let made = make(title, colors: colors(hue: hue, muted: muted))
        images[key] = made
        return made
    }

    static func counts(_ chips: [ThreadRowChip], maximum: Int) -> (visible: Int, hidden: Int) {
        let named = chips.filter { $0.kind != .overflow }
        guard !named.isEmpty else { return (0, 0) }
        let overflow = chips.first { $0.kind == .overflow }.flatMap { Int($0.title.dropFirst()) } ?? 0
        let visible = min(named.count, max(0, maximum))
        return (visible, named.count - visible + overflow)
    }

    static func shown(_ chips: [ThreadRowChip], maximum: Int) -> [(title: String, hue: LabelChipHue, muted: Bool)] {
        let (visible, hidden) = counts(chips, maximum: maximum)
        guard visible > 0 || hidden > 0 else { return [] }
        var result = chips.filter { $0.kind != .overflow }.prefix(visible).map {
            (title: $0.kind == .returned || $0.kind == .gmailImportant ? $0.title : $0.title.localizedLowercase,
             hue: $0.hue, muted: $0.isQuiet)
        }
        if hidden > 0 { result.append(overflow(hidden)) }
        return result
    }

    static func overflow(_ count: Int) -> (title: String, hue: LabelChipHue, muted: Bool) {
        (title: "+\(count)", hue: .neutral, muted: false)
    }

    private func make(_ title: String, colors: (fill: ThemeColor, ink: ThemeColor)) -> (image: NSImage, baseline: CGFloat) {
        let fill = colors.fill.nsColor, font = chipFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors.ink.nsColor]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let paddingX = paddingX
        let size = NSSize(width: (textSize.width + 2 * paddingX).rounded(.up), height: chipHeight)
        let radius = size.height / 2
        let textY = ((size.height - textSize.height) / 2).rounded()
        let image = NSImage(size: size, flipped: false) { rect in
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            (title as NSString).draw(at: NSPoint(x: paddingX, y: textY), withAttributes: attributes)
            return true
        }
        return (image, (textY - font.descender).rounded())
    }
}
