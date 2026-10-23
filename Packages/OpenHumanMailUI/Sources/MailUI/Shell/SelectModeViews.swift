import MailActions
import MailFeatures
import MailTheme
import SwiftUI

struct SelectAllCheckbox: View {
    let list: ThreadListModel
    let descriptors: [ActionDescriptor]
    @Environment(\.theme) private var theme
    @Environment(\.selectAllTipPinned) private var tipPinned

    var body: some View {
        let check = list.headerCheck
        if check == .hidden {
            Color.clear
                .frame(width: ShellMetrics.toolbarControlHeight, height: ShellMetrics.toolbarControlHeight)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            let rows = SelectAllShortcuts.tipRows(descriptors)
            Button {
                list.headerCheckClicked()
            } label: {
                SelectCheckboxGlyph(checked: check == .all)
                    .frame(width: ShellMetrics.toolbarControlHeight, height: ShellMetrics.toolbarControlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .shortcutTip(SelectAllShortcuts.tip(descriptors), alignment: .leading, pinned: tipPinned)
            .help(Self.helpText(check == .all, rows))
            .accessibilityLabel(check == .all ? "Clear selection" : "Select all")
            .accessibilityValue(check == .all ? "All conversations checked" : "Some conversations checked")
            .accessibilityHint(Self.spokenHint(rows))
            .accessibilityIdentifier("toolbar.selectAll")
        }
    }

    static func helpText(_ allChecked: Bool, _ rows: [SelectAllShortcuts.TipRow]) -> String {
        let title = allChecked ? "Clear selection" : "Select all"
        return ([title] + rows.map { "\($0.title)  \($0.keycaps.joined())" }).joined(separator: "\n")
    }

    static func spokenHint(_ rows: [SelectAllShortcuts.TipRow]) -> String {
        rows.map { "\($0.title): \(SelectAllShortcuts.spoken($0.keycaps))" }.joined(separator: ". ")
    }
}

extension EnvironmentValues {
    @Entry public var selectAllTipPinned = false
}

struct ToastKeycapRow: View {
    let keycaps: [String]
    @Environment(\.theme) private var theme

    var body: some View {
        let toast = theme.component.toast
        HStack(spacing: theme.space2) {
            ForEach(Array(keycaps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(theme.typeKeycap.swiftUIFont)
                    .foregroundStyle(toast.keycapText.color)
                    .padding(.horizontal, theme.space2)
                    .frame(minWidth: theme.component.keycap.minWidth, minHeight: theme.component.keycap.height)
                    .background(RoundedRectangle(cornerRadius: theme.component.keycap.radius).fill(toast.keycapBg.color))
            }
        }
        .accessibilityHidden(true)
    }
}

struct CheckBeforeHint: View {
    let list: ThreadListModel
    let keycaps: [String]
    @Environment(\.theme) private var theme

    var body: some View {
        let toast = theme.component.toast
        HStack(spacing: theme.space3) {
            HStack(spacing: theme.space3) {
                Text("Want to select everything before this conversation? Hit")
                    .font(theme.typeBody.swiftUIFont)
                    .lineLimit(1)
                HStack(spacing: theme.space1) {
                    ToastKeycapRow(keycaps: keycaps)
                    Text("!").font(theme.typeBody.swiftUIFont)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            Button { list.selection.checkBeforeHintDismissed = true } label: {
                Image(systemName: "xmark")
                    .font(.system(size: ShellMetrics.smallIconSize, weight: .regular))
                    .foregroundStyle(toast.textSecondary.color)
                    .frame(width: toast.closeSize, height: toast.closeSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(toast.text.color)
        .padding(.leading, theme.space5)
        .padding(.trailing, theme.space3)
        .frame(minHeight: toast.height)
        .background(RoundedRectangle(cornerRadius: toast.radius).fill(toast.bg.color))
        .themeShadow(theme.shadow2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selection.checkBeforeHint")
        .onAppear { AccessibilityNotification.Announcement(spoken).post() }
    }

    var spoken: String {
        "Want to select everything before this conversation? Press \(SelectAllShortcuts.spoken(keycaps))."
    }

    /// Only over the account's mail list on screen: not over a conversation, All Inboxes, or the Calendar, which is
    /// drawn over the mail column while the list and its checks stay behind it.
    static func applies(mode: AppRouter.Mode, isMail: Bool, offersCheckBefore: Bool) -> Bool {
        mode == .list && isMail && offersCheckBefore
    }

    static func shows(router: AppRouter) -> CheckBeforeHint? {
        guard let list = router.active?.list,
              applies(mode: router.mode, isMail: ShellSurface(router: router).isMail,
                      offersCheckBefore: list.offersCheckBefore) else { return nil }
        let keycaps = SelectAllShortcuts.keycaps(for: SelectAllShortcuts.commandA, in: router.environment.actions.descriptors)
        return keycaps.isEmpty ? nil : CheckBeforeHint(list: list, keycaps: keycaps)
    }
}
