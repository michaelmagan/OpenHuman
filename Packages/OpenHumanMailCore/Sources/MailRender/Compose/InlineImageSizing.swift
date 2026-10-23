import CoreGraphics
import Foundation
import MailModel

extension InlineImageSize {
    // Share of the composer column; Original keeps the picture's own size
    public var columnFraction: CGFloat? {
        switch self {
        case .small: 0.3
        case .medium: 0.6
        case .large: 1
        case .original: nil
        }
    }

    public func size(natural: CGSize, column: CGFloat) -> CGSize {
        let limit = columnFraction.map { $0 * InlineImageSizing.column(column) } ?? .greatestFiniteMagnitude
        return InlineImageSizing.fit(natural, maxWidth: limit)
    }

    // A small picture is the same at every size, so the plainest name wins
    public static func matching(_ size: CGSize, natural: CGSize, column: CGFloat) -> InlineImageSize? {
        allCases.reversed().first { abs($0.size(natural: natural, column: column).width - size.width) <= 1 }
    }
}

public enum InlineImageSizing {
    public static let referenceColumn: CGFloat = 600
    public static let minimumWidth: CGFloat = 16
    public static let maximumSide: CGFloat = 10_000

    public static func column(_ width: CGFloat) -> CGFloat {
        width.isFinite && width >= minimumWidth ? width : referenceColumn
    }

    // Like the reader's max-width with height:auto: scaled down to fit, never up, the aspect ratio kept
    public static func fit(_ size: CGSize, maxWidth: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return size }
        var width = min(size.width, max(maxWidth, 1), maximumSide)
        if size.height * width / size.width > maximumSide { width = size.width * maximumSide / size.height }
        return CGSize(width: max(1, width.rounded()), height: max(1, (size.height * width / size.width).rounded()))
    }

    public static func resized(_ size: CGSize, toWidth width: CGFloat, column: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0, width.isFinite else { return size }
        let target = min(max(width, minimumWidth), Self.column(column))
        return fit(CGSize(width: target, height: size.height * target / size.width), maxWidth: target)
    }
}

extension InlineImageRef {
    public var size: CGSize? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    public func sized(_ size: CGSize) -> InlineImageRef {
        var ref = self
        ref.width = Int(size.width.rounded())
        ref.height = Int(size.height.rounded())
        return ref
    }
}
