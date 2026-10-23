import CoreGraphics
import Foundation
import MailModel
import Testing
@testable import MailRender

struct InlineImageSizingTests {
    // A Retina screenshot of 1840 by 1000 pixels, in points
    static let screenshot = CGSize(width: 920, height: 500)

    @Test func aScreenshotStartsAtTheShareOfTheColumnForEachSize() {
        let column: CGFloat = 720
        #expect(InlineImageSize.small.size(natural: Self.screenshot, column: column) == CGSize(width: 216, height: 117))
        #expect(InlineImageSize.medium.size(natural: Self.screenshot, column: column) == CGSize(width: 432, height: 235))
        #expect(InlineImageSize.large.size(natural: Self.screenshot, column: column) == CGSize(width: 720, height: 391))
        #expect(InlineImageSize.original.size(natural: Self.screenshot, column: column) == Self.screenshot,
                "its own point size; the column caps only how it is shown")
        #expect(InlineImageSize.pastedDefault == .medium && InlineImageSize.medium.columnFraction == 0.6)
    }

    @Test func noSizeIsWiderThanItsShareOfTheColumn() {
        for width in stride(from: 10, through: 4000, by: 37) {
            let natural = CGSize(width: CGFloat(width), height: CGFloat(width) * 0.75)
            for column in [CGFloat(320), 600, 1024] {
                for preset in InlineImageSize.allCases {
                    let size = preset.size(natural: natural, column: column)
                    #expect(size.width <= natural.width, "never upscaled")
                    if let fraction = preset.columnFraction { #expect(size.width <= (fraction * column).rounded()) }
                    #expect(abs(size.height - size.width * 0.75) <= 1, "aspect ratio kept")
                }
            }
        }
    }

    @Test func aSmallPictureKeepsItsOwnSizeAndReadsAsOriginal() {
        let icon = CGSize(width: 40, height: 30)
        for preset in InlineImageSize.allCases { #expect(preset.size(natural: icon, column: 720) == icon) }
        #expect(InlineImageSize.matching(icon, natural: icon, column: 720) == .original)
        #expect(InlineImageSize.matching(CGSize(width: 432, height: 235), natural: Self.screenshot, column: 720) == .medium)
        #expect(InlineImageSize.matching(CGSize(width: 300, height: 163), natural: Self.screenshot, column: 720) == nil,
                "a dragged size is none of the four")
    }

    @Test func anUnknownColumnUsesTheReferenceWidth() {
        #expect(InlineImageSize.medium.size(natural: Self.screenshot, column: 0) == CGSize(width: 360, height: 196))
        #expect(InlineImageSize.medium.size(natural: Self.screenshot, column: .infinity).width == 360)
    }

    @Test func draggingKeepsTheAspectRatioBetweenAThumbnailAndTheColumn() {
        let shown = CGSize(width: 432, height: 235)
        #expect(InlineImageSizing.resized(shown, toWidth: 216, column: 720) == CGSize(width: 216, height: 118))
        #expect(InlineImageSizing.resized(shown, toWidth: 2, column: 720).width == InlineImageSizing.minimumWidth)
        #expect(InlineImageSizing.resized(shown, toWidth: 5000, column: 720).width == 720)
    }

    @Test func fittingScalesDownOnlyAndKeepsAVeryTallPictureInBounds() {
        #expect(InlineImageSizing.fit(CGSize(width: 800, height: 600), maxWidth: 480) == CGSize(width: 480, height: 360))
        #expect(InlineImageSizing.fit(CGSize(width: 100, height: 50), maxWidth: 480) == CGSize(width: 100, height: 50))
        let tall = InlineImageSizing.fit(CGSize(width: 1000, height: 40_000), maxWidth: 2000)
        #expect(tall.height <= InlineImageSizing.maximumSide && tall.width == 250)
    }

    @Test func theSentImageCarriesTheChosenWidthAndHeight() {
        let ref = InlineImageRef(contentID: "shot@openhuman", alt: "Pasted image")
            .sized(InlineImageSize.medium.size(natural: Self.screenshot, column: 720))
        let html = ComposeSerializer.html(RichTextDocument(blocks: [.image(ref)]), signature: nil)
        #expect(html.contains("<img src=\"cid:shot@openhuman\" alt=\"Pasted image\" width=\"432\" height=\"235\">"), "\(html)")
        #expect(ref.size == CGSize(width: 432, height: 235))
        #expect(InlineImageRef(contentID: "x", width: 10).size == nil, "a width alone is not a size")
    }

    @Test func mappingImagesReachesPicturesInListsAndQuotes() {
        let doc = RichTextDocument(blocks: [
            .image(InlineImageRef(contentID: "a")),
            .list(ordered: false, items: [[.paragraph([.text("item", [])]), .image(InlineImageRef(contentID: "b"))]]),
            .quote([.image(InlineImageRef(contentID: "c"))]),
        ])
        let sized = doc.mappingImages { $0.sized(CGSize(width: 10, height: 5)) }
        #expect(sized.inlineImageIDs == ["a", "b", "c"])
        #expect(sized == RichTextDocument(blocks: [
            .image(InlineImageRef(contentID: "a", width: 10, height: 5)),
            .list(ordered: false, items: [[.paragraph([.text("item", [])]),
                                           .image(InlineImageRef(contentID: "b", width: 10, height: 5))]]),
            .quote([.image(InlineImageRef(contentID: "c", width: 10, height: 5))]),
        ]))
    }
}
