import MailActions
import MailModel
import SwiftUI
import UIKit

struct SwipeRow<Content: View>: View {
    let phone: PhoneMail
    let row: ThreadRow
    @ViewBuilder let content: Content

    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 390
    @Environment(\.touch) private var theme

    static var commitFraction: CGFloat { 0.3 }

    var body: some View {
        let shown = phone.heldSwipe.flatMap { $0.thread == row.id ? CGFloat($0.offset) : nil } ?? offset
        ZStack {
            actionPanel(offset: shown)
            content
                .background(theme.window)
                .offset(x: shown)
        }
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .gesture(HorizontalPan(onChange: changed, onEnd: ended))
        .onTapGesture { phone.open(row.id) }
        .contextMenu {
            Button("Done", systemImage: "checkmark") { phone.perform(.markDone, on: row.id, source: .menu) }
            Button("Remind me", systemImage: "clock") { phone.askReminder(row.id, source: .menu) }
            Button(row.isStarred ? "Unstar" : "Star", systemImage: row.isStarred ? "star.slash" : "star") {
                phone.perform(.toggleStar, on: row.id, source: .menu)
            }
            Button(row.isUnread ? "Mark read" : "Mark unread", systemImage: row.isUnread ? "envelope.open" : "envelope.badge") {
                phone.perform(.toggleRead, on: row.id, source: .menu)
            }
            Button("Trash", systemImage: "trash", role: .destructive) { phone.perform(.trash, on: row.id, source: .menu) }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the conversation")
        .accessibilityAction(named: "Done") { phone.perform(.markDone, on: row.id, source: .menu) }
        .accessibilityAction(named: "Remind me") { phone.askReminder(row.id, source: .menu) }
        .accessibilityAction(named: row.isStarred ? "Unstar" : "Star") { phone.perform(.toggleStar, on: row.id, source: .menu) }
        .accessibilityAction(named: row.isUnread ? "Mark read" : "Mark unread") {
            phone.perform(.toggleRead, on: row.id, source: .menu)
        }
        .accessibilityAction(named: "Trash") { phone.perform(.trash, on: row.id, source: .menu) }
        .accessibilityIdentifier("row.\(row.id.rowID)")
    }

    @ViewBuilder
    private func actionPanel(offset: CGFloat) -> some View {
        let armed = abs(offset) >= width * Self.commitFraction
        if offset > 0 {
            panel(symbol: "clock", label: "Remind me", color: theme.swipeSnooze, armed: armed)
                .frame(width: offset)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if offset < 0 {
            panel(symbol: "checkmark", label: "Done", color: theme.swipeDone, armed: armed)
                .frame(width: -offset)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func panel(symbol: String, label: String, color: Color, armed: Bool) -> some View {
        ZStack {
            Rectangle().fill(armed ? color : theme.elevated)
            VStack(spacing: theme.tokens.space1) {
                Image(systemName: symbol)
                    .font(.system(.title3, weight: .bold))
                Text(label)
                    .font(theme.chip)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(armed ? theme.swipeText : theme.textSecondary)
            .padding(.horizontal, theme.tokens.space4)
        }
        .accessibilityHidden(true)
    }

    private func changed(_ translation: CGFloat) {
        if phone.heldSwipe != nil { phone.heldSwipe = nil }
        let before = abs(offset) >= width * Self.commitFraction
        offset = translation
        let after = abs(offset) >= width * Self.commitFraction
        if before != after { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }

    private func ended(_ translation: CGFloat, _ velocity: CGFloat) {
        let commits = abs(translation) >= width * Self.commitFraction
            || (abs(velocity) > 1_200 && abs(translation) > 40 && velocity.sign == translation.sign)
        guard commits else {
            withAnimation(.spring(duration: 0.3)) { offset = 0 }
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if translation < 0 {
            var handled = false
            withAnimation(.easeOut(duration: 0.22)) {
                handled = phone.done(row.id)
                if handled { offset = -width }
            }
            if !handled { withAnimation(.spring(duration: 0.3)) { offset = 0 } }
        } else {
            withAnimation(.spring(duration: 0.3)) { offset = 0 }
            phone.askReminder(row.id)
        }
    }
}

struct HorizontalPan: UIGestureRecognizerRepresentable {
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed:
            onChange(translation)
        case .ended, .cancelled, .failed:
            onEnd(translation, recognizer.velocity(in: recognizer.view).x)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        // Why: only a mostly sideways pan starts a swipe, so the list keeps scrolling vertically
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.4
        }
    }
}
