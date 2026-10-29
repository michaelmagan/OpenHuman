import AppKit
import MailFeatures
import SwiftUI
import Testing
@testable import MailUI

@MainActor
@Suite(.serialized)
struct SettingsSidebarWindowTests {
    @Test func footerStaysBelowTheLastRowAtShortHeights() async throws {
        let build = BuildLabel(version: "0.1.0", build: "1001", channel: "early-development")
        let pages = SettingsShellView.standalonePages(SettingsShellModel.standalone().pages)
        for (height, text) in [(CGFloat(180), DynamicTypeSize.large), (CGFloat(240), .accessibility2)] {
            let content = SettingsSidebar(pages: pages, selection: .constant(SettingsPageID.advanced.rawValue),
                                          build: build, footerFrameProbe: AnyView(FooterFrameProbe()))
                .environment(\.dynamicTypeSize, text)
                .frame(width: 260, height: height)
            let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000, width: 260, height: height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: 260, height: height)
            window.contentView = host
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()

            try await until(timeout: .seconds(5)) {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                return views(in: host).contains { ($0 as? NSTableView)?.numberOfRows == pages.count }
                    && views(in: host).contains {
                        $0.accessibilityIdentifier() == FooterFrameProbe.identifier && !$0.bounds.isEmpty
                    }
            }
            let table = try #require(views(in: host).compactMap { $0 as? NSTableView }
                .first { $0.numberOfRows == pages.count })
            let scroll = try #require(table.enclosingScrollView)
            let list = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
            let probe = try #require(views(in: host).first {
                $0.accessibilityIdentifier() == FooterFrameProbe.identifier
            })
            let footer = window.convertToScreen(probe.convert(probe.bounds, to: nil))
            #expect(list.width > 0 && list.height > 0 && footer.width > 0 && footer.height > 0)
            table.scrollRowToVisible(pages.count - 1)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let advanced = window.convertToScreen(table.convert(table.rect(ofRow: pages.count - 1), to: nil))
            #expect(advanced.width > 0 && advanced.height > 0)
            #expect(advanced.minY >= list.minY - 0.5 && advanced.maxY <= list.maxY + 0.5,
                    "the last row is visible inside the scrolling list")
            #expect(footer.maxY <= list.minY + 0.5, "the footer sits below the scrolling list")
            #expect(!list.intersects(footer), "the footer has its own space below the list")
            #expect(!advanced.intersects(footer), "Advanced does not sit under the footer")
        }
    }

    private func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(views)
    }
}

private struct FooterFrameProbe: NSViewRepresentable {
    static let identifier = "settings.buildNotice.frameProbe"

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        view.setAccessibilityIdentifier(Self.identifier)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
