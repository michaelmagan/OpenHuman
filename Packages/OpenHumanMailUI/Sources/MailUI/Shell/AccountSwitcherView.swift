import MailFeatures
import MailModel
import MailTheme
import SwiftUI

public struct AccountSwitcherView: View {
    let router: AppRouter
    @Environment(\.theme) private var theme

    public init(router: AppRouter) {
        self.router = router
    }

    public var body: some View {
        HStack(spacing: ShellMetrics.avatarGap) {
            if router.allInboxesEnabled { allInboxesAvatar }
            ForEach(Array(router.accounts.enumerated()), id: \.element.id) { position, state in
                avatar(state, position: position + 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Accounts")
    }

    private var allInboxesAvatar: some View {
        let shown = router.unifiedInbox != nil
        let size = ShellMetrics.avatarSize
        let ring = theme.borderWidthFocus
        let offset = theme.borderWidthFocusOffset
        let mode = router.accountCountMode
        let count = router.allInboxesUnread
        let badge = shown ? nil : AccountState.switcherBadge(count ?? 0)
        return Button {
            router.goToAllInboxes()
        } label: {
            Image(systemName: "tray.2")
                .font(.system(size: size * 0.5))
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: size, height: size)
                .background(Circle().fill(theme.borderHairline.color))
                .padding(ring + offset)
                .overlay {
                    if shown { Circle().strokeBorder(theme.accentRing.color, lineWidth: ring) }
                }
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge)
                            .font(theme.typeCaption.swiftUIFont)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, theme.space1)
                            .background(Capsule().fill(theme.accentRing.color))
                            .offset(x: offset, y: -offset)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if router.environment.settings != nil {
                Button(mode == .off ? "Show count" : "Hide count") {
                    Self.toggleCounts(router)
                }
                Button("Hide All Inboxes") { router.hideAllInboxes() }
            }
        }
        .help(Self.allInboxesTooltip(count, mode))
        .accessibilityLabel("All Inboxes")
        .accessibilityValue(shown ? "Active" : (badge == nil ? "" : Self.unreadValue(count ?? 0, mode)))
        .accessibilityHint("Control-0 shows every account's inbox together")
        .accessibilityAddTraits(shown ? .isSelected : [])
    }

    private func avatar(_ state: AccountState, position: Int) -> some View {
        let account = state.account
        let isActive = state.id == router.activeAccountID && router.unifiedInbox == nil
        let needsSignIn = account.health == .needsSignIn
        let mode = router.accountCountMode
        let count = state.badgeCount(mode) ?? 0
        let badge = isActive || needsSignIn ? nil : AccountState.switcherBadge(count)
        let showsUnread = badge != nil
        let size = ShellMetrics.avatarSize
        let ring = theme.borderWidthFocus
        let offset = theme.borderWidthFocusOffset
        return Button {
            router.switchAccount(to: account.id)
        } label: {
            AccountAvatar(account: account, size: size)
                .padding(ring + offset)
                .overlay {
                    if isActive {
                        Circle().strokeBorder(theme.accentRing.color, lineWidth: ring)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if needsSignIn {
                        Circle()
                            .fill(theme.textDanger.color)
                            .frame(width: ShellMetrics.avatarDot, height: ShellMetrics.avatarDot)
                            .offset(x: -offset, y: offset)
                    } else if let badge {
                        Text(badge)
                            .font(theme.typeCaption.swiftUIFont)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, theme.space1)
                            .background(Capsule().fill(theme.accentRing.color))
                            .offset(x: offset, y: -offset)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !isActive {
                Button("Switch to \(Self.name(account))") { router.switchAccount(to: account.id) }
            }
            if needsSignIn, router.environment.accounts != nil {
                Button("Sign in again…") { Self.signInAgain(account, router: router) }
            }
        }
        .help(Self.tooltip(account, position: position))
        .accessibilityLabel(Self.name(account))
        .accessibilityValue(isActive ? "Active" : (needsSignIn ? "Needs sign-in"
            : (showsUnread ? Self.unreadValue(count, mode) : "")))
        .accessibilityHint("Control-\(position) switches to this account")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    static func tooltip(_ account: Account, position: Int) -> String {
        if account.health == .needsSignIn { return "\(name(account)) · Needs sign-in" }
        let shortcut = position <= 9 ? "  ⌃\(position)" : ""
        return "\(name(account)) · \(account.email)\(shortcut)"
    }

    static func unreadValue(_ count: Int, _ mode: AccountCountMode) -> String {
        countPhrase(count > 99 ? "More than 99" : String(count), mode)
    }

    static func countPhrase(_ count: String, _ mode: AccountCountMode) -> String {
        mode == .inbox ? "\(count) unread in Inbox" : "\(count) important unread"
    }

    static func allInboxesTooltip(_ count: Int?, _ mode: AccountCountMode) -> String {
        guard let count, count > 0 else { return "All Inboxes  ⌃0" }
        return "All Inboxes · \(countPhrase(count.formatted(), mode))  ⌃0"
    }

    /// Turns the account counts off, or back on to important unread.
    static func toggleCounts(_ router: AppRouter) {
        guard let settings = router.environment.settings else { return }
        let next: AccountCountMode = router.accountCountMode == .off ? .important : .off
        let notices = router.environment.notices
        Task {
            do { try await settings.set(AppSettings.accountCounts, next) } catch {
                notices.post("Couldn't change this setting", style: .error, actionTitle: nil)
            }
        }
    }

    static func signInAgain(_ account: Account, router: AppRouter) {
        guard let accounts = router.environment.accounts else { return }
        Task {
            do { try await accounts.reauthorize(account.id) } catch {
                router.environment.notices.post("Couldn't open the sign-in page", style: .error, actionTitle: nil)
            }
        }
    }

    static func name(_ account: Account) -> String {
        account.alias ?? account.displayName ?? account.email
    }
}

/// An account's picture: its initials on the account colour.
struct AccountAvatar: View {
    let account: Account
    let size: CGFloat
    var textSize: CGFloat?
    @Environment(\.theme) private var theme

    var body: some View {
        Text(ThreadRowFormatting().initials(name: account.displayName, email: account.email))
            .font(textSize.map { Font.system(size: $0, weight: .semibold) } ?? theme.typeCaption.swiftUIFont)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(Circle().fill(theme.tokens.avatarFill(for: account.email).color))
            .overlay {
                if theme.appearance == .dark {
                    Circle().strokeBorder(theme.borderElevated.color, lineWidth: theme.borderWidthHairline)
                }
            }
            .accessibilityHidden(true)
    }
}
