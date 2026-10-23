import AppKit
import MailUI
import SwiftUI
import Testing
@testable import MailUIMac

/// The shared native helpers side by side: AppKit buttons, separator and glass pill above, SwiftUI keycaps, tags and
/// the selection plate in both styles below.
private struct NativeControlsGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                NativeKeycap("esc")
                NativeKeycap("⌘K")
                NativeKeycap("E")
                NativeTagCapsule("Finance", tint: .green, text: .primary)
                NativeTagCapsule("Travel", tint: .blue, text: .primary)
            }
            VStack(spacing: 0) {
                row("System selection", selected: true, emphasized: true, style: .system)
                row("System selection, window in the background", selected: true, emphasized: false, style: .system)
                row("Tinted selection", selected: true, emphasized: true, style: .tint)
                row("Tinted selection, window in the background", selected: true, emphasized: false, style: .tint)
                row("Not selected", selected: false, emphasized: true, style: .system)
            }
            .frame(width: 520)
            Text("A glass card")
                .padding(16)
                .frame(width: 520, alignment: .leading)
                .nativeGlassCard()
        }
        .padding(16)
    }

    private func row(_ title: String, selected: Bool, emphasized: Bool, style: NativeSelectionStyle) -> some View {
        HStack {
            Image(systemName: "tray")
            Text(title)
            Spacer()
            Text("Inbox").foregroundStyle(.secondary)
            NativeKeycap("G I")
        }
        .padding(.horizontal, 20)
        .frame(height: NativeMetrics.Overlay.paletteRowHeight)
        .nativeSelectionForeground(isSelected: selected, isEmphasized: emphasized, style: style)
        .background(NativeSelectionPlate(isSelected: selected, isEmphasized: emphasized, style: style))
    }
}

extension RenderSweepTests {
    @Test(arguments: SweepTheme.builtIns + SweepTheme.accessibility)
    func nativeControlsGallery(_ theme: SweepTheme) async throws {
        let store = theme.makeStore()
        let size = NSSize(width: 720, height: 480)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        defer { window.close() }

        let buttons = NSStackView(views: [
            NSButton.nativeIcon("chevron.up", label: "Previous match", help: "Previous match  ⇧⌘G") {},
            NSButton.nativeIcon("chevron.down", label: "Next match", help: "Next match  ⌘G") {},
            NSButton.nativeIcon("ellipsis", label: "More") {},
            NSButton.nativeIcon("chevron.down", label: "Show details", pointSize: 9, size: 16) {},
            NSButton.nativeLink("Done") {},
            NSButton.nativePlain("to Dana Ruiz, Sam Lee and Robin Example"),
        ])
        buttons.spacing = 8
        let show = NSButton(title: "Show", target: nil, action: nil)
        show.bezelStyle = .push
        show.controlSize = .small
        let pill = NativeGlassPill(views: [NSTextField(labelWithString: "3 new messages"), show])
        let separator = NativeSeparator()
        let gallery = NSHostingView(rootView: NativeControlsGallery().themed(by: store))
        gallery.translatesAutoresizingMaskIntoConstraints = false
        let column = NSStackView(views: [buttons, separator, pill, gallery])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        column.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = store.resolved.tokens.bgWindow.nsColor.cgColor
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
            separator.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32),
        ])
        window.contentView = root
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        try await sweepShoot(window, screen: "native-controls", theme: theme)
    }
}
