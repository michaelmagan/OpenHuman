import AppKit
import MailFeatures
import MailModel
import OpenHumanCore
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
public final class DockTileBadge: DockBadging {
    public init() {}

    public func setBadge(_ label: String) {
        NSApp.dockTile.badgeLabel = label.isEmpty ? nil : label
    }
}

@MainActor
public final class MacLoginItem: LoginItemControlling {
    public init() {}

    public func status() -> LoginItemStatus { Self.map(SMAppService.mainApp.status) }

    public func register() throws { try SMAppService.mainApp.register() }

    public func unregister() throws { try SMAppService.mainApp.unregister() }

    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    nonisolated static func map(_ status: SMAppService.Status) -> LoginItemStatus {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }
}

@MainActor
public final class DefaultBrowserOpener: URLOpening {
    public init() {}
    public func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

extension SystemPlatform {
    @MainActor
    public static func mac(notifier: any SystemNotifying, spotlight: any SpotlightIndexing,
                           showMainWindow: (@MainActor () -> Void)? = nil) -> SystemPlatform {
        var platform = SystemPlatform(
            notifier: notifier, dock: DockTileBadge(), loginItem: MacLoginItem(), urlOpener: DefaultBrowserOpener(),
            spotlight: spotlight, menuBarItem: MacMenuBarItem.shared, hotkeys: CarbonGlobalHotkey.shared,
            services: MacServicesProvider.shared, textSettings: MacSystemTextSettings(),
            isAppActive: { NSApp.isActive }, activateApp: { NSApp.activate() },
            showMainWindow: showMainWindow ?? { NSApp.activate() },
            quitApp: { NSApp.terminate(nil) },
            chooseDiagnosticsFile: { name in
                let panel = NSSavePanel()
                panel.nameFieldStringValue = name
                panel.allowedContentTypes = [.zip]
                panel.canCreateDirectories = true
                panel.title = "Export Diagnostics"
                panel.message = "The file contains no email content: no subjects, addresses or message text."
                return panel.runModal() == .OK ? panel.url : nil
            },
            openNotificationSettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            })
        platform.copyToClipboard = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        platform.chooseConversationDebugFile = { name in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.title = "Save debug info"
            panel.message = "The file has no subject, addresses or message text unless you ticked the box. Nothing is sent anywhere."
            return panel.runModal() == .OK ? panel.url : nil
        }
        platform.confirmConversationDebug = {
            let alert = NSAlert()
            alert.messageText = "Copy debug info for this conversation?"
            alert.informativeText = "It lists versions, sync state, labels, split verdicts and message structure. It has no addresses (only the sender's domain), no message text and no attachment names. Nothing is sent anywhere."
            let box = NSButton(checkboxWithTitle: "Also include the subject line and sender name", target: nil, action: nil)
            box.state = .off
            box.sizeToFit()
            alert.accessoryView = box
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return ConversationDebugOptions(includeSubjectAndSender: box.state == .on)
        }
        platform.confirmDomainWideRule = { question in await DomainWideRuleAlert.run(question) }
        return platform
    }
}

@MainActor
enum DomainWideRuleAlert {
    static func make(_ question: DomainWideRuleConfirmation) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = question.title
        alert.informativeText = question.message
        for choice in question.choices {
            let button = alert.addButton(withTitle: question.buttonTitle(choice))
            if choice == .entireDomain { button.hasDestructiveAction = true }
        }
        return alert
    }

    static func choice(for response: NSApplication.ModalResponse,
                       in question: DomainWideRuleConfirmation) -> DomainWideRuleChoice {
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return question.choices.indices.contains(index) ? question.choices[index] : .cancel
    }

    static func run(_ question: DomainWideRuleConfirmation) async -> DomainWideRuleChoice {
        let alert = make(question)
        let response = if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil {
            await alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
        return choice(for: response, in: question)
    }
}
