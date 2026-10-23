import CoreGraphics

/// Sizes for the native window chrome. Content sizes (row heights, reader type) stay in the theme tokens.
public enum NativeMetrics {
    public enum Text {
        public static let body: CGFloat = 13
        public static let secondary: CGFloat = 12
        public static let caption: CGFloat = 11
    }

    public enum Toolbar {
        public static let symbolSize: CGFloat = 15
        public static let maxSplitSegments = 6
    }

    public enum Banner {
        public static let height: CGFloat = 32
        public static let topGap: CGFloat = 8
        public static let paddingX: CGFloat = 14
        /// The window-background fill under a floating capsule or card, so its text stays readable over the rows
        /// wherever the glass is thin or not drawn.
        public static let backingOpacity: Double = 0.85
    }

    public enum HintLine {
        public static let height: CGFloat = 26
        public static let textSize: CGFloat = 11
        public static let paddingX: CGFloat = 12
        public static let itemGap: CGFloat = 14
        public static let keyGap: CGFloat = 4
    }

    public enum Keycap {
        public static let textSize: CGFloat = 11
        public static let height: CGFloat = 16
        public static let minWidth: CGFloat = 16
        public static let paddingX: CGFloat = 4
        public static let cornerRadius: CGFloat = 4
        public static let strokeWidth: CGFloat = 1
    }

    public enum Sidebar {
        public static let minWidth: CGFloat = 180
        public static let idealWidth: CGFloat = 220
        public static let maxWidth: CGFloat = 320
        /// The account picture beside each account's section title.
        public static let avatarSize: CGFloat = 18
        public static let avatarTextSize: CGFloat = 8
    }

    public enum List {
        public static let plateCornerRadius: CGFloat = 6
        public static let plateInsetX: CGFloat = 8
        public static let plateInsetY: CGFloat = 1
        public static let selectedAlpha: CGFloat = 0.18
        public static let inactiveSelectedAlpha: CGFloat = 0.08
        public static let hoverAlpha: CGFloat = 0.05
        public static let checkedAlpha: CGFloat = 0.12
        public static let dateTextSize: CGFloat = 12
        public static let unreadDotSize: CGFloat = 8
    }

    public enum Tag {
        public static let textSize: CGFloat = 11
        public static let height: CGFloat = 18
        public static let fillOpacity: CGFloat = 0.14
        public static let paddingX: CGFloat = 7
    }

    public enum Reader {
        public static let maxColumnWidth: CGFloat = 720
        public static let subjectSize: CGFloat = 22
        public static let metaSize: CGFloat = 12
        public static let collapsedRowHeight: CGFloat = 36
        public static let monogramSize: CGFloat = 32
        public static let senderSize: CGFloat = 13
    }

    public enum Search {
        public static let fieldWidth: CGFloat = 260
        public static let focusedFieldWidth: CGFloat = 420
        /// The suggestions panel under the field: its list column, the tips or contact column beside it, and the
        /// rows, which match a source list's.
        public static let panelListWidth: CGFloat = 360
        public static let panelSideWidth: CGFloat = 248
        public static let panelRowHeight: CGFloat = 28
        public static let panelHeaderHeight: CGFloat = 26
        public static let panelPadding: CGFloat = 6
        public static let panelGap: CGFloat = 6
        public static let panelWindowMargin: CGFloat = 12
        public static let panelTipRowHeight: CGFloat = 20
        public static let panelPlateInsetX: CGFloat = 6
        public static let panelPlateRadius: CGFloat = 6
    }

    public enum Settings {
        public static let minWidth: CGFloat = 800
        public static let minHeight: CGFloat = 560
        /// The height of a regular switch or pop-up button, so rows without a control line up with rows that have one.
        public static let rowMinHeight: CGFloat = 22
        public static let compactRowMinHeight: CGFloat = 16
    }

    /// AppKit buttons in the window chrome (reader header, find bar, row actions).
    public enum Controls {
        public static let iconPointSize: CGFloat = 13
        /// The square an icon button keeps, so its bezel appearing on hover never moves its neighbours.
        public static let iconButtonSize: CGFloat = 28
    }

    /// Floating AppKit capsules (new-messages pill, retry bar, link preview).
    public enum Pill {
        public static let height: CGFloat = 28
        public static let paddingX: CGFloat = 12
        public static let spacing: CGFloat = 6
    }

    public enum Overlay {
        public static let cornerRadius: CGFloat = 16
        public static let paletteWidth: CGFloat = 640
        public static let paletteFieldTextSize: CGFloat = 17
        public static let paletteRowHeight: CGFloat = 40
    }
}
