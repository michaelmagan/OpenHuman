import SwiftUI

// The original and the suggestion: side by side from `sideBySideWidth`, else one above the other with the original
// cut to a few lines. Subviews, in order: the original, the suggestion, and the original cut to those lines (not
// shown; it gives the height of the cut). Both arrangements come from the width proposed in one layout pass, and side
// by side is never taller than one above the other at the same width, so a narrower panel is never shorter. Why: an
// arrangement chosen from a measured width that is stored and given back, and that got shorter when narrower, could
// show a legacy scroll bar, narrow the panel, hide the bar, widen it and show the bar again without end.
struct AIComparisonLayout: Layout {
    var sideBySideWidth: CGFloat = AIComposerMetrics.sideBySideWidth
    var columnSpacing: CGFloat
    var rowSpacing: CGFloat

    // The heights of the parts at a width: the original and the suggestion given at most `height` (nil: as tall
    // as they need), and the original cut to its lines one above the other
    struct Measure {
        var original: (_ width: CGFloat, _ height: CGFloat?) -> CGFloat
        var version: (_ width: CGFloat, _ height: CGFloat?) -> CGFloat
        var cut: (_ width: CGFloat) -> CGFloat
    }

    struct Frames: Equatable {
        var original: CGRect
        var version: CGRect
        var height: CGFloat
        var sideBySide: Bool
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? AIComposerPanel.width
        return CGSize(width: width, height: frames(width: width, subviews)?.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let frames = frames(width: bounds.width, subviews) else { return }
        for (subview, frame) in zip(subviews, [frames.original, frames.version]) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(frame.size))
        }
        subviews[2].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }

    private func frames(width: CGFloat, _ subviews: Subviews) -> Frames? {
        guard subviews.count == 3 else { return nil }
        func height(_ subview: LayoutSubview, _ width: CGFloat, _ height: CGFloat?) -> CGFloat {
            subview.sizeThatFits(ProposedViewSize(width: width, height: height)).height
        }
        return Self.frames(width: width, sideBySideWidth: sideBySideWidth, columnSpacing: columnSpacing,
                           rowSpacing: rowSpacing, measure: Measure(original: { height(subviews[0], $0, $1) },
                                                                    version: { height(subviews[1], $0, $1) },
                                                                    cut: { height(subviews[2], $0, nil) }))
    }

    static func frames(width: CGFloat, sideBySideWidth: CGFloat, columnSpacing: CGFloat, rowSpacing: CGFloat,
                       measure: Measure) -> Frames {
        let width = max(width, 0)
        // Half a point over the cut's height, so rounding never drops its last line
        let cut = min(measure.original(width, measure.cut(width) + 0.5), measure.original(width, nil))
        let below = measure.version(width, nil)
        let stacked = cut + rowSpacing + below
        guard width >= sideBySideWidth else {
            return Frames(original: CGRect(x: 0, y: 0, width: width, height: cut),
                          version: CGRect(x: 0, y: cut + rowSpacing, width: width, height: below),
                          height: stacked, sideBySide: false)
        }
        let column = max((width - columnSpacing) / 2, 0)
        let original = measure.original(column, nil)
        let version = measure.version(column, nil)
        let height = min(max(original, version), stacked)
        return Frames(original: CGRect(x: 0, y: 0, width: column, height: measure.original(column, min(original, height))),
                      version: CGRect(x: column + columnSpacing, y: 0, width: column,
                                      height: measure.version(column, min(version, height))),
                      height: height, sideBySide: true)
    }
}

// The examples card at half the panel's width within its bounds, from the width the panel is given in the same
// layout pass
struct AIExamplesColumn: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? AIComposerPanel.width
        let card = subview.sizeThatFits(ProposedViewSize(width: AIComposerMetrics.examplesWidth(boxWidth: width),
                                                         height: nil))
        return CGSize(width: width, height: card.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: AIComposerMetrics.examplesWidth(boxWidth: bounds.width),
                                                         height: nil))
    }
}
