import AppKit
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import Testing
@testable import MailUIMac

@MainActor
struct AttachmentDragTests {
    static let key = MessageKey(account: AccountID(1), rowID: 9, gmailMessageID: GmailMessageID("m9"))
    static func attachment(_ name: String) -> AttachmentInfo {
        AttachmentInfo(id: 4, filename: name, mimeType: "application/pdf", size: 2_048, contentID: nil, isInline: false)
    }

    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 600, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)

    init() { window.isReleasedWhenClosed = false }

    func strip(_ name: String = "invoice.pdf", writer: AttachmentDragWriter?) -> AttachmentStripView {
        let strip = AttachmentStripView([Self.attachment(name)], message: Self.key, theme: .light, formatting: ReaderFormatting())
        strip.frame = NSRect(x: 0, y: 0, width: 500, height: 120)
        window.contentView?.addSubview(strip)
        strip.dragWriter = writer
        strip.layoutSubtreeIfNeeded()
        return strip
    }

    static let writer = AttachmentDragWriter(fetch: { _, _ in throw CancellationError() })

    func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 100, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func aDragPastTheThresholdCarriesOneFilePromiseAndAJitterNone() throws {
        let tile = try #require(strip(writer: Self.writer).tiles.first)
        var drags: [[NSDraggingItem]] = []
        tile.beginDrag = { _, items, _ in drags.append(items) }
        tile.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20)))
        tile.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 21, y: 21)))
        #expect(drags.isEmpty)
        tile.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 30, y: 26)))
        tile.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 40, y: 30)))
        #expect(drags.count == 1 && drags.first?.count == 1)
        let provider = try #require(drags.first?.first?.item as? NSFilePromiseProvider)
        #expect(provider.fileType == "com.adobe.pdf")
        #expect(provider.userInfo is AttachmentPromiseDelegate, "the delegate lives as long as the provider")
        tile.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 40, y: 30)))
        #expect(AttachmentTileView.passesDragThreshold(from: .zero, to: NSPoint(x: 3, y: 0)) == false)
        #expect(AttachmentTileView.passesDragThreshold(from: .zero, to: NSPoint(x: 4, y: 0)))
    }

    @Test func withTheModuleOffATileStartsNoDrag() throws {
        let tile = try #require(strip(writer: nil).tiles.first)
        var drags = 0
        tile.beginDrag = { _, _, _ in drags += 1 }
        tile.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20)))
        tile.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 60, y: 40)))
        #expect(drags == 0 && tile.draggingItem() == nil)
    }

    @Test func thePromisedNameIsTheSafeNameForHostileNames() throws {
        for raw in ["invoice\u{202E}fdp.exe", "../../etc/passwd", "...hidden.pdf", "a\u{200B}b/c:d.pdf"] {
            let tile = try #require(strip(raw, writer: Self.writer).tiles.first)
            let provider = try #require(tile.draggingItem()?.item as? NSFilePromiseProvider)
            let delegate = try #require(provider.userInfo as? AttachmentPromiseDelegate)
            let name = delegate.filePromiseProvider(provider, fileNameForType: provider.fileType)
            #expect(name == ReaderFormatting.safeFilename(raw))
            #expect(!name.contains("/") && !name.hasPrefix(".") && !name.unicodeScalars.contains { $0.value == 0x202E })
        }
    }

    @Test func writesRunOffTheMainQueueAndTheSourceAllowsCopyOnly() throws {
        let tile = try #require(strip(writer: Self.writer).tiles.first)
        let provider = try #require(tile.draggingItem()?.item as? NSFilePromiseProvider)
        let delegate = try #require(provider.userInfo as? AttachmentPromiseDelegate)
        let queue = delegate.operationQueue(for: provider)
        #expect(queue !== OperationQueue.main && queue.maxConcurrentOperationCount == 1)
        #expect(AttachmentTileView.dragOperations == .copy)
    }

    @Test func theTileSaysItCanBeDragged() throws {
        let on = try #require(strip(writer: Self.writer).tiles.first)
        #expect(on.accessibilityHelp() == "Space previews it, Return or a double-click opens it, drag it to copy it.")
        let off = try #require(strip(writer: nil).tiles.first)
        #expect(off.accessibilityHelp() == "Space previews it, Return or a double-click opens it")
    }

    @Test func aFailedWriteReportsBackAndLeavesNothing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drag-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = Self.writer, attachment = Self.attachment("x.pdf"), key = Self.key
        let error = await Task.detached {
            AttachmentPromiseDelegate.waitForWrite(writer, attachment, key, to: folder)
        }.value
        #expect(error != nil)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty)
    }
}
