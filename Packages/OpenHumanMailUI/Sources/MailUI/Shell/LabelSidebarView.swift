import MailFeatures
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The sidebar for a layout without a split view: `MailSidebar` at its ideal width on the sidebar material, with a
/// separator on its trailing edge. In a `NavigationSplitView`, use `MailSidebar` itself.
public struct LabelSidebarView: View {
    let router: AppRouter

    public init(router: AppRouter) {
        self.router = router
    }

    public var body: some View {
        MailSidebar(router: router)
            .scrollContentBackground(.hidden)
            .frame(width: NativeMetrics.Sidebar.idealWidth)
            .frame(maxHeight: .infinity)
            .background { SidebarMaterial() }
            .overlay(alignment: .trailing) { Divider() }
    }
}

#if os(macOS)
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
#else
private struct SidebarMaterial: View {
    var body: some View { Rectangle().fill(.bar) }
}
#endif
