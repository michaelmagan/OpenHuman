import Foundation
import Testing
@testable import MailUI

struct SearchQueryTokensTests {
    static let fixtures: [(String, [String], String)] = [
        ("from:dana ", ["from:dana"], ""),
        ("from:dana", [], "from:dana"),
        ("from:dana subject:budget q4", ["from:dana", "subject:budget"], "q4"),
        ("subject:\"q4 budget\" notes", ["subject:\"q4 budget\""], "notes"),
        ("subject:\"q4 budget notes", [], "subject:\"q4 budget notes"),
        ("-from:dana has:attachment ", ["-from:dana", "has:attachment"], ""),
        ("from:a OR from:b", ["from:a"], "OR from:b"),
        ("(from:a OR to:b) x", [], "(from:a OR to:b) x"),
        ("subject:(dinner movie) x", ["subject:(dinner movie)"], "x"),
        ("from:josé.núñez@example.com ", ["from:josé.núñez@example.com"], ""),
        ("label:\"Team Notes\" is:unread ", ["label:\"Team Notes\"", "is:unread"], ""),
        ("foo:bar baz", [], "foo:bar baz"),
        ("from: dana", [], "from: dana"),
        ("hello from:dana ", [], "hello from:dana "),
        ("FROM:Dana ", ["FROM:Dana"], ""),
        ("from:dana    to:theo  x", ["from:dana", "to:theo"], "x"),
        ("", [], ""),
    ]

    @Test(arguments: fixtures.indices)
    func splitsTheLeadingOperators(_ i: Int) {
        let (query, tokens, rest) = Self.fixtures[i]
        let parts = SearchQueryTokens.split(query)
        #expect(parts.tokens.map(\.raw) == tokens, "tokens of “\(query)”")
        #expect(parts.rest == rest, "text after the pills of “\(query)”")
    }

    @Test(arguments: fixtures.indices)
    func joiningGivesTheQueryBack(_ i: Int) {
        let query = Self.fixtures[i].0
        let parts = SearchQueryTokens.split(query)
        let joined = SearchQueryTokens.join(parts.tokens, rest: parts.rest)
        let squeezed = { (s: String) in s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
        #expect(squeezed(joined) == squeezed(query))
        #expect(SearchQueryTokens.split(joined).tokens == parts.tokens, "stable")
    }

    @Test func pillsShowAndSpeakTheirParts() throws {
        let label = try #require(SearchQueryTokens.split("label:\"Team Notes\" ").tokens.first)
        #expect(label.displayName == "label:" && label.displayValue == "Team Notes")
        #expect(label.spokenLabel == "label Team Notes, search filter")
        let from = try #require(SearchQueryTokens.split("-from:Michael x").tokens.first)
        #expect(from.isNegated && from.displayName == "−from:")
        #expect(from.spokenLabel == "not from Michael, search filter")
        let long = try #require(SearchQueryTokens.split("from:averyveryverylongname@example-company.com ").tokens.first)
        #expect(long.shortValue.count == 28 && long.shortValue.contains("…") && long.shortValue.hasSuffix("company.com"))
        let older = try #require(SearchQueryTokens.split("older_than:2d ").tokens.first)
        #expect(older.spokenLabel == "older than 2d, search filter")
    }

    static let start = NSRange(location: 0, length: 0)

    static func edit(_ key: SearchFieldKey, _ text: String, selected: IndexSet = [],
                     caret: NSRange = start) -> SearchPillEdit? {
        SearchQueryTokens.edit(key, text: text, selected: selected, caret: caret)
    }

    static let kinds = ["from:matthew.walker@example.com", "to:theo", "-from:dana", "label:\"Team Notes\"",
                        "before:2026/10/01", "after:2026/09/01", "older_than:2d", "has:attachment", "is:unread",
                        "in:anywhere", "subject:(dinner movie)", "filename:pdf", "larger:5M"]

    @Test(arguments: kinds)
    func backspaceSelectsAnyPillThenRemovesIt(_ pill: String) throws {
        let text = "subject:budget " + pill + " "
        let first = try #require(Self.edit(.deleteBackward, text))
        #expect(first == SearchPillEdit(text: text, selected: [1], caret: Self.start, consumesKey: true),
                "the first ⌫ selects \(pill)")
        let second = try #require(Self.edit(.deleteBackward, text, selected: first.selected))
        #expect(second == SearchPillEdit(text: "subject:budget ", selected: [], caret: Self.start, consumesKey: true))
        #expect(SearchQueryTokens.removing([1], from: text) == "subject:budget ", "the remove control does the same")
    }

    @Test func backspaceInTheTextIsTheText() {
        #expect(Self.edit(.deleteBackward, "from:dana q4", caret: NSRange(location: 2, length: 0)) == nil)
        #expect(Self.edit(.deleteBackward, "q4 from:dana ") == nil, "no pill")
        #expect(Self.edit(.deleteBackward, "") == nil)
        #expect(Self.edit(.deleteForward, "from:dana q4") == nil, "no pill after the caret")
        #expect(Self.edit(.right, "from:dana q4") == nil)
        #expect(Self.edit(.typing("x"), "from:dana ") == nil)
    }

    @Test func aClickIntoTheTextLetsGoOfTheSelectedPill() {
        let moved = Self.edit(.deleteBackward, "from:dana q4", selected: [0], caret: NSRange(location: 2, length: 0))
        #expect(moved == SearchPillEdit(text: "from:dana q4", selected: [], caret: nil, consumesKey: false),
                "the caret left the pills: ⌫ edits the text")
        #expect(Self.edit(.other, "from:dana ", selected: [0])
                    == SearchPillEdit(text: "from:dana ", selected: [], caret: nil, consumesKey: false),
                "↩ and the like let go and go on")
        #expect(Self.edit(.escape, "from:dana ", selected: [0], caret: NSRange(location: 0, length: 0))
                    == SearchPillEdit(text: "from:dana ", selected: [], caret: Self.start, consumesKey: true),
                "Esc lets go of the pill and keeps it")
        #expect(Self.edit(.escape, "from:dana ") == nil, "nothing selected: Esc is the field's")
        #expect(Self.edit(.escape, "from:dana q4", selected: [0], caret: NSRange(location: 2, length: 0))?.consumesKey
                    == false, "the caret left the pills: Esc lets go and goes on")
        #expect(Self.edit(.deleteBackward, "from:dana ", selected: [4])?.selected == [0], "a stale position is ignored")
    }

    @Test func arrowsWalkAcrossThePills() throws {
        let text = "from:dana to:theo q4"
        let end = NSRange(location: 2, length: 0)
        #expect(Self.edit(.left, text, caret: end) == nil, "← in the text moves the caret")
        #expect(Self.edit(.left, text)?.selected == [1])
        #expect(Self.edit(.left, text, selected: [1])?.selected == [0])
        #expect(Self.edit(.left, text, selected: [0])?.selected == [0], "stays on the first pill")
        #expect(Self.edit(.right, text, selected: [0])?.selected == [1])
        let back = try #require(Self.edit(.right, text, selected: [1]))
        #expect(back == SearchPillEdit(text: text, selected: [], caret: Self.start, consumesKey: true), "back to the text")
        let deleted = try #require(Self.edit(.deleteForward, text, selected: [0]))
        #expect(deleted.text == "to:theo q4" && deleted.selected.isEmpty, "⌦ removes the pill after the caret")
    }

    @Test func selectAllTakesThePillsWithTheText() throws {
        let text = "from:dana to:theo q4"
        let whole = NSRange(location: 0, length: 2)
        let all = try #require(Self.edit(.selectAll, text, caret: NSRange(location: 1, length: 0)))
        #expect(all == SearchPillEdit(text: text, selected: [0, 1], caret: whole, consumesKey: true))
        #expect(Self.edit(.deleteBackward, text, selected: all.selected, caret: whole)?.text == "")
        #expect(Self.edit(.deleteForward, text, selected: all.selected, caret: whole)?.text == "")
        let typed = try #require(Self.edit(.typing("b"), text, selected: all.selected, caret: whole))
        #expect(typed == SearchPillEdit(text: "b", selected: [], caret: NSRange(location: 1, length: 0), consumesKey: true),
                "typing replaces everything")
        #expect(Self.edit(.selectAll, "q4") == nil, "no pills: the field selects its text")
    }

    @Test func aRemoveControlNamesItsFilter() throws {
        let from = try #require(SearchQueryTokens.split("from:dana ").tokens.first)
        #expect(from.removeLabel == "Remove from filter")
        let negated = try #require(SearchQueryTokens.split("-label:work ").tokens.first)
        #expect(negated.removeLabel == "Remove not label filter")
        let older = try #require(SearchQueryTokens.split("older_than:2d ").tokens.first)
        #expect(older.removeLabel == "Remove older than filter")
    }
}
