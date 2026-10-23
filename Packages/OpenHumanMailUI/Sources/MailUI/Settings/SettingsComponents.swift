import MailTheme
import SwiftUI

public enum SettingsMetrics {
    public static let windowWidth: CGFloat = NativeMetrics.Settings.minWidth
    public static let windowHeight: CGFloat = NativeMetrics.Settings.minHeight
    /// The page list's starting and narrowest width: the longest page title fits beside its symbol at the large
    /// sidebar size. Dragging the divider widens it up to `sidebarMaxWidth`.
    public static let sidebarWidth: CGFloat = 220
    public static let sidebarMaxWidth: CGFloat = 320
    public static let sidebarIconSize: CGFloat = 14
    public static let contentMaxWidth: CGFloat = 640
    public static let rowMinHeight: CGFloat = NativeMetrics.Settings.rowMinHeight
    public static let compactRowMinHeight: CGFloat = NativeMetrics.Settings.compactRowMinHeight
}

public enum SettingsTone: Sendable, Hashable {
    case secondary, warning, danger, success

    func color(_ theme: ResolvedTheme) -> Color {
        switch self {
        case .secondary: Color.secondary
        case .warning: theme.textWarning.color
        case .danger: theme.textDanger.color
        case .success: theme.textSuccess.color
        }
    }
}

/// A settings page: a grouped `Form` whose sections are `SettingsSection`s. The page title is the window title.
/// `.fill` is for pages that lay out their own full-height content (a list beside an editor).
public struct SettingsPageScaffold<Content: View>: View {
    public enum Layout: Sendable { case column, fill }

    let title: String
    let layout: Layout
    let content: Content
    @Environment(\.theme) private var theme

    public init(title: String, layout: Layout = .column, @ViewBuilder content: () -> Content) {
        self.title = title
        self.layout = layout
        self.content = content()
    }

    public var body: some View {
        switch layout {
        case .column:
            Form { content }
                .formStyle(.grouped)
                .scrollIndicatorsFlash(onAppear: true)
                .navigationTitle(title)
        case .fill:
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(theme.space6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(title)
        }
    }
}

/// One group of rows. Draws nothing when it has no rows, so a section whose rows are all switched off disappears with
/// its title and footnote.
public struct SettingsSection<Content: View>: View {
    let title: String?
    let detail: String?
    let footnote: String?
    let compact: Bool
    let content: Content
    @Environment(\.theme) private var theme

    public init(_ title: String? = nil, detail: String? = nil, footnote: String? = nil, compact: Bool = false,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.footnote = footnote
        self.compact = compact
        self.content = content()
    }

    public var body: some View {
        Group(subviews: content.environment(\.settingsCompactRows, compact)) { rows in
            if !rows.isEmpty {
                Section {
                    ForEach(rows) { row in row }
                } header: {
                    header
                } footer: {
                    if let footnote { SettingsFootnote(footnote) }
                }
            }
        }
    }

    @ViewBuilder private var header: some View {
        if title != nil || detail != nil {
            VStack(alignment: .leading, spacing: theme.space1) {
                if let title {
                    Text(title).accessibilityAddTraits(.isHeader)
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: NativeMetrics.Text.secondary))
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var settingsCompactRows = false
}

/// A labelled row: the title (with an optional detail and status line) on the leading side and the control on the
/// trailing side, as `LabeledContent` in the grouped form. `stacked` puts a wide control under the text.
public struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    let status: String?
    let statusTone: SettingsTone
    let alignment: VerticalAlignment
    let labelsControl: Bool
    let stacked: Bool
    let control: Control
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.settingsCompactRows) private var compact

    public init(_ title: String, detail: String? = nil, status: String? = nil, statusTone: SettingsTone = .secondary,
                alignment: VerticalAlignment = .center, labelsControl: Bool = false, stacked: Bool = false,
                @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.status = status
        self.statusTone = statusTone
        self.alignment = alignment
        self.labelsControl = labelsControl
        self.stacked = stacked
        self.control = control()
    }

    public var body: some View {
        arranged
            .frame(minHeight: compact ? SettingsMetrics.compactRowMinHeight : SettingsMetrics.rowMinHeight)
    }

    // Why: a wide control beside the title squeezes the title until it wraps a letter per line
    @ViewBuilder private var arranged: some View {
        if stacked {
            VStack(alignment: .leading, spacing: theme.space3) {
                text
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(RowTextAccessibility(hidden: labelsControl))
                accessibleControl
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if alignment == .center {
            LabeledContent {
                accessibleControl.fixedSize(horizontal: true, vertical: false)
            } label: {
                text.modifier(RowTextAccessibility(hidden: labelsControl))
            }
        } else {
            LabeledContent {
                accessibleControl.fixedSize(horizontal: true, vertical: false)
            } label: {
                text.modifier(RowTextAccessibility(hidden: labelsControl))
            }
            .labeledContentStyle(AlignedRowStyle(alignment: alignment, spacing: theme.space6))
        }
    }

    private var accessibleControl: some View {
        control.modifier(RowControlAccessibility(label: labelsControl ? title : nil, hint: labelsControl ? spokenDetail : nil))
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: theme.space1) {
            Text(title).foregroundStyle(isEnabled ? HierarchicalShapeStyle.primary : .tertiary)
            if let detail {
                Text(detail)
                    .font(.system(size: NativeMetrics.Text.secondary))
                    .foregroundStyle(.secondary)
            }
            if let status {
                Text(status)
                    .font(.system(size: NativeMetrics.Text.secondary))
                    .foregroundStyle(statusTone.color(theme))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var spokenDetail: String? {
        let lines = [detail, status].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}

private struct AlignedRowStyle: LabeledContentStyle {
    let alignment: VerticalAlignment
    let spacing: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: alignment, spacing: spacing) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            configuration.content
        }
    }
}

extension SettingsRow where Control == EmptyView {
    public init(_ title: String, detail: String? = nil, status: String? = nil, statusTone: SettingsTone = .secondary) {
        self.init(title, detail: detail, status: status, statusTone: statusTone) { EmptyView() }
    }
}

extension SettingsRow where Control == SettingsSwitch {
    public init(_ title: String, detail: String? = nil, status: String? = nil, statusTone: SettingsTone = .secondary,
                isOn: Binding<Bool>) {
        self.init(title, detail: detail, status: status, statusTone: statusTone, labelsControl: true) {
            SettingsSwitch(title: title, isOn: isOn)
        }
    }
}

extension SettingsRow {
    public init<Value: Hashable, Options: View>(_ title: String, detail: String? = nil, status: String? = nil,
                                                statusTone: SettingsTone = .secondary, selection: Binding<Value>,
                                                @ViewBuilder options: () -> Options)
        where Control == SettingsMenu<Value, Options> {
        let menu = SettingsMenu(title: title, selection: selection, options: options())
        self.init(title, detail: detail, status: status, statusTone: statusTone, labelsControl: true) { menu }
    }
}

public struct SettingsSwitch: View {
    let title: String
    @Binding var isOn: Bool

    public var body: some View {
        Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden()
    }
}

public struct SettingsMenu<Value: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Value
    let options: Options

    public var body: some View {
        Picker(title, selection: $selection) { options }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
    }
}

private struct RowTextAccessibility: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if hidden {
            content.accessibilityHidden(true)
        } else {
            content.accessibilityElement(children: .combine)
        }
    }
}

private struct RowControlAccessibility: ViewModifier {
    let label: String?
    let hint: String?

    func body(content: Content) -> some View {
        if let label, let hint {
            content.accessibilityLabel(Text(label)).accessibilityHint(Text(hint))
        } else if let label {
            content.accessibilityLabel(Text(label))
        } else {
            content
        }
    }
}

extension View {
    /// For a row that is not a `SettingsRow` (a picker, an editor, a list): fills the row's width.
    public func settingsRowPadding() -> some View {
        modifier(SettingsRowPadding())
    }
}

private struct SettingsRowPadding: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(.vertical, theme.space1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Sections hosted together, for example by an app-provided page part. The sections stay separate sections of the
/// page's form. A modifier on the stack applies to each section, so put a one-off `.task` or dialog on one section.
public struct SettingsSectionStack<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
    }
}

public struct SettingsFootnote: View {
    let text: String
    let tone: SettingsTone
    @Environment(\.theme) private var theme

    public init(_ text: String, tone: SettingsTone = .secondary) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Text(text)
            .font(.system(size: NativeMetrics.Text.secondary))
            .foregroundStyle(tone.color(theme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    public func settingsTextField() -> some View {
        textFieldStyle(.roundedBorder)
    }
}

extension Text {
    public func settingsPrompt(_ theme: ResolvedTheme) -> Text {
        foregroundStyle(theme.textTertiary.color)
    }
}

// Why: a fixed width keeps neighbouring fields aligned and stops one from widening as it is typed in
struct SettingsTextArea: View {
    static let width: CGFloat = 320

    let title: String
    let prompt: String
    @Binding var text: String
    @Environment(\.theme) private var theme

    var body: some View {
        TextField(title, text: $text, prompt: Text(verbatim: prompt).settingsPrompt(theme), axis: .vertical)
            .lineLimit(2...5)
            .labelsHidden()
            .settingsTextField()
            .frame(width: Self.width)
    }
}

struct SettingsErrorLine: View {
    let text: String?

    var body: some View {
        if let text { SettingsFootnote(text, tone: .danger) }
    }
}

typealias SettingsNote = SettingsFootnote

extension View {
    func settingsSectionLabel(_ theme: ResolvedTheme) -> some View {
        font(.system(size: NativeMetrics.Text.caption, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
