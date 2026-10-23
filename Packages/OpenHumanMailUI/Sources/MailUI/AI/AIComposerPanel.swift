import MailFeatures
import MailTheme
import SwiftUI

public struct AIComposerPanel: View {
    @Bindable var model: AIComposerModel
    let center: AICenter?
    @FocusState private var focused: Bool
    @FocusState private var actionFocus: String?
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: AIComposerModel, center: AICenter?) {
        self.model = model
        self.center = center
    }

    public static let width: CGFloat = 480
    static let minWidth: CGFloat = 320
    static let previewMaxHeight: CGFloat = 240

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            if let version = model.currentVersion {
                comparison(version)
                    .transition(AnyTransition.opacity.combined(with: .offset(y: reduceMotion ? 0 : -4)))
            }
            box
            if let consent = model.consent {
                AIConsentView(request: consent, center: center,
                              accept: { Task { await model.acceptConsent() } }, decline: { model.declineConsent() })
            }
            if case .failed(let reason) = model.phase {
                Text(verbatim: String(localized: "Couldn't write it: \(reason)"))
                    .font(theme.typeCaption.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("composer.ai.failure")
            }
            if model.showsExamples {
                AIExamplesColumn {
                    AIExamplesPopover(use: { example in
                        model.useExample(example)
                        focused = true
                    }, close: { model.dismissExamples() })
                }
            }
            if model.currentVersion == nil, model.instruction.isEmpty, let replies = model.quickReplies,
               replies.isOffered || replies.phase != .idle {
                QuickRepliesList(model: replies, use: { model.use($0) })
                    .padding(.top, theme.space1)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: model.currentVersion?.id)
        .frame(minWidth: Self.minWidth, idealWidth: Self.width, maxWidth: .infinity, alignment: .leading)
        .background(PanelShortcuts(model: model))
        .onAppear {
            focused = true
            #if canImport(AppKit)
            if center?.pasteboard == nil { center?.pasteboard = AISystemPasteboard() }
            #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "AI: \(model.scopeTitle)"))
        .accessibilityIdentifier("composer.ai")
    }

    private var isEditBar: Bool { model.currentVersion != nil || model.scope != .notes }

    // The original and the new text, one above the other, or side by side when the panel is wide enough. The
    // arrangement comes from the width the panel is given in the same layout pass; see `AIComparisonLayout`.
    @ViewBuilder
    private func comparison(_ version: AIComposerModel.Version) -> some View {
        if model.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            versionText(version).fixedSize(horizontal: false, vertical: true)
        } else {
            AIComparisonLayout(columnSpacing: theme.space4, rowSpacing: theme.space3) {
                originalText()
                versionText(version)
                originalCut
            }
        }
    }

    private func columnTitle(_ title: String) -> some View {
        Text(verbatim: title)
            .font(theme.typeCaption.swiftUIFont)
            .fontWeight(.semibold)
            .foregroundStyle(theme.textTertiary.color)
            .accessibilityAddTraits(.isHeader)
    }

    private var originalTitle: String {
        model.scope == .selection ? String(localized: "Selected text") : String(localized: "Your draft")
    }

    // The original as many lines as the height it is given holds, the last one cut with an ellipsis
    private func originalText() -> some View {
        VStack(alignment: .leading, spacing: theme.space1) {
            columnTitle(originalTitle)
            Text(verbatim: model.original)
                .font(theme.typeReader.swiftUIFont)
                .foregroundStyle(theme.textSecondary.color)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .help(model.original)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Original text"))
        .accessibilityValue(model.original)
        .accessibilityIdentifier("composer.ai.original")
    }

    // Not shown: the original cut to the lines it keeps one above the other, which gives that height
    private var originalCut: some View {
        VStack(alignment: .leading, spacing: theme.space1) {
            columnTitle(originalTitle)
            Text(verbatim: model.original)
                .font(theme.typeReader.swiftUIFont)
                .lineLimit(AIComposerMetrics.stackedOriginalLines)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var box: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusXL, style: .continuous)
        return VStack(alignment: .leading, spacing: theme.space2) {
            HStack(alignment: .center, spacing: theme.space3) {
                if model.phase == .working {
                    Text(AIComposerModel.workingText)
                        .font(theme.typeReader.swiftUIFont)
                        .foregroundStyle(theme.textTertiary.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("composer.ai.working")
                } else if model.currentVersion != nil {
                    field(text: $model.editInstruction, placeholder: AIComposerModel.editPlaceholder,
                          submit: { model.submitEdit() })
                } else {
                    field(text: $model.instruction, placeholder: model.placeholder, submit: { model.submit() })
                }
                AISendButton(working: model.phase == .working, enabled: canSend,
                             send: { send() }, stop: { model.stop() })
            }
            .frame(minHeight: AIComposerMetrics.promptHeight)
            if isEditBar {
                AIEditActions(model: model, badge: model.currentVersion?.badge, focus: $actionFocus,
                              backToField: { actionFocus = nil; focused = true })
            }
        }
        .padding(.horizontal, theme.space4)
        .padding(.vertical, theme.space3)
        .background(shape.fill(theme.bgElevated.color))
        .overlay(shape.strokeBorder((focused ? theme.borderControl : theme.borderHairline).color,
                                    lineWidth: CGFloat(theme.borderWidthHairline)))
    }

    private var canSend: Bool {
        if model.currentVersion != nil { return true }
        return !model.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func enterActions() -> KeyPress.Result {
        guard isEditBar, model.phase != .working else { return .ignored }
        let first = model.currentVersion != nil ? "done" : model.editPresets.first?.id
        guard let first else { return .ignored }
        actionFocus = first
        return .handled
    }

    private func send() {
        if model.currentVersion != nil { model.submitEdit() } else { model.submit() }
    }

    private func field(text: Binding<String>, placeholder: String, submit: @escaping () -> Void) -> some View {
        TextField(model.scopeTitle, text: text, prompt: Text(placeholder).foregroundStyle(theme.textTertiary.color),
                  axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .font(theme.typeReader.swiftUIFont)
            .foregroundStyle(theme.textPrimary.color)
            .focused($focused)
            .onSubmit(submit)
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) {
                    text.wrappedValue += "\n"
                    return .handled
                }
                if press.modifiers.contains(.option) {
                    model.insertBelow()
                    return .handled
                }
                submit()
                return .handled
            }
            .onKeyPress(.tab, phases: .down) { press in
                if press.modifiers.contains(.option) {
                    return enterActions()
                }
                if press.modifiers.contains(.shift) {
                    model.previousVersion()
                } else if model.currentVersion != nil {
                    model.retry()
                } else if !model.instruction.isEmpty {
                    model.generate()
                } else {
                    model.quickReplies?.selectNext()
                }
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard model.currentVersion == nil, model.instruction.isEmpty, let replies = model.quickReplies,
                      !replies.options.isEmpty else { return enterActions() }
                replies.selectNext()
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard model.currentVersion == nil, model.instruction.isEmpty, let replies = model.quickReplies,
                      !replies.options.isEmpty else { return .ignored }
                replies.selectPrevious()
                return .handled
            }
            .onKeyPress(.escape) {
                model.close()
                return .handled
            }
            .accessibilityLabel(placeholder)
            .accessibilityIdentifier("composer.ai.field")
    }

    private func versionText(_ version: AIComposerModel.Version) -> some View {
        VStack(alignment: .leading, spacing: theme.space1) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space2) {
                columnTitle(String(localized: "Suggestion"))
                if let counter = model.counterText {
                    Text(verbatim: counter)
                        .font(theme.typeCaption.swiftUIFont)
                        .monospacedDigit()
                        .foregroundStyle(theme.textTertiary.color)
                        .help(String(localized: "⇧⇥ the previous version, ⇥ another one"))
                }
                Spacer(minLength: 0)
                if version.isComplete, !model.original.isEmpty {
                    Button(model.showsDiff ? String(localized: "Hide changes") : String(localized: "Show changes")) {
                        model.showsDiff.toggle()
                    }
                    .ohLinkButtonStyle()
                    .font(theme.typeCaption.swiftUIFont)
                    .help(String(localized: "Mark what the AI changed  ⌘D"))
                    .accessibilityIdentifier("composer.ai.changes")
                }
            }
            ScrollView {
                Group {
                    if model.showsDiff, version.isComplete {
                        Text(diffText)
                    } else {
                        Text(verbatim: version.text.isEmpty ? " " : version.text)
                    }
                }
                .font(theme.typeReader.swiftUIFont)
                .foregroundStyle(theme.textPrimary.color)
                .textSelection(.enabled)
                .padding(.horizontal, theme.space2)
                .padding(.vertical, theme.space1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: theme.radiusSM, style: .continuous)
                    .fill(theme.bgRowSelected.color))
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: Self.previewMaxHeight)
            if version.isSuspicious { AISuspiciousLine() }
            if version.isTruncated {
                Text("The answer was cut at its length limit.")
                    .font(theme.typeCaption.swiftUIFont)
                    .foregroundStyle(theme.textTertiary.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Suggested text"))
        .accessibilityValue(version.text)
        .accessibilityIdentifier("composer.ai.version")
    }

    private var diffText: AttributedString {
        var out = AttributedString()
        for segment in model.diff {
            var run = AttributedString(segment.text)
            switch segment.kind {
            case .kept:
                break
            case .inserted:
                run.swiftUI.underlineStyle = Text.LineStyle(pattern: .solid, color: theme.textPrimary.color)
            case .deleted:
                run.swiftUI.strikethroughStyle = Text.LineStyle(pattern: .solid, color: theme.textTertiary.color)
                run.swiftUI.foregroundColor = theme.textTertiary.color
            }
            out += run
        }
        return out
    }
}

enum AIComposerMetrics {
    static let promptHeight: CGFloat = 38
    static let fieldHeight: CGFloat = 32
    static let sendButton: CGFloat = 22
    static let sendTarget: CGFloat = 28
    static let sideBySideWidth: CGFloat = 620
    static let stackedOriginalLines = 3

    static func examplesWidth(boxWidth: CGFloat) -> CGFloat {
        min(max(boxWidth * 0.5, 280), 360)
    }
}

private struct PanelShortcuts: View {
    let model: AIComposerModel

    var body: some View {
        ZStack {
            Button("") { model.showsDiff.toggle() }.keyboardShortcut("d", modifiers: .command)
            ForEach(0..<3, id: \.self) { index in
                Button("") {
                    guard let replies = model.quickReplies, replies.options.indices.contains(index) else { return }
                    model.use(replies.options[index])
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
