import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanStore

let searchTestNow = Date(timeIntervalSince1970: 1_790_000_000)
let searchTestOptions: SearchParseOptions = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return SearchParseOptions(now: searchTestNow, calendar: calendar)
}()

func parseSearchQuery(_ text: String) throws -> SearchQuery {
    try SearchParser.parse(text, options: searchTestOptions)
}

func describe(_ term: SearchTerm) -> String {
    switch term {
    case let .text(text, field): return field.map { "\($0.rawValue):\(text)" } ?? "t:\(text)"
    case let .address(field, value): return "\(field.rawValue):\(value)"
    case let .label(name): return "label:\(name)"
    case let .mailbox(box): return "in:\(box.rawValue)"
    case let .isFlag(flag): return "is:\(flag.rawValue)"
    case let .has(has): return "has:\(has.rawValue)"
    case let .filename(name): return "fn:\(name)"
    case let .before(date): return "before:\(Int64(date.timeIntervalSince1970))"
    case let .after(date): return "after:\(Int64(date.timeIntervalSince1970))"
    case let .larger(n): return "larger:\(n)"
    case let .smaller(n): return "smaller:\(n)"
    case let .listID(id): return "list:\(id)"
    case let .rfc822msgid(id): return "msgid:\(id)"
    case .anywhere: return "anywhere"
    case let .not(inner): return "not(\(describe(inner)))"
    case let .or(items): return "or(\(items.map(describe).joined(separator: ",")))"
    case let .and(items): return "and(\(items.map(describe).joined(separator: ",")))"
    }
}

@Suite struct SearchParserGoldenTests {
    static let cases: [(String, String)] = [
        ("invoice", "t:invoice"),
        ("invoice acme", "t:invoice ; t:acme"),
        ("\"quarterly report\"", "t:quarterly report"),
        ("  spaced   out  ", "t:spaced ; t:out"),
        ("\"unterminated phrase", "t:unterminated phrase"),
        ("ab", "t:ab"),
        ("well-known", "t:well-known"),
        ("a-b -c", "t:a-b ; not(t:c)"),
        ("cafe\u{301}", "t:caf\u{E9}"),
        ("日本語", "t:日本語"),
        ("a\u{200B}b", "t:ab"),
        ("a\u{2}b\u{3}c", "t:a ; t:b ; t:c"),
        ("\"\" x", "t:x"),
        ("from:alice@example.com", "from:alice@example.com"),
        ("FROM:Alice", "from:Alice"),
        ("to:bob", "to:bob"),
        ("cc:carol", "cc:carol"),
        ("bcc:dave", "bcc:dave"),
        ("deliveredto:me@example.com", "to:me@example.com"),
        ("from:\"John Smith\"", "from:John Smith"),
        ("from:me", "from:me"),
        ("to:me", "to:me"),
        ("from:(a OR b)", "or(from:a,from:b)"),
        ("FROM:A TO:B", "from:A ; to:B"),
        ("subject:invoice", "subject:invoice"),
        ("subject:\"big deal\"", "subject:big deal"),
        ("subject:(a b)", "subject:a ; subject:b"),
        ("subject:re:", "subject:re:"),
        ("label:work", "label:work"),
        ("label:Clients/Acme", "label:Clients/Acme"),
        ("label:\"My Label\"", "label:My Label"),
        ("label:inbox", "label:inbox"),
        ("category:promotions", "label:CATEGORY_PROMOTIONS"),
        ("category:primary", "label:CATEGORY_PERSONAL"),
        ("category:bogus", "t:category:bogus"),
        ("in:inbox", "in:inbox"),
        ("in:sent", "in:sent"),
        ("in:trash", "in:trash"),
        ("in:spam", "in:spam"),
        ("in:drafts", "in:drafts"),
        ("in:draft", "in:drafts"),
        ("in:starred", "in:starred"),
        ("in:snoozed", "in:snoozed"),
        ("in:all", "in:allMail"),
        ("in:anywhere", "anywhere"),
        ("in:clients", "label:clients"),
        ("is:unread", "is:unread"),
        ("is:read", "is:read"),
        ("is:starred", "is:starred"),
        ("is:important", "is:important"),
        ("is:draft", "is:draft"),
        ("is:snoozed", "is:snoozed"),
        ("is:event", "is:event"),
        ("is:events", "is:event"),
        ("is:muted", "t:is:muted"),
        ("has:attachment", "has:attachment"),
        ("has:invite", "has:invite"),
        ("has:userlabels", "has:userLabels"),
        ("has:nouserlabels", "not(has:userLabels)"),
        ("has:drive", "t:has:drive"),
        ("filename:report.pdf", "fn:report.pdf"),
        ("filename:pdf", "fn:pdf"),
        ("before:2024/01/15", "before:1705276800"),
        ("after:2024-01-15", "after:1705276800"),
        ("after:1705276800", "after:1705276800"),
        ("before:2024/02/29", "before:1709164800"),
        ("after:2024/01/15 before:2024/02/29", "after:1705276800 ; before:1709164800"),
        ("older_than:2d", "before:1789827200"),
        ("newer_than:1y", "after:1758464000"),
        ("newer_than:3m", "after:1782051200"),
        ("larger:5M", "larger:5242880"),
        ("smaller:10k", "smaller:10240"),
        ("larger:2000", "larger:2000"),
        ("size:100", "and(larger:99,smaller:101)"),
        ("list:news.example.com", "list:news.example.com"),
        ("rfc822msgid:<abc@example.com>", "msgid:abc@example.com"),
        ("foo:bar", "t:foo:bar"),
        ("http://example.com", "t:http://example.com"),
        ("10:30", "t:10:30"),
        ("\"from:alice\"", "t:from:alice"),
        ("body:secret", "t:body:secret"),
        ("participants:x", "t:participants:x"),
        ("-spam", "not(t:spam)"),
        ("-from:bob", "not(from:bob)"),
        ("NOT from:bob", "not(from:bob)"),
        ("-\"exact phrase\"", "not(t:exact phrase)"),
        ("--x", "not(not(t:x))"),
        ("-(a b)", "not(and(t:a,t:b))"),
        ("-", "ERROR"),
        ("a OR b", "or(t:a,t:b)"),
        ("a OR b OR c", "or(t:a,t:b,t:c)"),
        ("from:a OR from:b", "or(from:a,from:b)"),
        ("x a OR b", "t:x ; or(t:a,t:b)"),
        ("{a b}", "or(t:a,t:b)"),
        ("{from:a from:b} urgent", "or(from:a,from:b) ; t:urgent"),
        ("(a b)", "t:a ; t:b"),
        ("(a OR b) c", "or(t:a,t:b) ; t:c"),
        ("a AND b", "t:a ; t:b"),
        ("a or b", "t:a ; t:or ; t:b"),
        ("in:inbox is:unread from:boss has:attachment", "in:inbox ; is:unread ; from:boss ; has:attachment"),
    ]

    @Test(arguments: cases) func golden(_ input: String, _ expected: String) throws {
        let parsed: SearchQuery
        do { parsed = try parseSearchQuery(input) } catch {
            #expect(expected == "ERROR", "\(input) threw \(error)")
            return
        }
        #expect(parsed.text == input)
        #expect(parsed.terms.map(describe).joined(separator: " ; ") == expected, "\(input)")
    }

    @Test func tableSize() { #expect(Self.cases.count >= 80) }
}

@Suite struct SearchParserErrorTests {
    static let cases: [(String, Int)] = [
        ("", 0), ("   ", 0), ("a AROUND 5 b", 2), ("a AROUND_3 b", 2), ("(a b", 0), ("a b)", 3), ("{a b", 0), ("a }", 2),
        ("OR a", 0), ("a OR", 2), ("from:", 0), ("from: bob", 0), ("a from:", 2), ("before:garbage", 0),
        ("before:2024/13/01", 0), ("before:2024/02/31", 0), ("after:2025/02/29", 0), ("larger:abc", 0),
        ("smaller:5x", 0), ("older_than:5x", 0), ("newer_than:", 0), ("a NOT", 2), ("x ((a)", 2),
        ("a -(b", 3),
    ]

    @Test(arguments: cases) func errorsCarryPositions(_ input: String, _ position: Int) {
        do {
            let parsed = try parseSearchQuery(input)
            Issue.record("\(input) parsed to \(parsed.terms)")
        } catch let StoreError.invalidQuery(message, at) {
            #expect(at == position, "\(input): \(message)")
        } catch {
            Issue.record("\(input): unexpected \(error)")
        }
    }

    @Test func boundsAreEnforced() {
        for input in [String(repeating: "a", count: SearchParser.maxLength + 1),
                      String(repeating: "(", count: 30) + "a" + String(repeating: ")", count: 30),
                      (0..<70).map { "w\($0)" }.joined(separator: " ")] {
            #expect(throws: StoreError.self) { try parseSearchQuery(input) }
        }
        #expect(throws: Never.self) { try parseSearchQuery(String(repeating: "(", count: 10) + "a" + String(repeating: ")", count: 10)) }
    }

    @Test(arguments: ["larger:9999999999g", "smaller:8589934592g", "size:9999999999g", "larger:9999999999999999m"])
    func sizesThatOverflowAreRejected(_ input: String) {
        #expect(throws: StoreError.self) { try parseSearchQuery(input) }
    }

    @Test func extremeSizesAndDatesStillParse() throws {
        #expect(try parseSearchQuery("larger:8589934591g").terms == [.larger(8_589_934_591 << 30)])
        #expect(try parseSearchQuery("smaller:9999999999k").terms == [.smaller(9_999_999_999 << 10)])
        #expect(try parseSearchQuery("size:9999999999").terms == [.and([.larger(9_999_999_998), .smaller(10_000_000_000)])])
        #expect(try parseSearchQuery("larger:0").terms == [.larger(0)])
        for input in ["after:99999999999", "before:100000000", "before:9999/12/31", "after:0001/01/01",
                      "older_than:999999y", "newer_than:999999m", "older_than:999999d", "newer_than:0d"] {
            let query = try parseSearchQuery(input)
            let compiled = SearchCompiler.compile(query, accounts: nil)
            #expect(!compiled.predicate.isEmpty, "\(input)")
            #expect(!query.canonicalText.isEmpty, "\(input)")
        }
    }

    @Test func parseSearchOnTheStoreUsesTheSameParser() throws {
        let store = try MailStore.openInMemoryForTesting()
        #expect(try store.parseSearch("from:a invoice").terms == [.address(.from, "a"), .text("invoice", field: nil)])
        #expect(throws: StoreError.self) { try store.parseSearch("(") }
    }
}

@Suite struct SearchSerializationTests {
    @Test func gmailQueryForTheServerFallback() throws {
        let q = try parseSearchQuery("from:alice \"quarterly report\" -label:\"My Label\" has:attachment is:unread before:2024/01/15 in:inbox")
        #expect(q.gmailQuery == "from:alice \"quarterly report\" -label:My-Label has:attachment is:unread before:1705276800 in:inbox")
        #expect(try parseSearchQuery("category:promotions subject:\"big deal\" larger:5M").gmailQuery
                == "category:promotions subject:\"big deal\" larger:5242880")
        #expect(try parseSearchQuery("{from:a from:b} urgent").gmailQuery == "(from:a OR from:b) urgent")
        #expect(try parseSearchQuery("in:all in:reminders is:unread").gmailQuery == "is:unread")
        #expect(try parseSearchQuery("has:invite").gmailQuery == "filename:ics")
        #expect(try parseSearchQuery("is:event").gmailQuery == "(filename:ics OR from:calendar-notification@google.com "
                + "OR subject:invitation OR subject:\"updated invitation\" OR subject:\"canceled event\" OR from:lu.ma "
                + "OR from:luma-mail.com OR from:eventbrite.com OR from:meetup.com OR from:partiful.com)")
        #expect(try parseSearchQuery("is:event").canonicalText == "is:event")
        #expect(try parseSearchQuery("has:nouserlabels").gmailQuery == "-has:userlabels")
    }

    @Test(arguments: [
        "invoice acme", "\"quarterly report\" -spam", "from:a OR from:b x", "subject:\"big deal\" label:Clients/Acme",
        "{a b} -(c d)", "in:inbox is:unread has:attachment filename:pdf", "before:2024/01/15 after:2024/01/01 larger:1k",
        "\"from:alice\" \"OR\" \"-x\" \"a(b)\"", "category:primary in:reminders in:all has:invite", "rfc822msgid:<x@y.z> list:l.example.com",
        "is:event -is:important",
    ])
    func canonicalTextRoundTrips(_ input: String) throws {
        let q = try parseSearchQuery(input)
        let again = try parseSearchQuery(q.canonicalText)
        #expect(again.terms == q.terms, "\(input) -> \(q.canonicalText)")
    }

    @Test func quotedValuesNeverBecomeOperators() throws {
        let q = SearchQuery(text: "", terms: [.text("from:alice", field: nil), .text("a b", field: .subject), .text("-x", field: nil),
                                             .text("OR", field: nil)])
        #expect(q.gmailQuery == "\"from:alice\" subject:\"a b\" \"-x\" \"OR\"")
        #expect(try parseSearchQuery(q.gmailQuery).terms == q.terms)
    }
}
