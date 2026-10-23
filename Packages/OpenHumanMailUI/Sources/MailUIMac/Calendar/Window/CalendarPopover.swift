import AppKit
import MailFeatures
import MailModel
import MailTheme
import MailUI
import SwiftUI

// The event it belongs to marks its bounds; the event card and the new-event card open beside that mark, with an
// arrow pointing at it, as a system popover does
struct CalendarPopoverAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    func calendarPopoverAnchor(_ isTarget: Bool) -> some View {
        anchorPreference(key: CalendarPopoverAnchorKey.self, value: .bounds) { isTarget ? $0 : nil }
    }
}

struct CalendarPopoverPlacement: Equatable {
    enum ArrowEdge: Equatable { case leading, trailing }

    var origin: CGPoint
    var arrow: ArrowEdge?
    var arrowY: CGFloat = 0

    static let cornerRadius: CGFloat = NativeMetrics.Overlay.cornerRadius
    static let arrowSize: CGFloat = 9
    static let gap: CGFloat = 3
    static let topLead: CGFloat = 28

    // Beside the event when one side has room for the whole card, the right side first; otherwise pinned to the edge
    // away from the event, without an arrow. The card's top stays near the event's top, so a card that grows while
    // typing grows down instead of moving.
    static func place(target: CGRect?, size: CGSize, in bounds: CGSize, margin: CGFloat) -> CalendarPopoverPlacement {
        let trailingX = max(bounds.width - margin - size.width, margin)
        let maxTop = max(bounds.height - margin - size.height, margin)
        guard let target, target.width > 0, target.height > 0, target.maxY > 0, target.minY < bounds.height,
              target.maxX > 0, target.minX < bounds.width else {
            return CalendarPopoverPlacement(origin: CGPoint(x: trailingX, y: margin))
        }
        let visibleTop = min(max(target.minY, 0), bounds.height)
        let visibleMid = (visibleTop + min(max(target.maxY, 0), bounds.height)) / 2
        let top = min(max(visibleTop - topLead, margin), maxTop)
        let reach = gap + arrowSize
        if target.maxX + reach + size.width + margin <= bounds.width {
            return CalendarPopoverPlacement(origin: CGPoint(x: target.maxX + reach, y: top), arrow: .leading,
                                            arrowY: visibleMid - top)
        }
        if target.minX - reach - size.width - margin >= 0 {
            return CalendarPopoverPlacement(origin: CGPoint(x: target.minX - reach - size.width, y: top), arrow: .trailing,
                                            arrowY: visibleMid - top)
        }
        let narrow = target.width < bounds.width / 2
        let x = narrow && target.midX > bounds.width / 2 ? margin : trailingX
        return CalendarPopoverPlacement(origin: CGPoint(x: x, y: top))
    }
}

// A rounded card with an optional arrow on its leading or trailing edge
struct CalendarPopoverShape: Shape {
    var cornerRadius: CGFloat = CalendarPopoverPlacement.cornerRadius
    var arrow: CalendarPopoverPlacement.ArrowEdge?
    var arrowY: CGFloat = 0
    var arrowSize: CGFloat = CalendarPopoverPlacement.arrowSize

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, rect.width / 2, rect.height / 2)
        let s = arrowSize
        let canPoint = rect.height >= 2 * (r + s)
        let y = min(max(rect.minY + arrowY, rect.minY + r + s), rect.maxY - r - s)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r),
                    radius: r)
        if arrow == .trailing, canPoint {
            path.addLine(to: CGPoint(x: rect.maxX, y: y - s))
            path.addLine(to: CGPoint(x: rect.maxX + s, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y + s))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY),
                    radius: r)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r),
                    radius: r)
        if arrow == .leading, canPoint {
            path.addLine(to: CGPoint(x: rect.minX, y: y + s))
            path.addLine(to: CGPoint(x: rect.minX - s, y: y))
            path.addLine(to: CGPoint(x: rect.minX, y: y - s))
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r, y: rect.minY),
                    radius: r)
        path.closeSubpath()
        return path
    }
}

// The event card or the new-event card over the grid, placed beside the event it belongs to
struct CalendarPopoverLayer: View {
    @Bindable var model: CalendarWindowModel
    let target: CGRect?
    let bounds: CGSize
    @Environment(\.theme) private var theme
    @State private var height: CGFloat = 0

    var body: some View {
        let margin = theme.space4
        let width = CGFloat(CalendarCardMode.width(available: Double(bounds.width - 2 * margin)))
        let maxHeight = max(bounds.height - 2 * margin, 220)
        let place = CalendarPopoverPlacement.place(target: target, size: CGSize(width: width, height: height),
                                                   in: bounds, margin: margin)
        let shape = CalendarPopoverShape(arrow: place.arrow, arrowY: place.arrowY)
        if model.card != nil || model.showsPendingCard {
            card(width: width, maxHeight: maxHeight)
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .clipShape(RoundedRectangle(cornerRadius: CalendarPopoverPlacement.cornerRadius, style: .continuous))
                .background {
                    shape.fill(theme.component.popover.bg.color)
                        .themeShadow(theme.component.popover.shadow)
                }
                .overlay {
                    shape.stroke(theme.component.popover.border.color, lineWidth: theme.borderWidthHairline)
                        .allowsHitTesting(false)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(model.card != nil ? "calendar.window.popover" : "calendar.window.pendingCard")
                // Whole points: the height only places the card, and a fraction of a point is not worth another pass
                .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { height = $0 }
                .opacity(height > 0 ? 1 : 0)
                .padding(.leading, place.origin.x)
                .padding(.top, place.origin.y)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func card(width: CGFloat, maxHeight: CGFloat) -> some View {
        if model.card != nil {
            CalendarEventCardView(model: model, width: width, maxHeight: maxHeight)
        } else {
            CalendarDraftEditor(model: model.sidebar, showsDay: false, width: width, maxHeight: maxHeight,
                                onCancel: { Task { await model.cancelPending() } },
                                title: String(localized: "New event"), drawsBackground: false)
        }
    }
}
