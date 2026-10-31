import MailFeatures
import MailTheme
import SwiftUI

public struct OverlayHostView: View {
    let center: OverlayCenter
    @Environment(\.theme) private var theme

    public init(center: OverlayCenter) {
        self.center = center
    }

    public var body: some View {
        let tokens = theme.tokens
        let enter = tokens.motion(tokens.motionEnterFast), exit = tokens.motion(tokens.motionExitFast)
        ZStack {
            if center.isShowing {
                overlay
                    .transition(.asymmetric(insertion: AnyTransition.opacity.animation(enter.animation),
                                            removal: AnyTransition.opacity.animation(exit.animation)))
            }
        }
        .animation(enter.animation, value: center.isShowing)
    }

    @ViewBuilder private var overlay: some View {
        switch center.overlay {
        case .none:
            EmptyView()
        case .palette(let palette):
            lifecycle(PaletteView(palette: palette)).id(center.showing)
        case .shortcuts(let model):
            lifecycle(ShortcutHelpView(model: model) { center.dismiss() }).id(center.showing)
        case .time(let model):
            lifecycle(TimePickerView(model: model) { center.dismiss() }).id(center.showing)
        case .label(let model):
            lifecycle(LabelPickerView(model: model) { center.dismiss() }).id(center.showing)
        case .zero(let model):
            lifecycle(GetMeToZeroView(model: model) { center.dismiss() }).id(center.showing)
        case .ask(let model):
            lifecycle(AskPanelView(model: model)).id(center.showing)
        case .batchSend(let model):
            lifecycle(BatchSendView(model: model) { center.dismiss() }).id(center.showing)
        }
    }

    private func lifecycle(_ view: some View) -> some View {
        view
            .onAppear { center.overlayAppeared() }
            .onDisappear { center.overlayDisappeared() }
    }
}
