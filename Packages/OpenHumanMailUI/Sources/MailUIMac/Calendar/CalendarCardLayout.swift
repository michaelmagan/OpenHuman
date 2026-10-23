import AppKit
import SwiftUI

// A card's parts, top to bottom. The part marked `calendarCardScrolls()` takes the height its content needs, up to
// what `maxHeight` leaves after the other parts, and scrolls beyond it. Every height comes from the parts at the card's
// width within one layout pass: nothing is measured, stored and given back to a later pass, so the card cannot ask
// for a size that asks for another.
struct CalendarCardColumn: Layout {
    var maxHeight: CGFloat
    var minScrollHeight: CGFloat = 0

    struct Scrolls: LayoutValueKey {
        static let defaultValue = false
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return CGSize(width: width, height: heights(width: width, subviews).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (subview, height) in zip(subviews, heights(width: bounds.width, subviews)) {
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height
        }
    }

    private func heights(width: CGFloat, _ subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let fixed = zip(subviews, ideal).reduce(CGFloat(0)) { sum, part in sum + (part.0[Scrolls.self] ? 0 : part.1) }
        let room = max(maxHeight - fixed, minScrollHeight, 0)
        return zip(subviews, ideal).map { subview, height in subview[Scrolls.self] ? min(height, room) : height }
    }
}

// The sidebar's parts, top to bottom with `spacing` between them. The part marked `calendarFitsRoom(givingUp:)` (the
// day) gives up to that much of its ideal height so the parts fit `room`, and never grows past it. The room
// is the scroll view's height, which does not depend on what it scrolls; every other height comes from the parts at
// the column's width within one layout pass. Why: hours sized from a measured content height that is stored and given
// back ask for another pass on each change of the content.
struct CalendarFitColumn: Layout {
    var room: CGFloat
    var spacing: CGFloat

    // How much of its ideal height the part gives up at most
    struct FitsRoom: LayoutValueKey {
        static let defaultValue: CGFloat? = nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return CGSize(width: width, height: heights(width: width, subviews).reduce(0, +) + gaps(subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (subview, height) in zip(subviews, heights(width: bounds.width, subviews)) {
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + spacing
        }
    }

    private func gaps(_ subviews: Subviews) -> CGFloat { spacing * CGFloat(max(subviews.count - 1, 0)) }

    private func heights(width: CGFloat, _ subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        guard room > 0, let fitting = subviews.firstIndex(where: { $0[FitsRoom.self] != nil }) else { return ideal }
        let others = ideal.indices.reduce(CGFloat(0)) { sum, index in sum + (index == fitting ? 0 : ideal[index]) }
        let least = ideal[fitting] - max(subviews[fitting][FitsRoom.self] ?? 0, 0)
        let wanted = (room - others - gaps(subviews)).rounded(.down)
        var result = ideal
        result[fitting] = min(max(wanted, least), ideal[fitting])
        return result
    }
}

// Its content at its ideal width when that fits, narrower when it does not. Why: one control in place of a
// ViewThatFits choosing between a fixed and a shrinking copy of it; measuring the copy that is not shown made a new
// AppKit control for each pass
struct CalendarUpToIdealWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let ideal = subview.sizeThatFits(.unspecified)
        let width = min(ideal.width, proposal.width ?? ideal.width)
        return subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height ?? ideal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

// A card's scrolling fields, laid out at the card's width whether or not a scroll bar shows
struct CalendarCardScroll<Content: View>: View {
    let width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical) {
            content.calendarScrollContent(width: width)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

extension View {
    func calendarCardScrolls() -> some View {
        layoutValue(key: CalendarCardColumn.Scrolls.self, value: true)
    }

    func calendarFitsRoom(givingUp most: CGFloat) -> some View {
        layoutValue(key: CalendarFitColumn.FitsRoom.self, value: most)
    }

    // Scroll content at `width`, less the room a legacy scroll bar takes beside it whether or not the bar shows.
    // Why: content that re-wrapped to the bar's width could show the bar, fit without it, hide it and overflow again
    // without end; at one width the bar coming and going changes nothing inside
    func calendarScrollContent(width: CGFloat) -> some View {
        modifier(CalendarScrollContentWidth(width: width))
    }
}

private struct CalendarScrollContentWidth: ViewModifier {
    let width: CGFloat
    @State private var reserve: CGFloat?

    func body(content: Content) -> some View {
        content
            .frame(width: max(width - (reserve ?? CalendarScrollerReserve.width), 0), alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
                reserve = CalendarScrollerReserve.width
            }
    }
}

@MainActor
enum CalendarScrollerReserve {
    // A legacy scroll bar (a mouse attached, or Show scroll bars: Always) takes this much beside the content; an
    // overlay one floats over it and takes none
    static var width: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }
}
