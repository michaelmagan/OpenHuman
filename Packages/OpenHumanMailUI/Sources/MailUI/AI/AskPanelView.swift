import MailFeatures
import MailTheme
import SwiftUI

enum AskPanelMetrics {
    static let width: CGFloat = 640
    static let top: CGFloat = 96
    static let maxHeight: CGFloat = 560
    static let verticalMargin: CGFloat = 192
    static let answerMaxHeight: CGFloat = 240
    static let inputHeight: CGFloat = 52
    static let planLineHeight: CGFloat = 28
    static let groupHeight: CGFloat = 28
    static let rowHeight: CGFloat = 36
    static let exampleRowHeight: CGFloat = 32
    static let footerHeight: CGFloat = 32
    static let chipHeight: CGFloat = 22
    static let chipMaxWidth: CGFloat = 220
    static let rowsMaxHeight: CGFloat = 7 * rowHeight + 2 * groupHeight
}

public struct AskPanelView: View {
    @Bindable var model: AskModel
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @FocusState private var focused: Bool
    @State private var showsSearchingLine = false

    public init(model: AskModel) {
        self.model = model
    }

    public var body: some View {
        OverlayPanel(width: AskPanelMetrics.width, top: AskPanelMetrics.top, label: AskWording.title,
                     dismiss: { model.close() }) { size in
            card(maxHeight: min(AskPanelMetrics.maxHeight, max(size.height - AskPanelMetrics.verticalMargin, 240)))
        }
        .task(id: model.phase) {
            showsSearchingLine = false
            guard model.phase == .retrieving else { return }
            try? await Task.sleep(for: .milliseconds(150))
            showsSearchingLine = !Task.isCancelled && model.phase == .retrieving
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .done, let text = model.readyAnnouncement { AccessibilityNotification.Announcement(text).post() }
        }
    }

    private func card(maxHeight: CGFloat) -> some View {
        let rowsHeight = rowsListHeight
        let chrome = AskPanelMetrics.inputHeight + AskPanelMetrics.planLineHeight + AskPanelMetrics.footerHeight + 48
        let answerMax = max(80, min(AskPanelMetrics.answerMaxHeight, maxHeight - chrome - rowsHeight))
        return VStack(alignment: .leading, spacing: 0) {
            input
            Divider()
            planArea
            content(answerMax: answerMax)
            if showsExamples { examples }
            if !model.rows.isEmpty {
                Divider()
                rowsList(height: rowsHeight)
            }
            Divider()
            footer
        }
        .frame(maxHeight: maxHeight, alignment: .top)
        .onAppear {
            focused = true
            #if canImport(AppKit)
            if model.aiCenter?.pasteboard == nil { model.aiCenter?.pasteboard = AISystemPasteboard() }
            #endif
        }
    }

    private var input: some View {
        OverlayFieldRow(symbol: "sparkle", symbolColor: theme.textAI.color) {
            TextField(AskWording.title, text: $model.question, prompt: Text(AskWording.placeholder))
                .overlayField()
                .focused($focused)
                .onSubmit { model.submit() }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) {
                        model.showAsList()
                        return .handled
                    }
                    if press.modifiers.contains(.option) {
                        model.ask(followUp: false)
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.tab, phases: .down) { press in
                    model.cycleScope(by: press.modifiers.contains(.shift) ? -1 : 1)
                    return .handled
                }
                .onKeyPress(.upArrow) { model.moveUp() ? .handled : .ignored }
                .onKeyPress(.downArrow) { model.moveDown() ? .handled : .ignored }
                .onKeyPress(.escape) {
                    model.escape()
                    return .handled
                }
                .onKeyPress(KeyEquivalent("j"), phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    model.close()
                    return .handled
                }
                .onKeyPress(KeyEquivalent("c"), phases: .down) { press in
                    guard press.modifiers.contains(.command), model.canCopyAnswer else { return .ignored }
                    model.copyAnswer()
                    return .handled
                }
                .accessibilityLabel(AskWording.placeholder)
        } trailing: {
            if !model.scopes.isEmpty { scopeChip }
            OverlayShortcutHint("esc")
        }
    }

    private var scopeChip: some View {
        Menu {
            ForEach(model.scopes, id: \.self) { scope in
                Button(model.title(of: scope)) { model.select(scope) }
            }
        } label: {
            Text(verbatim: model.scopeTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: AskPanelMetrics.chipMaxWidth)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel(String(localized: "Scope: \(model.scopeTitle)"))
        .accessibilityHint(String(localized: "Tab changes it"))
    }

    @ViewBuilder
    private var planArea: some View {
        let text = planText
        if !text.isEmpty || model.isWorking {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: text)
                    .font(.system(size: NativeMetrics.Text.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, OverlayMetrics.panelInsetX)
                    .frame(maxWidth: .infinity, minHeight: AskPanelMetrics.planLineHeight, alignment: .leading)
                if model.isWorking { progress }
            }
        }
    }

    private var planText: String {
        if let line = model.planLine, model.phase != .planning { return line }
        switch model.phase {
        case .planning: return AskWording.planning
        case .retrieving: return showsSearchingLine ? AskWording.searching : ""
        default: return ""
        }
    }

    @ViewBuilder
    private var progress: some View {
        if reduceMotion {
            VStack(alignment: .leading, spacing: theme.space1) {
                ProgressView(value: 0.3)
                    .progressViewStyle(.linear)
                    .tint(theme.textAI.color)
                Text(AskWording.working)
                    .font(.system(size: NativeMetrics.Text.caption))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, OverlayMetrics.panelInsetX)
            }
            .accessibilityElement(children: .combine)
        } else {
            AIProgressLine()
        }
    }

    private func content(answerMax: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            if let asked = model.askedAtText { caption(asked) }
            if model.isSuspicious { suspiciousStrip }
            if !model.answer.isEmpty { answer(maxHeight: answerMax) }
            if model.isTruncated { caption(AskWording.truncated) }
            if model.phase == .stopped { caption(AskWording.stopped) }
            if let status = model.statusText { statusLine(status) }
            if let consent = model.consent {
                AIConsentView(request: consent, center: model.aiCenter,
                              accept: { Task { await model.acceptConsent() } }, decline: { model.declineConsent() })
            }
        }
        .padding(.horizontal, OverlayMetrics.panelInsetX)
        .padding(.vertical, hasContent ? theme.space3 : 0)
    }

    private var hasContent: Bool {
        model.askedAtText != nil || model.isSuspicious || !model.answer.isEmpty || model.statusText != nil
            || model.consent != nil || model.phase == .stopped
    }

    private var showsExamples: Bool {
        model.phase == .idle && model.answer.isEmpty && model.question.isEmpty && model.statusText == nil
    }

    private func answer(maxHeight: CGFloat) -> some View {
        ScrollView {
            Text(verbatim: model.answer)
                .font(.system(size: NativeMetrics.Text.body))
                .foregroundStyle(answerStyle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(String(localized: "Answer"))
        .accessibilityValue(model.answer)
    }

    private var answerStyle: HierarchicalShapeStyle {
        if model.phase == .stopped { return .tertiary }
        if model.phase == .done, model.sources.isEmpty { return .secondary }
        return .primary
    }

    private var suspiciousStrip: some View {
        GroupBox {
            Label {
                Text(AskWording.suspicious)
                    .font(.system(size: NativeMetrics.Text.body))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: NativeMetrics.Text.caption))
            .foregroundStyle(.secondary)
    }

    private func statusLine(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            Text(verbatim: text)
                .font(.system(size: NativeMetrics.Text.body))
                .foregroundStyle(statusIsError ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .fixedSize(horizontal: false, vertical: true)
            #if os(macOS)
            if model.phase == .failed(.aiOff) {
                Button(AskWording.openSettings) {
                    model.close()
                    openSettings()
                }
                .ohLinkButtonStyle()
                .font(.system(size: NativeMetrics.Text.body))
            }
            #endif
        }
    }

    private var statusIsError: Bool {
        guard case .failed(let failure) = model.phase else { return false }
        switch failure {
        case .aiOff, .unavailable, .onDeviceOnly, .needsConsent: return false
        default: return true
        }
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(AskWording.examples, id: \.self) { example in
                OverlayRow(isSelected: false, height: AskPanelMetrics.exampleRowHeight) {
                    model.question = example
                    model.ask(followUp: false)
                } label: {
                    Text(verbatim: example)
                        .font(.system(size: NativeMetrics.Text.body))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.bottom, OverlayMetrics.listPaddingY)
    }

    private enum Item: Identifiable {
        case header(String)
        case row(Int, AskModel.Row)

        var id: String {
            switch self {
            case .header(let title): "header.\(title)"
            case .row(_, let row): row.id
            }
        }
    }

    private var items: [Item] {
        var out: [Item] = []
        var group = ""
        for (index, row) in model.rows.enumerated() {
            let title: String
            switch row {
            case .source: title = AskWording.sources
            case .otherMatch, .showMore: title = AskWording.alsoMatched
            case .olderMail: title = ""
            }
            if title != group {
                if !title.isEmpty { out.append(.header(title)) }
                group = title
            }
            out.append(.row(index, row))
        }
        return out
    }

    private var rowsListHeight: CGFloat {
        let headers = items.filter { if case .header = $0 { true } else { false } }.count
        let content = CGFloat(model.rows.count) * AskPanelMetrics.rowHeight + CGFloat(headers) * AskPanelMetrics.groupHeight
            + OverlayMetrics.listPaddingY * 2
        return min(content, AskPanelMetrics.rowsMaxHeight)
    }

    private func rowsList(height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        switch item {
                        case .header(let title):
                            OverlaySectionHeader(title: title)
                        case .row(let index, let row):
                            rowView(row, index: index).id(row.id)
                        }
                    }
                }
                .padding(.vertical, OverlayMetrics.listPaddingY)
            }
            .frame(height: height)
            .onChange(of: model.cursor) { _, cursor in
                if let cursor, model.rows.indices.contains(cursor) { proxy.scrollTo(model.rows[cursor].id) }
            }
        }
    }

    private func rowView(_ row: AskModel.Row, index: Int) -> some View {
        let isCursor = model.cursor == index
        let enabled = row != .olderMail || model.olderMailEnabled
        return OverlayRow(isSelected: isCursor, height: AskPanelMetrics.rowHeight) {
            model.moveCursor(to: index)
            model.activate(row)
        } label: {
            HStack(spacing: OverlayMetrics.rowSpacing) {
                switch row {
                case .source(let source), .otherMatch(let source):
                    sourceLabel(source)
                case .showMore(let count):
                    plainRow(AskWording.showMore(count), symbol: "chevron.down", enabled: true)
                case .olderMail:
                    plainRow(model.olderMailText ?? "", symbol: "magnifyingglass", enabled: enabled)
                }
            }
        }
        .disabled(!enabled)
        .accessibilityLabel(model.spokenLabel(row))
    }

    @ViewBuilder
    private func sourceLabel(_ source: AskSource) -> some View {
        OverlayRowSymbol(symbol: "envelope")
        Text(verbatim: source.sender)
            .font(.system(size: NativeMetrics.Text.body))
            .foregroundStyle(.primary)
            .lineLimit(1)
        Text(verbatim: source.subject)
            .font(.system(size: NativeMetrics.Text.body))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        Spacer(minLength: OverlayMetrics.rowSpacing)
        Text(verbatim: model.dateText(source))
            .font(.system(size: NativeMetrics.Text.secondary))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func plainRow(_ text: String, symbol: String, enabled: Bool) -> some View {
        let style = enabled ? AnyShapeStyle(TintShapeStyle.tint) : AnyShapeStyle(HierarchicalShapeStyle.tertiary)
        Image(systemName: symbol)
            .font(.system(size: OverlayMetrics.rowSymbolSize))
            .foregroundStyle(style)
            .frame(width: OverlayMetrics.symbolColumn, height: OverlayMetrics.symbolColumn)
            .accessibilityHidden(true)
        Text(verbatim: text)
            .font(.system(size: NativeMetrics.Text.body))
            .foregroundStyle(style)
            .lineLimit(1)
        Spacer(minLength: 0)
    }

    private var footer: some View {
        OverlayFooter {
            Text(verbatim: model.footer)
                .lineLimit(1)
            Spacer(minLength: OverlayMetrics.rowSpacing)
            if let badge = model.badge { AIWhyThisBadge(badge: badge, center: model.aiCenter) }
        }
    }
}
