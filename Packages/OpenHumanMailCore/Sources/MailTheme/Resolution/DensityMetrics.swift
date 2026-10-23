import Foundation

extension ThemeTokens {
    public var densityDelta: Double { rowHeight - densityDefaultRow }

    public func densityScaled(_ value: Double) -> Double { value + densityDelta / 2 }

    public var listPlateInsetY: Double { max(1, component.row.cursorInsetY + densityDelta / 4) }

    public var listPlateInsetX: Double { component.row.cursorInsetX + max(0, densityDelta) / 4 }

    public var listHoverTarget: Double {
        let delta = densityDelta
        return min(28, max(20, 24 + (delta < 0 ? delta / 4 : delta / 2)))
    }

    public var listGroupHeaderRow: Double { rowHeight }

    public var collapsedMessageRow: Double { densityScaled(component.thread.collapsedRow) }

    public var cardContentInsetY: Double { densityScaled(space5) }

    public var cardGap: Double { densityScaled(component.thread.messageGap) }

    public var messageHeaderHeight: Double { densityScaled(Self.defaultMessageHeaderHeight) }

    public static let defaultMessageHeaderHeight: Double = 36

    public func composerFieldHeight(default defaultHeight: Double) -> Double { densityScaled(defaultHeight) }

    public var footerHeight: Double { component.footer.height + min(0, densityDelta / 2) }
}
