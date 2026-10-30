#if OH_DEV_TOOLS
import AppKit
import MailFeatures
import MailUI
import SwiftUI

enum DevFeedbackShortcuts {
    static let checklist = KeyboardShortcut("t", modifiers: [.command, .option, .control])
    static let giveFeedback = KeyboardShortcut("f", modifiers: [.command, .option, .control])
}

struct DeveloperCommands: Commands {
    let center: DevFeedbackCenter
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        if center.availability.isAvailable {
            menu
        }
    }

    private var menu: some Commands {
        CommandMenu("Developer") {
            Button("Test checklist…") {
                guard center.isEnabled else { return }
                center.history.record("menu:dev.checklist")
                center.reloadChecklist()
                openWindow(id: DevFeedbackRuntime.checklistWindowID)
            }
            .keyboardShortcut(DevFeedbackShortcuts.checklist)
            .disabled(!center.isEnabled)
            Button("Give feedback…") {
                guard center.isEnabled else { return }
                openWindow(id: DevFeedbackRuntime.mainWindowID)
                center.beginFeedback()
            }
            .keyboardShortcut(DevFeedbackShortcuts.giveFeedback)
            .disabled(!center.isEnabled)
            Divider()
            Button("Show Feedback Folder") { DevFeedbackRuntime.revealFeedbackFolder(center) }
                .disabled(!center.isEnabled)
            if !center.isEnabled {
                Text("Turn on in Settings › Advanced")
            }
        }
    }
}

struct DevChecklistWindow: View {
    let center: DevFeedbackCenter
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if !center.availability.isAvailable {
                Color.clear
            } else if center.isEnabled {
                DevChecklistView(model: center.checklist) {
                    openWindow(id: DevFeedbackRuntime.mainWindowID)
                    center.beginFeedback()
                }
            } else {
                Text(verbatim: "Developer feedback is off (Settings › Advanced).")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            guard center.availability.isAvailable else {
                dismissWindow(id: DevFeedbackRuntime.checklistWindowID)
                return
            }
            center.reloadChecklist()
            center.isChecklistOpen = true
        }
        .onDisappear { center.isChecklistOpen = false }
    }
}

struct DevFeedbackSheetHost: ViewModifier {
    let center: DevFeedbackCenter

    func body(content: Content) -> some View {
        let presented = center.isFeedbackSheetPresented
        content.sheet(isPresented: Binding(get: { presented }, set: { center.isFeedbackSheetPresented = $0 })) {
            if let model = center.feedback {
                DevFeedbackSheet(model: model, onClose: { center.isFeedbackSheetPresented = false },
                                 copy: DevFeedbackRuntime.copyToPasteboard,
                                 onSendToDevice: SendFeedbackSupport.feedbackSheetAction(center))
            }
        }
    }
}

extension View {
    func devFeedbackSheet(_ center: DevFeedbackCenter) -> some View {
        modifier(DevFeedbackSheetHost(center: center))
    }
}
#endif
