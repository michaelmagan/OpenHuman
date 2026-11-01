import CoreGraphics
import MailTheme
import SwiftUI

public enum SelectCheckbox {
    public static let side: CGFloat = 14
    public static let lineWidth: CGFloat = 1.5

    public static func cornerRadius(_ theme: ThemeTokens, side: CGFloat = SelectCheckbox.side) -> CGFloat {
        min(CGFloat(theme.radiusXS), side / 4)
    }

    public static func outlineRect(_ box: CGRect) -> CGRect { box.insetBy(dx: lineWidth / 2, dy: lineWidth / 2) }

    public static func colors(_ theme: ThemeTokens) -> (fill: ThemeColor, tick: ThemeColor, outline: ThemeColor) {
        (theme.accentFill, theme.accentOnFill, theme.textTertiary)
    }

    public static func tick(in box: CGRect, yUp: Bool) -> CGPath {
        let points: [(x: CGFloat, y: CGFloat)] = [(0.26, 0.5), (0.43, 0.32), (0.75, 0.68)]
        let path = CGMutablePath()
        for (index, point) in points.enumerated() {
            let y = yUp ? box.minY + box.height * point.y : box.maxY - box.height * point.y
            let p = CGPoint(x: box.minX + box.width * point.x, y: y)
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}
