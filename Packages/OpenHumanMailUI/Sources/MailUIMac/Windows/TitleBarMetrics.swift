import AppKit

@MainActor
protocol TitleBarMeasuring: AnyObject {
    var contentViewHeight: CGFloat { get }
    var layoutRectMaxY: CGFloat { get }
    var isFullScreen: Bool { get }
}

extension NSWindow: TitleBarMeasuring {
    var contentViewHeight: CGFloat { contentView?.bounds.height ?? contentLayoutRect.maxY }
    var layoutRectMaxY: CGFloat { contentLayoutRect.maxY }
    var isFullScreen: Bool { styleMask.contains(.fullScreen) }
}

/// How far the title bar and toolbar reach over a full-size content view, for crops and layout checks. A window
/// without a full-size content view, or in full screen, has nothing over its content.
enum TitleBarMetrics {
    @MainActor
    static func stripHeight(of window: some TitleBarMeasuring) -> CGFloat {
        guard !window.isFullScreen else { return 0 }
        return max(0, (window.contentViewHeight - window.layoutRectMaxY).rounded(.up))
    }
}
