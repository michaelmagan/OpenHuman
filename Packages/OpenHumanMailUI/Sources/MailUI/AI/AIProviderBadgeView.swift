import MailFeatures
import MailTheme
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

public struct AIProviderBadgeView: View {
    let badge: AIProviderBadge
    var short = false
    @Environment(\.theme) private var theme

    public init(badge: AIProviderBadge, short: Bool = false) {
        self.badge = badge
        self.short = short
    }

    public var body: some View {
        HStack(spacing: theme.space2) {
            Image(systemName: badge.symbol).font(.system(size: 10))
            Text(verbatim: short ? badge.short : badge.title).font(theme.typeCaption.swiftUIFont)
        }
        .foregroundStyle((badge.leavesMac ? theme.textWarning : theme.textTertiary).color)
        .help(badge.help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(badge.help)
    }
}

struct AISuspiciousLine: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Label(AIWording.suspicious, systemImage: "exclamationmark.triangle")
            .font(theme.typeCaption.swiftUIFont)
            .foregroundStyle(theme.textWarning.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct AIProgressLine: View {
    @Environment(\.theme) private var theme
    @State private var phase: CGFloat = 0

    var body: some View {
        let loop = theme.tokens.motion(theme.motionProgress, loop: true)
        GeometryReader { proxy in
            let width = proxy.size.width
            Capsule()
                .fill(theme.textAI.color)
                .frame(width: width * 0.3, height: 2)
                .offset(x: loop.loops ? -width * 0.3 + phase * width * 1.3 : 0)
        }
        .frame(height: 2)
        .clipped()
        .onAppear {
            guard loop.loops else { return }
            withAnimation(.linear(duration: loop.seconds).repeatForever(autoreverses: false)) { phase = 1 }
        }
        .accessibilityLabel(String(localized: "Working"))
    }
}

#if canImport(AppKit)
@MainActor
final class AISystemPasteboard: TextPasteboard {
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
#endif
