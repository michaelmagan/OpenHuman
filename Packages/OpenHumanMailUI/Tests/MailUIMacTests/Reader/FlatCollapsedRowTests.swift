import AppKit
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import Testing
@testable import MailUIMac

@MainActor
struct FlatCollapsedRowTests {
    private func olderRow(_ theme: ThemeTokens, width: CGFloat = 700) -> OlderMessagesPillView {
        let row = OlderMessagesPillView(count: 9, theme: theme)
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        row.layoutSubtreeIfNeeded()
        return row
    }

    private func collapsedRow(_ theme: ThemeTokens, width: CGFloat = 700, unread: Bool = false) -> CollapsedMessageView {
        let fixed = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let summary = MessageSummary(id: UIFixtures.message(1), from: UIFixtures.dana, to: [UIFixtures.me], cc: [], bcc: [],
                                     date: fixed.addingTimeInterval(-3600), snippet: "Works for me, see you then",
                                     isUnread: unread, attachments: [])
        let row = CollapsedMessageView(summary: summary, theme: theme, format: ThreadRowFormatting(), now: fixed)
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        row.layoutSubtreeIfNeeded()
        return row
    }

    @Test func thePlateIsHiddenAtRestTintedOnHoverAndRingedOnlyForFocusUnderIncreaseContrast() {
        for increaseContrast in [false, true] {
            var theme = ThemeTokens.light
            theme.increaseContrast = increaseContrast
            let plate = ReaderPlateView(theme: theme)
            #expect(plate.isHidden && plate.look == .none)
            plate.look = .hover
            #expect(!plate.isHidden && !plate.showsRing)
            plate.look = .focus
            #expect(!plate.isHidden && plate.showsRing == increaseContrast)
            plate.look = .none
            #expect(plate.isHidden)
            #expect(plate.hitTest(.zero) == nil, "the plate never takes a click")
        }
    }

    @Test func aCollapsedRowIs36PointsAndTheOlderRowMatchesItUnderItsHairline() {
        for density in ThemeDensity.allCases {
            var theme = ThemeTokens.light
            theme.density = density
            let expected = CGFloat(theme.densityScaled(Double(NativeMetrics.Reader.collapsedRowHeight)))
            #expect(collapsedRow(theme).fittingSize.height == expected, "\(density): 32 / 36 / 40")
            #expect(olderRow(theme).fittingSize.height == expected + 1, "\(density): the older-messages row and its hairline")
        }
    }

    @Test func theSnippetStartsAfterTheSenderColumn() throws {
        let theme = ThemeTokens.light
        for unread in [false, true] {
            let row = collapsedRow(theme, unread: unread)
            let snippet = row.snippetLabel.alignmentRect(forFrame: row.snippetLabel.frame)
            #expect(abs(snippet.minX - CGFloat(theme.component.row.senderMin + theme.space5)) < 0.5, "was \(snippet.minX)")
            let name = try #require(row.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Dana Ruiz" })
            let nameFrame = name.alignmentRect(forFrame: name.frame)
            #expect(abs(nameFrame.minX) < 0.5, "the sender at the content edge, was \(nameFrame.minX)")
            #expect(nameFrame.width <= CGFloat(theme.component.row.senderMin) + 0.5, "inside its column")
            let font = name.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            #expect(font?.fontName == theme.typeBodyStrong.font.fontName, "the sender is semibold, read or not")
        }
    }

    @Test func theOlderMessagesLabelSitsInTheSenderColumn() throws {
        for density in ThemeDensity.allCases {
            var theme = ThemeTokens.light
            theme.density = density
            let row = olderRow(theme)
            let label = try #require(row.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "9 older messages" })
            let frame = label.alignmentRect(forFrame: label.frame)
            #expect(abs(frame.minX - MessageContainerView.horizontalPadding(theme)) < 0.5,
                    "\(density): the label starts where the senders do, was \(frame.minX)")
            #expect(abs(frame.midY - row.bounds.midY) < 1, "\(density): centred vertically in the row")
        }
    }

    @Test func theOlderMessagesRowTintsUnderThePointer() throws {
        let row = olderRow(.light)
        let frame = row.frame
        #expect(!row.isHovered && row.plate.isHidden)
        let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0,
                                                        userData: nil))
        row.mouseEntered(with: enter)
        #expect(row.isHovered && !row.plate.isHidden)
        row.layoutSubtreeIfNeeded()
        #expect(row.frame == frame, "the tint never changes a frame")
        row.mouseExited(with: enter)
        #expect(!row.isHovered && row.plate.isHidden)
    }
}
