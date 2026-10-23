import MailFeatures
import OpenHumanCore
import Testing
@testable import MailUI

@MainActor
struct CompletionListModelTests {
    let dana = EmailAddress(name: "Dana Ruiz", email: "dana@example.com")
    let dan = EmailAddress(name: "Dan Okafor", email: "dan@example.org")
    let danielle = EmailAddress(name: nil, email: "danielle@example.net")

    func shown(_ found: [EmailAddress], for query: String = "da") -> CompletionListModel {
        let list = CompletionListModel()
        list.update(query: query)
        list.receive(found, for: query)
        return list
    }

    @Test func filteringDropsPeopleAlreadyAddedRepeatsAndBlanksAndKeepsTheLimit() {
        let found = [dana, EmailAddress(name: "Dana R", email: "DANA@example.com"), dan,
                     EmailAddress(name: "Nobody", email: "  "), danielle]
        #expect(CompletionListModel.filtered(found, excluding: [], limit: 8) == [dana, dan, danielle])
        #expect(CompletionListModel.filtered(found, excluding: ["Dan@Example.org"], limit: 8) == [dana, danielle])
        #expect(CompletionListModel.filtered(found, excluding: [], limit: 2) == [dana, dan])
    }

    @Test func typingLooksPeopleUpAndLeavesOutGuestsAlreadyAdded() async {
        let people = [dana, dan, danielle]
        let list = CompletionListModel(debounce: .zero) { prefix in
            people.filter { $0.email.hasPrefix(prefix.lowercased()) }
        }
        list.update(query: " Dan ", excluding: ["dan@example.org"])
        await list.settle()
        #expect(list.query == "Dan")
        #expect(list.items == [dana, danielle])
        #expect(list.isShowing && list.selected == dana)
        list.update(query: "")
        #expect(!list.isShowing && list.items.isEmpty)
    }

    @Test func answersForAnOlderQueryAreIgnored() {
        let list = shown([dana])
        #expect(list.items == [dana])
        list.update(query: "dan")
        list.receive([dana, dan], for: "da")
        #expect(!list.items.contains(dan), "the answer for “da” came after “dan” was typed")
        list.receive([dan], for: "dan")
        #expect(list.items == [dan])
    }

    @Test func typingOnKeepsOnlyTheRowsThatStillFitUntilTheAnswerArrives() {
        let dariusz = EmailAddress(name: "Dariusz Nowak", email: "dariusz@example.com")
        let list = CompletionListModel(debounce: .seconds(60)) { _ in [] }
        list.update(query: "da")
        list.receive([dana, dan, danielle, dariusz], for: "da")
        #expect(list.handle(.down) == .moved && list.selected == dan)
        #expect(list.handle(.escape) == .dismissed)

        list.update(query: "dan")
        #expect(list.items == [dana, dan, danielle], "the answer for “dan” is still on its way")
        #expect(list.isShowing && list.cursor == 0, "typing opens the list again at its top row")
        #expect(list.handle(.accept) == .accepted(dana), "Return picks a row that fits what is typed")

        list.update(query: "dani")
        #expect(list.items.isEmpty, "the list was cleared by the pick, so it waits for the answer")
        list.receive([danielle], for: "dani")
        list.update(query: "danie", excluding: ["Danielle@example.net"])
        #expect(!list.isShowing, "someone added meanwhile is not offered")
    }

    @Test func aRowFitsWhenTheAddressOrAWordOfTheNameStartsWithTheText() {
        #expect(CompletionListModel.matches(dana, prefix: "DAN"))
        #expect(CompletionListModel.matches(dana, prefix: "ruiz"))
        #expect(CompletionListModel.matches(dana, prefix: "Dana R"))
        #expect(CompletionListModel.matches(danielle, prefix: "dani"))
        #expect(!CompletionListModel.matches(dana, prefix: "example"))
        #expect(!CompletionListModel.matches(dan, prefix: "dana"))
    }

    @Test func arrowsMoveTheHighlightAndReturnPicksIt() {
        #expect(CompletionListModel().handle(.down) == .ignored, "with nothing shown the keys stay with the field")
        let list = shown([dana, dan, danielle])
        #expect(list.cursor == 0)
        #expect(list.handle(.up) == .moved && list.cursor == 0)
        #expect(list.handle(.down) == .moved && list.cursor == 1)
        #expect(list.handle(.down) == .moved && list.cursor == 2)
        #expect(list.handle(.down) == .moved && list.cursor == 2, "the highlight stops at the last row")
        #expect(list.handle(.accept) == .accepted(danielle))
        #expect(!list.isShowing && list.items.isEmpty && list.query.isEmpty)
        #expect(list.handle(.accept) == .ignored, "a second Return belongs to the field")
    }

    @Test func pointingAtARowHighlightsIt() {
        let list = shown([dana, dan])
        list.select(1)
        #expect(list.selected == dan)
        list.select(9)
        #expect(list.cursor == 1)
    }

    @Test func escapeClosesOnlyTheListAndTypingOpensItAgain() {
        let list = shown([dana, dan])
        #expect(list.handle(.escape) == .dismissed)
        #expect(!list.isShowing && list.items == [dana, dan])
        #expect(list.handle(.escape) == .ignored, "the next Escape goes on to the editor")
        #expect(list.handle(.down) == .ignored && list.handle(.accept) == .ignored)
        list.update(query: "dan")
        list.receive([dan], for: "dan")
        #expect(list.isShowing && list.selected == dan)
    }

    @Test func theListShowsSixRowsThenScrolls() {
        let six = CompletionListMetrics.height(rows: 6)
        #expect(CompletionListMetrics.height(rows: 2) < six)
        #expect(CompletionListMetrics.height(rows: 9) == six)
        let many = (1...9).map { EmailAddress(name: "Person \($0)", email: "person\($0)@example.com") }
        let list = shown(many, for: "pe")
        #expect(list.items.count == 8, "the default limit")
        for _ in 0..<7 { _ = list.handle(.down) }
        #expect(list.cursor == 7)
    }

    @Test func aPickedPersonIsTypedAsNameAndAddress() {
        #expect(CompletionListModel.typed(dana) == "Dana Ruiz <dana@example.com>")
        #expect(CompletionListModel.typed(danielle) == "danielle@example.net")
        #expect(CompletionListModel.detail(dana) == "dana@example.com")
        #expect(CompletionListModel.detail(danielle) == nil)
    }

    @Test func aMirroredListShowsAnotherFieldsRowsAndHighlightWithoutLookingUp() {
        let list = CompletionListModel()
        list.mirror(query: " da", items: [dana, dan, danielle], cursor: 1)
        #expect(list.query == "da" && list.items == [dana, dan, danielle])
        #expect(list.isShowing && list.selected == dan)
        #expect(list.handle(.escape) == .dismissed && !list.isShowing)
        list.mirror(query: "da", items: [dana, dan], cursor: 5)
        #expect(!list.isShowing, "the same text keeps the list closed after Escape")
        list.mirror(query: "dan", items: [dan], cursor: 5)
        #expect(list.isShowing && list.selected == dan, "a cursor past the end starts at the top")
        list.mirror(query: "dan", items: [], cursor: 0)
        #expect(!list.isShowing)
    }
}
