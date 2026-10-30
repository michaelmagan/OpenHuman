import AppKit
import MailUI
import Testing
@testable import MailUIMac

@MainActor
struct NativeControlsTests {
    private func paintsNoLayer(_ view: NSView) -> Bool {
        guard let layer = view.layer else { return true }
        return layer.backgroundColor == nil && layer.cornerRadius == 0 && layer.borderWidth == 0 && layer.shadowOpacity == 0
    }

    @Test func anIconButtonUsesTheAccessoryBarBezelOnlyWhileThePointerIsInside() {
        var pressed = 0
        let button = NSButton.nativeIcon("chevron.down", label: "Next match", help: "Next match  ⌘G") { pressed += 1 }
        #expect(button.isBordered && button.bezelStyle == .accessoryBarAction)
        #expect(button.showsBorderOnlyWhileMouseInside)
        #expect(button.imagePosition == .imageOnly && button.image != nil)
        #expect(button.accessibilityLabel() == "Next match", "the label has no shortcut")
        #expect(button.toolTip == "Next match  ⌘G", "the tooltip shows the shortcut")
        #expect(button.contentTintColor == .secondaryLabelColor)
        #expect(paintsNoLayer(button))
        #expect(button.target === button && button.action == #selector(NativeButton.pressed))
        button.pressed()
        #expect(pressed == 1)
    }

    @Test func anIconButtonKeepsItsSquareSoTheBezelNeverMovesItsNeighbours() {
        let button = NSButton.nativeIcon("ellipsis", label: "More") {}
        #expect(button.toolTip == "More")
        #expect(button.fittingSize == NSSize(width: NativeMetrics.Controls.iconButtonSize, height: NativeMetrics.Controls.iconButtonSize))
        let small = NSButton.nativeIcon("chevron.down", label: "Show details", pointSize: 9, size: 16) {}
        #expect(small.fittingSize == NSSize(width: 16, height: 16))
        let free = NSButton.nativeIcon("xmark", label: "Close", size: nil) {}
        #expect(free.contentHuggingPriority(for: .horizontal) == .required, "without a size it hugs its symbol")
    }

    @Test func aLinkIsBorderlessInTheSystemLinkColour() {
        var pressed = false
        let link = NSButton.nativeLink("Save all") { pressed = true }
        #expect(!link.isBordered && link.title == "Save all")
        #expect(link.contentTintColor == .linkColor)
        #expect(link.accessibilityLabel() == "Save all")
        #expect(link.font?.pointSize == NativeMetrics.Text.body)
        #expect(paintsNoLayer(link))
        link.pressed()
        #expect(pressed)
    }

    @Test func aPlainButtonIsSecondaryTextThatTruncates() {
        let plain = NSButton.nativePlain("to Dana Ruiz, Sam Lee and Robin Example")
        #expect(!plain.isBordered)
        #expect(plain.contentTintColor == .secondaryLabelColor)
        #expect(plain.lineBreakMode == .byTruncatingTail)
        #expect(plain.contentCompressionResistancePriority(for: .horizontal) == .defaultLow, "it gives way to the date")
        #expect(plain.accessibilityLabel() == "to Dana Ruiz, Sam Lee and Robin Example")
        #expect(plain.font?.pointSize == NativeMetrics.Text.secondary)
        #expect(paintsNoLayer(plain))
        plain.pressed()
    }

    @Test func aSeparatorIsASystemBoxThatTakesNoClicks() {
        let line = NativeSeparator()
        #expect(line.boxType == .separator && !line.isVertical)
        #expect(line.fittingSize.height == 1)
        #expect(!line.isAccessibilityElement())
        #expect(line.hitTest(.zero) == nil)
        let vertical = NativeSeparator(vertical: true)
        #expect(vertical.isVertical && vertical.fittingSize.width == 1)
    }

    @Test func aGlassPillHostsItsViewsOnGlassWithACapsuleShape() throws {
        let label = NSTextField(labelWithString: "3 new messages")
        let close = NSButton.nativeIcon("xmark", label: "Dismiss") {}
        let pill = NativeGlassPill(views: [label, close])
        pill.frame = NSRect(x: 0, y: 0, width: 240, height: NativeMetrics.Pill.height)
        pill.layoutSubtreeIfNeeded()
        #expect(pill.glass.cornerRadius == NativeMetrics.Pill.height / 2)
        #expect(pill.views == [label, close])
        #expect(pill.glass.contentView?.subviews.first === pill.stack)
        #expect(pill.fittingSize.height == NativeMetrics.Pill.height)
        #expect(pill.subviews.last === pill.glass, "the glass sits above its backing")
        let backing = try #require(pill.backing)
        #expect(backing.hitTest(.zero) == nil && !backing.isAccessibilityElement())
        #expect(abs(backing.fill.alphaComponent - CGFloat(NativeMetrics.Banner.backingOpacity)) < 0.001)
        pill.setViews([label])
        #expect(pill.views == [label])
        let bare = NativeGlassPill(height: 36, backed: false)
        #expect(bare.backing == nil && bare.glass.cornerRadius == 18)
    }
}
