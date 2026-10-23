import CoreGraphics
import Foundation
import MailFeatures
import MailTheme
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI

struct ComposerNativeLookTests {
    @Test func theFromMenuListsEveryAddressAndMarksTheCurrentOne() {
        let work = FromIdentity(email: "robin@example.com", name: "Robin Example", isGmailDefault: true, isPrimary: true)
        let alias = FromIdentity(email: "help@example.com", name: "Example Help")
        let unverified = FromIdentity(email: "robin@example.org", needsVerification: true)
        let rows = FromMenu.rows([work, alias, unverified], current: alias)
        #expect(rows.map(\.title) == ["Robin Example <robin@example.com>", "Example Help <help@example.com>",
                                      "robin@example.org"])
        #expect(rows.map(\.isCurrent) == [false, true, false], "exactly the chosen address is checked")
        #expect(rows[0].subtitle == "Gmail default")
        #expect(rows[1].subtitle == nil)
        #expect(rows[2].subtitle == "Not verified in Gmail: sending may fail" && rows[2].needsVerification)
        #expect(FromMenu.rows([work, alias], current: work) != FromMenu.rows([work, alias], current: alias),
                "a new choice rebuilds the menu's selection")
    }

    @Test func sendIsProminentOnlyWhenItCanSend() {
        #expect(SendButton.look(enabled: true) == .prominent)
        #expect(SendButton.look(enabled: false) == .unavailable, "a process that cannot send shows a plain Send")
    }

    @Test func aRecipientChipShowsItsStateWithoutHidingTheRemoveButton() {
        #expect(RecipientToken.look(valid: true, dragged: false) == .resting)
        #expect(RecipientToken.look(valid: true, dragged: true) == .dragged, "the dragged chip takes the accent fill")
        #expect(RecipientToken.look(valid: false, dragged: false) == .invalid)
        #expect(RecipientToken.look(valid: false, dragged: true) == .dragged)
        #expect(RecipientToken.removeStyle(hovered: false).opacity == 1, "the remove x stays visible at rest")
        let chip = RecipientToken.removeStyle(hovered: false, chipHovered: true)
        #expect(chip.opacity == 1 && chip.emphasized && !chip.plate, "hovering the chip brightens its x")
        let x = RecipientToken.removeStyle(hovered: true, chipHovered: true)
        #expect(x.emphasized && x.plate, "hovering the x itself puts a plate under it")
        #expect(!RecipientToken.removeStyle(hovered: false).plate)
        #expect(RecipientToken.removePlateSize <= RecipientToken.removeHitWidth)
    }

    @Test func aRecipientChipIsARoundedRectangleWithTheThemeTokenCorner() {
        #expect(RecipientToken.cornerRadius(token: 6, height: 22) == 6)
        #expect(RecipientToken.cornerRadius(token: 999, height: 22) == 11, "a pill theme still gets a pill, never more")
        #expect(RecipientToken.cornerRadius(token: 0, height: 22) == 4, "a square theme still gets a soft corner")
    }

    @Test func theFieldLabelsShareOneRightAlignedColumn() {
        #expect(FieldLabel.alignment == .trailing, "labels end at one edge, like the Mac's own forms")
        #expect(ComposerMetrics.labelGap > 0 && ComposerMetrics.labelGap < ComposerMetrics.labelWidth / 2)
        #expect(ComposerMetrics.labelWidth - ComposerMetrics.labelGap >= 48, "room for Subject at the body size")
    }

    @MainActor @Test func sendShowsItsShortcutTheWayMenusWriteIt() {
        #expect(SendButton.shortcutText(["⌘", "↵"]) == "⌘↵")
        #expect(SendButton.shortcutText(["⌘", "shift", "↵"]) == "⇧⌘↵", "modifiers in the menus' order")
        #expect(SendButton.shortcutText([]) == nil, "an unbound Send shows no keys")
        #expect(ComposerMetrics.sendShortcutOpacity > 0.5 && ComposerMetrics.sendShortcutOpacity < 1,
                "the keys read quieter than the word")
    }

    @Test func theFromReasonIsQuietAndOnlyAnUnverifiedAddressWarns() {
        let theme = ResolvedTheme.light
        #expect(FromLine.color(.quiet, theme: theme) == theme.textSecondary)
        #expect(FromLine.color(.warning, theme: theme) == theme.textWarning)
        #if os(macOS)
        #expect(!FromMenuButton.isBordered, "From is a borderless pop-up in its row, like the Mac's Mail")
        #endif
    }

    @Test func theSignatureToggleStaysFaintUntilThePointerIsNear() {
        let theme = ResolvedTheme.light
        #expect(SignatureAndQuote.toggleColor(hovered: false, theme: theme) == theme.textTertiary)
        #expect(SignatureAndQuote.toggleColor(hovered: true, theme: theme) == theme.textSecondary)
    }

    @Test func theToolGroupsHoldTheirButtonsWithAir() {
        #expect(ComposerMetrics.toolGroupHeight >= ComposerMetrics.iconButton + 2 * ComposerMetrics.toolGroupPadding)
        #expect(ComposerMetrics.toolGroupHeight <= ComposerMetrics.actionBarHeight)
        #expect(FormatBarMetrics.height <= ComposerMetrics.toolGroupHeight, "the format bar matches the tool capsules")
        #expect(FormatBarMetrics.inlinePadding >= (FormatBarMetrics.height - FormatBarMetrics.button) / 2)
    }

    @MainActor @Test func theFloatingMentionListAlwaysHasAQuery() {
        let address = EmailAddress(name: "Dana Reyes", email: "dana@example.org")
        let picker = MentionPickerModel(rows: [MentionRow(address: address)], query: "da", onChoose: { _ in })
        #expect(FloatingMentionList.query(picker) == "@da")
        let empty = MentionPickerModel(rows: [MentionRow(address: address)], onChoose: { _ in })
        #expect(FloatingMentionList.query(empty) == "@", "so the floating list shows before a letter is typed")
    }

    @Test func toolButtonsShowAPlateOnlyOnHoverOrPress() {
        #expect(ComposerToolStyle.plate(hovered: false, pressed: false, enabled: true) == .none)
        #expect(ComposerToolStyle.plate(hovered: true, pressed: false, enabled: true) == .hovered)
        #expect(ComposerToolStyle.plate(hovered: true, pressed: true, enabled: true) == .pressed)
        #expect(ComposerToolStyle.plate(hovered: true, pressed: true, enabled: false) == .none, "disabled stays flat")
    }

    @Test func formatButtonsShowTheActiveMarkAndTheirHover() {
        #expect(FormatButtonStyle.plate(active: false, hovered: false, pressed: false) == .none)
        #expect(FormatButtonStyle.plate(active: false, hovered: true, pressed: false) == .hovered)
        #expect(FormatButtonStyle.plate(active: true, hovered: false, pressed: false) == .active)
        #expect(FormatButtonStyle.plate(active: true, hovered: true, pressed: false) == .active)
        #expect(FormatButtonStyle.plate(active: true, hovered: true, pressed: true) == .pressed)
        #expect(FormatBarMetrics.floatingPadding >= (FormatBarMetrics.height - FormatBarMetrics.button) / 2,
                "the end buttons sit inside the capsule's rounded ends")
    }

    @Test func theCardKeepsAtLeastTheSystemSheetCorner() {
        #expect(ComposerSurface.radius(token: 4) == ComposerMetrics.minimumCardRadius)
        #expect(ComposerSurface.radius(token: 8) == ComposerMetrics.minimumCardRadius)
        #expect(ComposerSurface.radius(token: 20) == 20, "a theme with rounder cards keeps them")
    }

    @Test func theFieldRowsHaveRoomForTheirControls() {
        #expect(ComposerMetrics.fieldHeight > ComposerMetrics.dockedFieldHeight)
        #expect(ComposerMetrics.dockedFieldHeight >= ComposerMetrics.lineBand + 2 * 4,
                "a pop-up button and a chip fit with air above and below")
        #expect(ComposerMetrics.actionBarHeight >= ComposerMetrics.iconButton + 2 * 8)
        #expect(ComposerMetrics.attachmentTileHeight > ComposerMetrics.attachmentIcon)
    }

    @Test func theActionBarShrinksItsControlsWhenTheRowIsNarrow() {
        #expect(ComposerActionBar.Fit.allCases == [.full, .compact], "tried in this order")
        #expect(ComposerActionBar.Fit.full.controlSize == .large && ComposerActionBar.Fit.compact.controlSize == .regular)
    }

    @Test func theAttachmentSummaryCountsFilesAndBytes() {
        let size = ByteCountFormatter.string(fromByteCount: 2_400_000, countStyle: .file)
        #expect(AttachmentChips.summary(count: 1, bytes: 2_400_000) == "1 attachment · \(size)")
        #expect(AttachmentChips.summary(count: 3, bytes: 2_400_000) == "3 attachments · \(size)")
    }

    @Test func eachAttachmentGetsASymbolForItsKind() {
        #expect(AttachmentChips.symbol(filename: "agenda.pdf", mimeType: "application/pdf") == "doc.richtext")
        #expect(AttachmentChips.symbol(filename: "photo.jpg", mimeType: "image/jpeg") == "photo")
        #expect(AttachmentChips.symbol(filename: "photo", mimeType: "image/png") == "photo", "the MIME type when no extension")
        #expect(AttachmentChips.symbol(filename: "notes.txt", mimeType: "application/octet-stream") == "doc.text",
                "the extension wins over a generic MIME type")
        #expect(AttachmentChips.symbol(filename: "archive.zip", mimeType: "application/zip") == "doc.zipper")
        #expect(AttachmentChips.symbol(filename: "clip.mov", mimeType: "video/quicktime") == "film")
        #expect(AttachmentChips.symbol(filename: "invite.ics", mimeType: "text/calendar") == "calendar")
        #expect(AttachmentChips.symbol(filename: "blob", mimeType: "application/octet-stream") == "doc")
    }
}
