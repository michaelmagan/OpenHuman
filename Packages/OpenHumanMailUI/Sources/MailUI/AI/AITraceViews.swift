import MailFeatures
import MailTheme
import SwiftUI

struct AITraceFactsView: View {
    let facts: [AITraceDetail.Fact]
    var labelWidth: CGFloat = 104
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            ForEach(facts, id: \.key) { fact in
                HStack(alignment: .firstTextBaseline, spacing: theme.space3) {
                    Text(verbatim: fact.label)
                        .themeFont(theme.typeMeta)
                        .foregroundStyle(theme.textTertiary.color)
                        .frame(width: labelWidth, alignment: .leading)
                    Text(verbatim: fact.value)
                        .themeFont(theme.typeBody)
                        .foregroundStyle(theme.textPrimary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct AITraceTextBlock: View {
    let section: AITraceDetail.Section
    var expandedHeight: CGFloat = AITraceMetrics.expandedHeight
    @State private var expanded = false
    @State private var copied = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space3) {
                Text(verbatim: section.title).settingsSectionLabel(theme)
                Spacer(minLength: theme.space2)
                if section.collapses {
                    Button(expanded ? String(localized: "Show less")
                                    : String(localized: "Show all (\(section.lineCount) lines)")) { expanded.toggle() }
                        .buttonStyle(.plain)
                        .themeFont(theme.typeMeta)
                        .foregroundStyle(theme.textLink.color)
                        .accessibilityIdentifier("ai.trace.section.\(section.id).showAll")
                }
                if !section.isPlainText {
                    Button(copied ? String(localized: "Copied") : String(localized: "Copy")) { copy() }
                        .buttonStyle(.plain)
                        .themeFont(theme.typeMeta)
                        .foregroundStyle(theme.textLink.color)
                        .accessibilityIdentifier("ai.trace.section.\(section.id).copy")
                }
            }
            textBox
        }
        .accessibilityIdentifier("ai.trace.section.\(section.id)")
    }

    @ViewBuilder private var textBox: some View {
        if section.collapses, expanded {
            ScrollView(.vertical) { text }
                .frame(maxHeight: expandedHeight)
                .background(RoundedRectangle(cornerRadius: theme.radiusSM).fill(theme.bgSunken.color))
        } else {
            text
                .lineLimit(section.collapses ? AITraceDetail.Section.collapsedLines : nil)
                .background(RoundedRectangle(cornerRadius: theme.radiusSM).fill(theme.bgSunken.color))
        }
    }

    private var text: some View {
        Text(verbatim: section.text)
            .themeFont(section.isPlainText ? theme.typeBody : theme.typeMono)
            .foregroundStyle((section.id == "error" ? theme.textDanger : theme.textPrimary).color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: !section.collapses || expanded)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(theme.space3)
    }

    private func copy() {
        #if canImport(AppKit)
        AISystemPasteboard().copy(section.text)
        #endif
        copied = true
    }
}

enum AITraceMetrics {
    static let expandedHeight: CGFloat = 360
}

public struct AITraceDetailView: View {
    let detail: AITraceDetail
    var backTitle: String?
    var back: (() -> Void)?
    var delete: (() -> Void)?
    var editPrompt: ((String) -> Void)?
    @Environment(\.theme) private var theme

    public init(detail: AITraceDetail, backTitle: String? = nil, back: (() -> Void)? = nil, delete: (() -> Void)? = nil,
                editPrompt: ((String) -> Void)? = nil) {
        self.detail = detail
        self.backTitle = backTitle
        self.back = back
        self.delete = delete
        self.editPrompt = editPrompt
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.space5) {
            if let back {
                Button(action: back) {
                    Label(backTitle ?? String(localized: "Back"), systemImage: "chevron.left")
                        .themeFont(theme.typeBody)
                        .foregroundStyle(theme.textLink.color)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ai.trace.back")
            }
            HStack(alignment: .firstTextBaseline, spacing: theme.space3) {
                Text(verbatim: detail.title)
                    .themeFont(theme.typeHeadline)
                    .foregroundStyle(theme.textPrimary.color)
                Spacer(minLength: theme.space3)
                Text(detail.date, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                    .themeFont(theme.typeMeta)
                    .foregroundStyle(theme.textSecondary.color)
            }
            AITraceFactsView(facts: detail.facts)
            ForEach(detail.sections) { section in AITraceTextBlock(section: section) }
            if delete != nil || (editPrompt != nil && detail.promptName != nil) {
                HStack(spacing: theme.space3) {
                    if let editPrompt, let name = detail.promptName {
                        Button(String(localized: "Edit prompt")) { editPrompt(name) }
                            .accessibilityIdentifier("ai.trace.editPrompt")
                    }
                    Spacer(minLength: 0)
                    if let delete {
                        Button(String(localized: "Delete this trace"), role: .destructive, action: delete)
                            .accessibilityIdentifier("ai.trace.delete")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai.trace.detail")
    }
}

public struct AIWhyThisContent: View {
    let detail: AITraceDetail
    let openTrace: () -> Void
    @Environment(\.theme) private var theme

    public init(detail: AITraceDetail, openTrace: @escaping () -> Void) {
        self.detail = detail
        self.openTrace = openTrace
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.space4) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space3) {
                Text(verbatim: detail.title)
                    .themeFont(theme.typeBodyStrong)
                    .foregroundStyle(theme.textPrimary.color)
                Spacer(minLength: theme.space3)
                AIProviderBadgeView(badge: detail.badge, short: true)
            }
            AITraceFactsView(facts: detail.whyThisFacts, labelWidth: 96)
            Divider()
            AIPopoverRowButton(title: String(localized: "View trace"), symbol: "doc.text.magnifyingglass",
                               detail: String(localized: "Prompt, email text and answer as sent"),
                               action: openTrace)
                .accessibilityIdentifier("ai.whyThis.viewTrace")
        }
    }
}

struct AIPopoverRowButton: View {
    let title: String
    let symbol: String
    var detail: String?
    var enabled = true
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.space3) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title).themeFont(theme.typeBody).foregroundStyle(theme.textPrimary.color)
                    if let detail {
                        Text(verbatim: detail).themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
                    }
                }
                Spacer(minLength: theme.space2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textTertiary.color)
            }
            .padding(.horizontal, theme.space2)
            .padding(.vertical, theme.space2)
            .background(RoundedRectangle(cornerRadius: theme.radiusSM)
                .fill(hovered && enabled ? theme.bgRowHover.color : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovered = $0 }
    }
}

enum AIPopoverMetrics {
    static let width: CGFloat = 380
    static let maxHeight: CGFloat = 520
}

@MainActor
struct AITracePopoverFrame<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            content
                .padding(theme.space5)
                .frame(width: AIPopoverMetrics.width, alignment: .leading)
        }
        .frame(width: AIPopoverMetrics.width)
        .frame(maxHeight: AIPopoverMetrics.maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.bgElevated.color)
    }
}

public struct AIWhyThisPopover: View {
    let center: AICenter
    let traceID: UUID
    @State private var detail: AITraceDetail?
    @State private var showsTrace = false
    @State private var missing = false
    @Environment(\.theme) private var theme

    public init(center: AICenter, traceID: UUID) {
        self.center = center
        self.traceID = traceID
    }

    public var body: some View {
        AITracePopoverFrame {
            if let detail {
                if showsTrace {
                    AITraceDetailView(detail: detail, backTitle: String(localized: "Why this?"),
                                      back: { showsTrace = false })
                } else {
                    AIWhyThisContent(detail: detail) { showsTrace = true }
                }
            } else if missing {
                Text(AIWhyThisPopover.missingText)
                    .themeFont(theme.typeBody)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: traceID) { await load() }
        .accessibilityIdentifier("ai.whyThis")
    }

    static let missingText = String(localized: "No trace was kept for this answer. Turn traces on in Settings › AI › Activity.")

    private func load() async {
        guard let trace = try? await center.traces?.trace(traceID) else {
            missing = true
            return
        }
        detail = AITraceDetail(trace, why: await center.whyLine(for: trace))
    }
}

public struct AIWhyThisBadge: View {
    let badge: AIProviderBadge
    let center: AICenter?
    var short = false
    @State private var open = false
    @Environment(\.theme) private var theme

    public init(badge: AIProviderBadge, center: AICenter?, short: Bool = false) {
        self.badge = badge
        self.center = center
        self.short = short
    }

    public var body: some View {
        if let center, center.traces != nil, let traceID = badge.traceID {
            Button { open.toggle() } label: {
                HStack(spacing: 3) {
                    AIProviderBadgeView(badge: badge, short: short)
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textTertiary.color)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Why this? Shows the model, the prompt and the trace"))
            .accessibilityLabel(String(localized: "Why this?"))
            .accessibilityIdentifier("ai.whyThis.button")
            .popover(isPresented: $open, arrowEdge: .top) { AIWhyThisPopover(center: center, traceID: traceID) }
        } else {
            AIProviderBadgeView(badge: badge, short: short)
        }
    }
}
