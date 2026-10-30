import MailActions
import MailFeatures
import MailTheme
import SwiftUI

public struct FormatBarView: View {
    public enum Style: Sendable {
        case floating
        case inline
    }

    let state: ComposeFormatState
    let style: Style
    let action: (ComposeFormatCommand) -> Void
    @Environment(\.theme) private var theme

    public init(state: ComposeFormatState, style: Style, action: @escaping (ComposeFormatCommand) -> Void) {
        self.state = state
        self.style = style
        self.action = action
    }

    public var body: some View {
        HStack(spacing: FormatBarMetrics.spacing) {
            ForEach(Array(ComposeFormatCommand.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Rectangle()
                        .fill(theme.borderHairline.color)
                        .frame(width: theme.borderWidthHairline, height: FormatBarMetrics.separatorHeight)
                        .padding(.horizontal, FormatBarMetrics.spacing)
                        .accessibilityHidden(true)
                }
                ForEach(group) { command in button(command) }
            }
        }
        .padding(.horizontal, style == .floating ? FormatBarMetrics.floatingPadding : FormatBarMetrics.inlinePadding)
        .frame(height: FormatBarMetrics.height)
        .modifier(FormatBarSurface(floating: style == .floating))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Formatting")
        .accessibilityIdentifier(style == .floating ? "composer.formatBar.floating" : "composer.formatBar")
    }

    private func button(_ command: ComposeFormatCommand) -> some View {
        let active = state.isActive(command)
        return Button { action(command) } label: {
            Image(systemName: Self.symbol(command))
                .font(.system(size: FormatBarMetrics.glyph, weight: .medium))
        }
        .buttonStyle(FormatButtonStyle(active: active))
        .modifier(FormatButtonTip(command: command, inline: style == .inline))
        .accessibilityLabel(command.title)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("composer.format.\(command.rawValue)")
    }

    static func symbol(_ command: ComposeFormatCommand) -> String {
        switch command {
        case .bold: "bold"
        case .italic: "italic"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .link: "link"
        case .bulletList: "list.bullet"
        case .numberedList: "list.number"
        case .quote: "text.quote"
        case .clearFormatting: "eraser"
        }
    }
}

public enum FormatBarMetrics {
    public static let height: CGFloat = 32
    static let button: CGFloat = 28
    static let spacing: CGFloat = 2
    static let separatorHeight: CGFloat = 16
    static let floatingPadding: CGFloat = 8
    static let inlinePadding: CGFloat = 4
    static let plateRadius: CGFloat = 7
    static let glyph: CGFloat = 13
}

struct FormatButtonStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        FormatButtonBody(configuration: configuration, active: active)
    }

    enum Plate: Equatable {
        case none
        case hovered
        case pressed
        case active
    }

    static func plate(active: Bool, hovered: Bool, pressed: Bool) -> Plate {
        if pressed { return .pressed }
        if active { return .active }
        return hovered ? .hovered : .none
    }

    private struct FormatButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        @Environment(\.theme) private var theme
        @State private var hovered = false

        var body: some View {
            let plate = FormatButtonStyle.plate(active: active, hovered: hovered, pressed: configuration.isPressed)
            let shape = RoundedRectangle(cornerRadius: FormatBarMetrics.plateRadius, style: .continuous)
            configuration.label
                .foregroundStyle((active ? theme.accentText : hovered ? theme.textPrimary : theme.textSecondary).color)
                .frame(width: FormatBarMetrics.button, height: FormatBarMetrics.button)
                .background {
                    switch plate {
                    case .none: Color.clear
                    case .hovered: shape.fill(theme.bgRowHover.color)
                    case .pressed: shape.fill(theme.bgRowSelected.color)
                    case .active: shape.fill(theme.accentSubtle.color)
                    }
                }
                .contentShape(shape)
                .onHover { hovered = $0 }
        }
    }
}

private struct FormatBarSurface: ViewModifier {
    let floating: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if floating {
            content.glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            // In the card the bar sits in the same capsule as the tools of the Send bar, like a toolbar group
            content.composerToolGroupSurface()
        }
    }
}

private struct FormatButtonTip: ViewModifier {
    let command: ComposeFormatCommand
    let inline: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if inline {
            let tip = ShortcutTip(title: command.title, keycaps: ShortcutTip.keycaps(symbols: command.shortcut))
            content.shortcutTip(tip).accessibilityHint(tip.spokenDetail)
        } else {
            content.help(command.help)
        }
    }
}
