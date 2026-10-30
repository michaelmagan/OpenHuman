import AppKit
import Testing
@testable import MailUI

struct ComposerGlyphTests {
    @Test func theAIGlyphsSymbolsExist() {
        #expect(AIWordButton.pencilSymbol == "pencil" && AIWordButton.sparkleSymbol == "sparkle")
        for name in [AIWordButton.pencilSymbol, AIWordButton.sparkleSymbol] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) is an SF Symbol here")
        }
    }

    @Test func theAttachmentSymbolsExist() {
        let samples = [("a.pdf", "application/pdf"), ("a.png", "image/png"), ("a.mov", "video/quicktime"),
                       ("a.m4a", "audio/mp4"), ("a.zip", "application/zip"), ("a.xlsx", ""), ("a.key", ""),
                       ("a.ics", "text/calendar"), ("a.txt", "text/plain"), ("a", "application/octet-stream")]
        let symbols = Set(samples.map { AttachmentChips.symbol(filename: $0.0, mimeType: $0.1) })
        #expect(symbols.count >= 9, "the kinds get their own symbols: \(symbols.sorted())")
        for name in symbols.union(["xmark.circle.fill"]) {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) is an SF Symbol here")
        }
    }
}
