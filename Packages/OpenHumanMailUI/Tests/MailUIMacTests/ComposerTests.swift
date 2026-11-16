import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailRender
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

@MainActor
@Suite struct ComposerTests {
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 600), styleMask: [.titled],
                          backing: .buffered, defer: false)
    let bridge = AttributedBridge(font: .systemFont(ofSize: 14))

    init() { window.isReleasedWhenClosed = false }

    func until(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        let clock = ContinuousClock()
        let deadline = clock.now + testBackstop
        while !condition() {
            if clock.now > deadline {
                Issue.record("condition not met within 15 s", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func key(_ chars: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 100,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func editor() -> ComposerTextView {
        let text = ComposerTextView.make()
        text.bridge = bridge
        text.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        window.contentView?.addSubview(text)
        return text
    }

    @Test func aReloadTellsTheComposerItsUndoStepsAreGone() {
        let text = editor()
        var reloads = 0
        text.onReload = { reloads += 1 }
        text.load(RichTextDocument(blocks: [.paragraph([.text("Hello", [])])]))
        #expect(reloads == 1)
        #expect(text.string == "Hello")
    }

    @Test func theBridgeRoundTripsTheSupportedFormatting() {
        let document = RichTextDocument(blocks: [
            .paragraph([.text("Plain ", []), .text("bold", [.bold]), .text(" and ", []), .text("both", [.bold, .italic])]),
            .paragraph([.text("under", [.underline]), .text(" ", []), .text("struck", [.strikethrough]), .text(" ", []),
                        .text("code", [.code])]),
            .paragraph([.link(URL(string: "https://example.com")!, [.text("a link", [])]), .lineBreak, .text("next line", [])]),
            .list(ordered: false, items: [[.paragraph([.text("one", [])])], [.paragraph([.text("two", [])])]]),
            .list(ordered: true, items: [[.paragraph([.text("first", [])])]]),
            .paragraph([]),
            .paragraph([.text("end", [])]),
        ])
        let attributed = bridge.attributedString(document)
        #expect(bridge.document(attributed) == document.normalized)
        #expect(attributed.string.contains("\t•\tone"), "AppKit's list marker text is shown")
        #expect(bridge.document(NSAttributedString(string: "")) == RichTextDocument())
        let html = ComposeSerializer.html(bridge.document(attributed), signature: nil)
        #expect(html.contains("<ul><li>one</li><li>two</li></ul>") && html.contains("<ol><li>first</li></ol>"))
        #expect(!html.contains("•"))
    }

    @Test func foreignFontsAndColorsAreNotKept() {
        let pasted = NSAttributedString(string: "Hello", attributes: [
            .font: NSFont(name: "Times New Roman", size: 30) ?? NSFont.systemFont(ofSize: 30),
            .foregroundColor: NSColor.systemRed, .backgroundColor: NSColor.yellow,
        ])
        #expect(bridge.document(pasted) == RichTextDocument(blocks: [.paragraph([.text("Hello", [])])]))
        let link = NSAttributedString(string: "x", attributes: [.link: URL(string: "javascript:alert(1)")!])
        #expect(bridge.document(link) == RichTextDocument(blocks: [.paragraph([.text("x", [])])]))
    }

    @Test func aSnippetIsInsertedWithItsVariablesFilledAndTheFirstUnresolvedSelected() throws {
        let text = editor()
        text.insertText("Hi ;;", replacementRange: NSRange(location: 0, length: 0))
        let snippet = SnippetInfo(id: "s1", name: "Intro", subject: nil,
                                  bodyHTML: "<p>Hello <b>{{first_name}}</b>, about {{project}} by {{date+1}}. \\{{x}}</p>",
                                  variables: [])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let context = SnippetContext(recipient: EmailAddress(name: "Dana Ruiz", email: "dana@acme.example"), myName: "Robin",
                                     now: Date(timeIntervalSince1970: 1_791_000_000), calendar: calendar,
                                     locale: Locale(identifier: "en_US_POSIX"))
        let insertion = ComposeSession.SnippetInsertion(snippet: snippet, document: ComposeSerializer.importHTML(snippet.bodyHTML),
                                                        range: 3..<5, context: context)
        let unresolved = text.insert(insertion)
        #expect(unresolved == ["project"])
        #expect(text.string == "Hi Hello Dana, about project by Sun, Oct 4, 2026. {{x}}")
        let selected = (text.string as NSString).substring(with: text.selectedRange())
        #expect(selected == "project", "the unresolved variable is selected for editing")
        let dana = (text.string as NSString).range(of: "Dana")
        let font = try #require(text.textStorage?.attribute(.font, at: dana.location, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func theTriggerRuleRunsOnTypedText() {
        let text = editor()
        var typed: [(String, Int)] = []
        text.onTyped = { typed.append(($0, $1)) }
        for ch in ["H", "i", " ", ";", ";"] { text.insertText(ch, replacementRange: text.selectedRange()) }
        let last = typed.last!
        #expect(SnippetTrigger.detect(in: last.0, caret: last.1, shortcuts: []) == .openPicker(range: 3..<5, query: ""))
        var keys: [ComposerTextView.PickerKey] = []
        text.pickerKeys = { keys.append($0); return true }
        text.moveDown(nil)
        text.insertNewline(nil)
        text.cancelOperation(nil)
        #expect(keys == [.down, .choose, .close])
        #expect(text.string == "Hi ;;", "the picker's keys do not edit the text")
    }

    @Test func commandKeysAndFormatting() {
        let text = editor()
        var commands: [ActionID] = []
        text.onCommand = { commands.append($0); return true }
        var escaped = 0
        text.onEscape = { escaped += 1 }
        #expect(text.handleCommandKey(key("\r", code: 36, modifiers: .command)))
        #expect(text.handleCommandKey(key("\u{7F}", code: 51, modifiers: .command)))
        #expect(text.handleCommandKey(key("L", code: 37, modifiers: [.command, .shift])))
        #expect(text.handleCommandKey(key(";", code: 41, modifiers: .command)))
        #expect(text.handleCommandKey(key("E", code: 14, modifiers: [.command, .shift])))
        #expect(commands == [.send, .discardDraft, .sendLater, .insertSnippet, .chooseFrom])
        #expect(!text.handleCommandKey(key("e", code: 14)), "plain keys type")
        text.cancelOperation(nil)
        #expect(escaped == 1)

        commands = []
        text.insertText("Hello there", replacementRange: NSRange(location: 0, length: 0))
        #expect(!text.handleCommandKey(key("\u{7F}", code: 51, modifiers: .command)), "mid-sentence: the text's own")
        text.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(!text.handleCommandKey(key("\u{7F}", code: 51, modifiers: .command)), "a selection: the text's own")
        text.setSelectedRange(NSRange(location: 0, length: 0))
        let held = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 100,
                                    windowNumber: window.windowNumber, context: nil, characters: "\u{7F}",
                                    charactersIgnoringModifiers: "\u{7F}", isARepeat: true, keyCode: 51)!
        #expect(!text.handleCommandKey(held), "a held ⌘⌫ that reached the start does not go on to discard")
        #expect(commands.isEmpty)
        #expect(text.handleCommandKey(key("\u{7F}", code: 51, modifiers: .command)))
        #expect(commands == [.discardDraft], "at the start: the discard path, with its Undo toast")
        text.string = ""

        text.insertText("word", replacementRange: NSRange(location: 0, length: 0))
        text.setSelectedRange(NSRange(location: 0, length: 4))
        #expect(text.handleCommandKey(key("b", code: 11, modifiers: .command)))
        #expect(text.document == RichTextDocument(blocks: [.paragraph([.text("word", [.bold])])]))
        text.handleCommandKey(key("b", code: 11, modifiers: .command))
        text.handleCommandKey(key("u", code: 32, modifiers: .command))
        #expect(text.document == RichTextDocument(blocks: [.paragraph([.text("word", [.underline])])]))
        text.handleCommandKey(key("\\", code: 42, modifiers: .command))
        #expect(text.document == RichTextDocument(blocks: [.paragraph([.text("word", [])])]))
        text.handleCommandKey(key("*", code: 28, modifiers: [.command, .shift]))
        #expect(text.document == RichTextDocument(blocks: [.list(ordered: false, items: [[.paragraph([.text("word", [])])]])]))
        text.handleCommandKey(key("*", code: 28, modifiers: [.command, .shift]))
        #expect(text.document == RichTextDocument(blocks: [.paragraph([.text("word", [])])]))
    }

    @Test func commandShiftPeriodDiscardsTheDraftWhereverTheCaretIs() {
        let text = editor()
        var commands: [ActionID] = []
        text.onCommand = { commands.append($0); return true }
        var escaped = 0
        text.onEscape = { escaped += 1 }
        text.translation = KeyTranslation(applyingModifiers: { _, _ in nil },
                                          asciiCharacter: { code, shift in code == 47 ? (shift ? ">" : ".") : nil })
        text.insertText("Hello there", replacementRange: NSRange(location: 0, length: 0))
        #expect(text.handleCommandKey(key(">", code: 47, modifiers: [.command, .shift])), "⌘⇧. as a US layout reports it")
        #expect(text.handleCommandKey(key(".", code: 47, modifiers: [.command, .shift])),
                "a layout that reports the unshifted . is still ⌘⇧., not AppKit's ⌘. cancel")
        #expect(commands == [.discardDraft, .discardDraft], "mid-sentence too, unlike ⌘⌫; the discard keeps its Undo")
        #expect(!text.handleCommandKey(key(".", code: 47, modifiers: .command)), "⌘. stays the text system's")
        #expect(escaped == 0 && text.string == "Hello there")
    }

    @Test func theCommandKeysComeFromTheCatalog() {
        let text = editor()
        var commands: [ActionID] = []
        text.onCommand = { commands.append($0); return true }
        #expect(text.handleCommandKey(key("F", code: 3, modifiers: [.command, .shift])))
        #expect(text.handleCommandKey(key("E", code: 14, modifiers: [.command, .shift])))
        #expect(text.handleCommandKey(key("U", code: 32, modifiers: [.command, .shift])))
        #expect(text.handleCommandKey(key("C", code: 8, modifiers: [.command, .shift])))
        #expect(text.handleCommandKey(key("B", code: 11, modifiers: [.command, .shift])))
        #expect(text.handleCommandKey(key("T", code: 17, modifiers: [.command, .shift])))
        #expect(text.handleCommandKey(key("A", code: 0, modifiers: [.command, .shift])), "⇧⌘A: Insert free times")
        #expect(commands == [.chooseFrom, .chooseFrom, .attachFiles, .showCc, .showBcc, .focusTo, .calendarInsertAvailability])
        text.commandKeys = KeyTable.composer(ActionCatalog.all.filter { $0.module != .calendar })
        #expect(!text.handleCommandKey(key("A", code: 0, modifiers: [.command, .shift])), "no calendar: ⇧⌘A does nothing")
        #expect(!text.handleCommandKey(key("\r", code: 36, modifiers: [.command, .shift])), "⇧⌘↵ is not Send")
        #expect(ComposerTextView.catalogKeys == KeyTable.composer(ActionCatalog.all))
        #expect(ComposerTextView.catalogKeys.values.allSatisfy { ActionCatalog.descriptor($0)?.scopes.contains(.composer) == true })
    }

    @Test func theEditorTableFollowsTheRegistry() {
        let text = editor()
        var commands: [ActionID] = []
        text.onCommand = { commands.append($0); return true }
        text.commandKeys = KeyTable.composer(ActionCatalog.all.filter { $0.module != .sendLater })
        #expect(!text.handleCommandKey(key("L", code: 37, modifiers: [.command, .shift])), "send later is off")
        #expect(text.handleCommandKey(key("\r", code: 36, modifiers: .command)))
        #expect(commands == [.send])
    }

    @Test func formattingKeysWorkOnOtherLayouts() {
        let text = editor()
        text.insertText("word", replacementRange: NSRange(location: 0, length: 0))
        text.setSelectedRange(NSRange(location: 0, length: 4))
        #expect(text.handleCommandKey(key("7", code: 26, modifiers: [.command, .shift])), "French: ⇧ and the 7 key type 7")
        #expect(text.document == RichTextDocument(blocks: [.list(ordered: true, items: [[.paragraph([.text("word", [])])]])]))
        #expect(text.handleCommandKey(key("&", code: 26, modifiers: [.command, .shift])), "US: the same key types &")
        #expect(text.document == RichTextDocument(blocks: [.paragraph([.text("word", [])])]))
        text.setSelectedRange(NSRange(location: 0, length: 4))
        text.translation = KeyTranslation(applyingModifiers: { _, _ in nil },
                                          asciiCharacter: { keyCode, _ in keyCode == 11 ? "b" : nil })
        #expect(text.handleCommandKey(key("и", code: 11, modifiers: .command)), "Russian input source, the B key")
        #expect(text.document == RichTextDocument(blocks: [.paragraph([.text("word", [.bold])])]))
        #expect(text.applyFormatting(.clearFormatting) && text.document == RichTextDocument(blocks: [.paragraph([.text("word", [])])]))
        #expect(!text.applyFormatting(.send), "only formatting entries format")
    }

    @Test func singleKeysTypeInTheComposer() async {
        let env = AppEnvironment.fake(corpus: .make(threadCount: 5, now: Date(timeIntervalSince1970: 1_791_000_000)),
                                      options: .init(remoteAck: .immediate))
        let router = AppRouter(environment: env)
        router.start()
        await until { router.list?.rows.count == 5 }
        let keys = KeyRouter.catalog(env.actions.descriptors)
        let target = window
        keys.isMailWindow = { $0 === target }
        keys.activeScopes = { [.list, .global] }
        var performed: [ActionID] = []
        keys.perform = { action, _ in performed.append(action); return router.perform(action) }
        let text = editor()
        #expect(window.makeFirstResponder(text))
        for (chars, code) in [("e", UInt16(14)), ("j", 38), ("#", 20)] {
            #expect(keys.route(key(chars, code: code)) != nil, "\(chars) passes through to the text view")
        }
        #expect(performed.isEmpty)
        #expect(router.list?.rows.count == 5, "nothing was marked done")
    }

    @Test func quotesFromTheKeyboardRoundTripAndLinksOpenThePanel() {
        let text = editor()
        text.insertText("quoted line", replacementRange: NSRange(location: 0, length: 0))
        #expect(text.handleCommandKey(key("(", code: 25, modifiers: [.command, .shift])), "⇧⌘9")
        #expect(text.document == RichTextDocument(blocks: [.quote([.paragraph([.text("quoted line", [])])])]))
        #expect(ComposeSerializer.html(text.document, signature: nil).contains("<blockquote"))
        let round = bridge.document(bridge.attributedString(text.document))
        #expect(round == text.document, "a quote survives the bridge both ways")
        text.handleCommandKey(key("(", code: 25, modifiers: [.command, .shift]))
        #expect(text.document == RichTextDocument(blocks: [.paragraph([.text("quoted line", [])])]))
        var panels = 0
        text.showLinkPanel = { _ in panels += 1 }
        #expect(text.handleCommandKey(key("K", code: 40, modifiers: [.command, .shift])), "⇧⌘K")
        #expect(panels == 1)
        #expect(!text.handleCommandKey(key("k", code: 40, modifiers: .command)), "⌘K stays the palette's")
    }

    @Test func theBodyStartsAtTheLabelsEdgeAndThePlaceholderSitsWhereTypedTextGoes() throws {
        let tokens = ThemeTokens.light
        let text = ComposerTextView.make()
        text.bridge = AttributedBridge(theme: tokens)
        #expect(text.textContainer?.lineFragmentPadding == 0 && text.textContainerInset.width == 0,
                "no padding: the text starts where the field labels do")
        #expect(text.bridge.font.pointSize == 13 && text.bridge.lineHeightValue == 18, "type.body, 13/18")
        text.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
        window.contentView?.addSubview(text)
        let words = "Write your reply. ⌘J for AI help"
        text.placeholder = words
        let placeholder = try #require(Self.inkBounds(of: text))
        text.insertText(words, replacementRange: NSRange(location: 0, length: 0))
        let typed = try #require(Self.inkBounds(of: text))
        #expect(abs(placeholder.minX - typed.minX) <= 1 && abs(placeholder.minY - typed.minY) <= 1,
                "the placeholder and the typed line share their place: \(placeholder) vs \(typed)")
        #expect(abs(placeholder.height - typed.height) <= 1)
        text.string = ""
        let one = text.contentHeight(forWidth: 400)
        #expect(one == 18 + 2 * ComposerTextView.verticalInset, "one line: \(one)")
        text.insertText("one\ntwo\nthree", replacementRange: NSRange(location: 0, length: 0))
        #expect(text.contentHeight(forWidth: 400) == 3 * 18 + 2 * ComposerTextView.verticalInset)
    }

    static func inkBounds(of view: NSView) -> NSRect? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.2 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return NSRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale, width: CGFloat(maxX - minX + 1) / scale,
                      height: CGFloat(maxY - minY + 1) / scale)
    }

    @Test func theCardAndTheHostRenderOnTheFakeStore() async throws {
        let env = AppEnvironment.fake(corpus: .small, options: .init(remoteAck: .immediate))
        env.router.start()
        await until { env.router.list?.state == .loaded }
        let manager = env.compose
        let session = try #require(manager.openNew(placement: .modal))
        session.to.text = "Dana Ruiz <dana@acme.example>,"
        let host = NSHostingView(rootView: ComposerHostView(manager: manager).frame(width: 900, height: 700))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
        let editors = Self.descendants(of: host).compactMap { $0 as? ComposerTextView }
        let text = try #require(editors.first)
        text.insertText("Hello from the editor", replacementRange: NSRange(location: 0, length: 0))
        #expect(session.plainText == "Hello from the editor")
        manager.close(session)
        #expect(manager.windowSession == nil)
    }

    static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
