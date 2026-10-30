import MailFeatures
import MailTheme
import SwiftUI

struct AISendButton: View {
    let working: Bool
    let enabled: Bool
    let send: () -> Void
    let stop: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button { working ? stop() : send() } label: {
            ZStack {
                Circle().fill((working || enabled ? theme.textSecondary : theme.bgRowSelected).color)
                Image(systemName: working ? "stop.fill" : "arrow.up")
                    .font(.system(size: working ? 8 : 11, weight: .bold))
                    .foregroundStyle((working || enabled ? theme.bgElevated : theme.textTertiary).color)
            }
            .frame(width: AIComposerMetrics.sendButton, height: AIComposerMetrics.sendButton)
            .frame(width: AIComposerMetrics.sendTarget, height: AIComposerMetrics.sendTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!working && !enabled)
        .help(working ? String(localized: "Stop") : String(localized: "Run  ↵"))
        .accessibilityLabel(working ? String(localized: "Stop") : String(localized: "Run"))
        .accessibilityIdentifier(working ? "composer.ai.stop" : "composer.ai.send")
    }
}

struct AIEditActions: View {
    let model: AIComposerModel
    let badge: AIProviderBadge?
    var focus: FocusState<String?>.Binding
    var backToField: () -> Void = {}
    @Environment(\.theme) private var theme

    var order: [String] {
        var ids: [String] = []
        if model.currentVersion != nil { ids += ["done", "retry", "dismiss"] }
        ids += model.editPresets.map(\.id)
        if !model.morePresets.isEmpty { ids.append("more") }
        return ids
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        let ids = order
        guard !ids.isEmpty else { return .ignored }
        let at = focus.wrappedValue.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        let next = at + delta
        if next < 0 || next >= ids.count { backToField(); return .handled }
        focus.wrappedValue = ids[next]
        return .handled
    }

    // The ways to change the text on one line; with a suggestion, Accept, Retry and Dismiss on the last line, with
    // the model and the ratings at its end, so no row has to share its width with them
    var body: some View {
        VStack(alignment: .leading, spacing: theme.space1) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: theme.space1) {
                    ForEach(model.editPresets) { preset in
                        action(preset.title, id: preset.id) { model.refine(preset) }
                    }
                    if !model.morePresets.isEmpty { more }
                }
            }
            .frame(height: AIComposerMetrics.fieldHeight)
            if model.currentVersion != nil {
                HStack(spacing: theme.space1) {
                    doneButton
                    action(String(localized: "Retry"), id: "retry") { model.retry() }
                    action(String(localized: "Dismiss"), id: "dismiss") { model.close() }
                    Spacer(minLength: theme.space3)
                    if let badge {
                        AIComposerModelButton(model: model, badge: badge)
                            .fixedSize()
                            .padding(.horizontal, theme.space1)
                    }
                    Rectangle().fill(theme.borderHairline.color).frame(width: theme.borderWidthHairline, height: 18)
                        .accessibilityHidden(true)
                    thumb(up: true)
                    thumb(up: false)
                }
                .frame(height: AIComposerMetrics.fieldHeight)
            }
        }
        .disabled(model.phase == .working)
        .onKeyPress(.rightArrow) { step(1) }
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.upArrow) { backToField(); return .handled }
        .onKeyPress(.escape) { backToField(); return .handled }
        .onKeyPress(.tab, phases: .down) { press in step(press.modifiers.contains(.shift) ? -1 : 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Edit the text"))
    }

    private var doneButton: some View {
        Button { model.replace() } label: {
            HStack(spacing: theme.space1) {
                Text("Accept")
                    .font(theme.typeBodyStrong.swiftUIFont)
                Text(verbatim: "↵")
                    .font(theme.typeCaption.swiftUIFont)
                    .opacity(0.7)
                    .accessibilityHidden(true)
            }
            .foregroundStyle((model.canApply ? theme.textPrimary : theme.textDisabled).color)
            .padding(.horizontal, theme.space3)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: theme.radiusSM, style: .continuous)
                .fill(theme.bgRowSelected.color))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusSM, style: .continuous)
                .strokeBorder((model.canApply ? theme.borderControl : theme.borderHairline).color,
                              lineWidth: CGFloat(theme.borderWidthHairline)))
            .contentShape(RoundedRectangle(cornerRadius: theme.radiusSM, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!model.canApply)
        .help(String(localized: "Put this text in the draft  ↵"))
        .accessibilityLabel(String(localized: "Accept"))
        .focusable()
        .focused(focus, equals: "done")
        .onKeyPress(characters: .init(charactersIn: " \r")) { _ in
            guard model.canApply else { return .ignored }
            model.replace()
            return .handled
        }
        .accessibilityIdentifier("composer.ai.done")
    }

    private func action(_ title: String, id: String, run: @escaping () -> Void) -> some View {
        AITextAction(title: title, run: run)
            .focusable()
            .focused(focus, equals: id)
            .onKeyPress(characters: .init(charactersIn: " \r")) { _ in run(); return .handled }
            .accessibilityIdentifier("composer.ai.action.\(id)")
    }

    private var more: some View {
        Menu {
            ForEach(model.morePresets) { preset in
                Button(preset.title) { model.refine(preset) }
                    .disabled(model.isDisabled(preset))
                    .help(model.isDisabled(preset) ? (model.voiceRefusal ?? "") : "")
            }
        } label: {
            HStack(spacing: 2) {
                Text("Rewrite").font(theme.typeBody.swiftUIFont)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(theme.textSecondary.color)
        }
        .ohBorderlessMenuStyle()
        .menuIndicator(.hidden)
        .tint(theme.textSecondary.color)
        .fixedSize()
        .padding(.horizontal, theme.space2)
        .focusable()
        .focused(focus, equals: "more")
        .accessibilityLabel(String(localized: "Rewrite"))
        .accessibilityIdentifier("composer.ai.action.more")
    }

    private func thumb(up: Bool) -> some View {
        let chosen = model.currentVersion?.rating == up
        let symbol = up ? (chosen ? "hand.thumbsup.fill" : "hand.thumbsup") : (chosen ? "hand.thumbsdown.fill" : "hand.thumbsdown")
        return Button { model.rate(up: up) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle((chosen ? theme.textPrimary : theme.textSecondary).color)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(up ? String(localized: "Good result (kept on this Mac)") : String(localized: "Bad result (kept on this Mac)"))
        .accessibilityLabel(up ? String(localized: "Good result") : String(localized: "Bad result"))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

private struct AITextAction: View {
    let title: String
    let run: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: run) {
            Text(verbatim: title)
                .font(theme.typeBody.swiftUIFont)
                .foregroundStyle((hovered ? theme.textPrimary : theme.textSecondary).color)
                .lineLimit(1)
                .padding(.horizontal, theme.space2)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: theme.radiusSM)
                    .fill(hovered ? theme.bgRowHover.color : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

struct AIExamplesPopover: View {
    // nil: the width it is given
    var width: CGFloat? = nil
    let use: (String) -> Void
    let close: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            HStack {
                Text("Example:")
                    .font(theme.typeBodyStrong.swiftUIFont)
                    .foregroundStyle(theme.textPrimary.color)
                Spacer(minLength: theme.space3)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textTertiary.color)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Close the examples"))
                .accessibilityLabel(String(localized: "Close the examples"))
            }
            ForEach(AIComposerModel.examples, id: \.self) { example in
                Button { use(example) } label: {
                    Text(verbatim: example)
                        .font(theme.typeBody.swiftUIFont)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(String(localized: "Puts these words in the field. Nothing runs until you press Return."))
            }
            Text("Hit Shift+Enter to add a new line")
                .font(theme.typeBodyStrong.swiftUIFont)
                .foregroundStyle(theme.textPrimary.color)
                .padding(.top, theme.space1)
        }
        .padding(theme.space4)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgElevated.color))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusMD)
            .strokeBorder(theme.borderHairline.color, lineWidth: CGFloat(theme.borderWidthHairline)))
        .themeShadow(theme.shadow1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Examples"))
        .accessibilityIdentifier("composer.ai.examples")
    }
}
