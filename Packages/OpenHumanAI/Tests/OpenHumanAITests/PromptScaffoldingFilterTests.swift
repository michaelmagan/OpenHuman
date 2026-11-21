import Foundation
import Testing

@testable import OpenHumanAI

@Suite struct PromptScaffoldingFilterTests {
    let nonce = "UbStFFQlVbCA"

    func strip(_ text: String) -> String { PromptScaffoldingFilter.strip(text, nonce: nonce) }

    @Test func removesTheWrapperTagsTheModelEchoes() {
        #expect(strip("<email_data nonce=\"\(nonce)\">\nHi Dana,\n\nFriday works.\n</email_data nonce=\"\(nonce)\">")
            == "Hi Dana,\n\nFriday works.")
        #expect(strip("<email_data nonce=\"\(nonce)\" id=\"draft\" kind=\"draft\">Hi Dana</email_data>") == "Hi Dana")
        #expect(strip("Hi Dana,\n</email_data>\nBest,\nSam") == "Hi Dana,\nBest,\nSam")
    }

    @Test func removesEveryVariantOfTheTag() {
        let variants = [
            "<email_data nonce=\"x\">", "<EMAIL_DATA NONCE='abc'>", "<Email_Data kind=\"draft\" nonce=\"\(nonce)\">",
            "</email_data>", "< /email_data >", "<email-data>", "<email data id=\"1\">", "<email_data/>",
            "<\u{FF45}mail_data>", "\u{FF1C}email_data\u{FF1E}", "\u{2039}email_data nonce=\"x\">",
            "<user_instruction>", "</user_instruction>",
            "<user_instruction kind=\"question\">", "<context kind=\"today\">", "</context>",
        ]
        for tag in variants {
            #expect(strip("Hello \(tag) world") == "Hello world", "\(tag)")
            #expect(strip("\(tag)Hello") == "Hello", "\(tag)")
        }
    }

    @Test func whitespaceHeldAtTheEndOfAChunkIsKnownBeforeTheStreamEnds() {
        var filter = PromptScaffoldingFilter(nonce: nonce)
        var text = filter.feed("Friday works. ")
        #expect(text == "Friday works." && filter.pendingWhitespace == " ")
        text += filter.feed("<email")
        #expect(text == "Friday works." && filter.pendingWhitespace.isEmpty, "not while a tag may follow")
        text += filter.feed("_data>\nSee you then.\n")
        #expect(text == "Friday works.\nSee you then." && filter.pendingWhitespace == "\n")
        let shown = text + filter.pendingWhitespace
        text += filter.finish()
        #expect(text == shown, "the end of the stream adds nothing")
        #expect(filter.pendingWhitespace.isEmpty)

        var removed = PromptScaffoldingFilter(nonce: nonce)
        text = removed.feed("Friday works.\n</email_data> ")
        #expect(text == "Friday works." && removed.pendingWhitespace.isEmpty, "dropped after a removed tag")
        #expect(removed.finish().isEmpty)
    }

    @Test func anUnterminatedTagAtTheEndIsDropped() {
        #expect(strip("Hello <email_data nonce=\"x") == "Hello")
        #expect(strip("Hello <email_d") == "Hello <email_d")
        #expect(strip("Best, Sam\n</email_data") == "Best, Sam", "a closing tag cut off after its name")
    }

    @Test func theEscapedBracketsCloseTheirTag() {
        #expect(strip("\u{2039}context\u{203A}Thanks, Friday works for me.") == "Thanks, Friday works for me.")
        #expect(strip("\u{2039}/email_data\u{203A} Bye") == "Bye")
    }

    @Test func aSpacedBracketInProseStays() {
        #expect(strip("I need more < context before I can answer.") == "I need more < context before I can answer.")
        #expect(strip("Is x < context size?\nYes.") == "Is x < context size?\nYes.")
        #expect(strip("Hello < /email_data > world") == "Hello world", "a spaced tag that closes is still a tag")
    }

    @Test func removesTheNonceWherever() {
        #expect(strip("The code \(nonce) is gone") == "The code is gone")
        #expect(strip("lower \(nonce.lowercased()) too") == "lower too")
    }

    @Test func keepsProseThatOnlyMentionsTheBlockNames() {
        for text in [
            "The email_data block says the invoice is paid.", "Dana asks for the email data retention policy.",
            "Use a < b and a > c.", "<contextual> stays", "<emails> stays", "Price <100 EUR", "Hi <Dana>",
            "Ub is not the nonce", "  leading space stays", "trailing newline stays\n",
        ] {
            #expect(strip(text) == text, "\(text)")
        }
    }

    @Test func aTagSplitAcrossChunksNeverShows() {
        let text = "<email_data nonce=\"\(nonce)\" kind=\"draft\">\nHi Dana,\nThanks \(nonce)!\n</email_data nonce=\"\(nonce)\">"
        for size in 1...12 {
            var filter = PromptScaffoldingFilter(nonce: nonce)
            var shown = ""
            var rest = Substring(text)
            while !rest.isEmpty {
                let piece = rest.prefix(size)
                rest = rest.dropFirst(piece.count)
                shown += filter.feed(String(piece))
                #expect(!shown.contains("<"), "chunk \(size): \(shown)")
                #expect(!shown.lowercased().contains("email_data"), "chunk \(size): \(shown)")
                #expect(!shown.contains(String(nonce.prefix(4))), "chunk \(size): \(shown)")
            }
            shown += filter.finish()
            #expect(shown == "Hi Dana,\nThanks!", "chunk \(size)")
            #expect(filter.removedAny)
        }
    }

    @Test func plainTextStreamsWithoutDelay() {
        var filter = PromptScaffoldingFilter(nonce: nonce)
        #expect(filter.feed("Hello ") == "Hello")
        #expect(filter.feed("there") == " there")
        #expect(filter.finish() == "")
        #expect(!filter.removedAny)
    }

    @Test func onlyTagsLeavesNothing() {
        #expect(strip("<email_data nonce=\"\(nonce)\">\n\n</email_data nonce=\"\(nonce)\">\n") == "")
    }

    @Test func aRunawayTagEndsAtTheLineOrTheLimit() {
        #expect(strip("<email_data nonce=\"x\" and then text\nNext line") == "Next line")
        let long = "<email_data " + String(repeating: "a", count: 2_000) + " tail"
        #expect(!strip(long).contains("<"))
        #expect(!strip(long).contains("email_data"))
    }

    @Test func onlyAmbiguousTextWaitsForTheNextChunk() {
        var filter = PromptScaffoldingFilter(nonce: "Zq9rT2bX7mLp")
        #expect(filter.feed("by Friday") == "by Friday", "a word that is not the nonce's start shows at once")
        #expect(filter.feed(". Z") == ".", "the nonce's first letter waits")
        #expect(filter.feed("ebra <") == " Zebra", "and shows once it is not the nonce; a bracket waits")
        #expect(filter.finish() == " <", "the end releases what was held")
    }

    @Test func withoutANonceOnlyTheTagsGo() {
        #expect(PromptScaffoldingFilter.strip("<email_data nonce=\"\(nonce)\">Hi Dana</email_data>", nonce: nil) == "Hi Dana")
        #expect(PromptScaffoldingFilter.strip("The code \(nonce) stays", nonce: nil) == "The code \(nonce) stays")
    }
}
