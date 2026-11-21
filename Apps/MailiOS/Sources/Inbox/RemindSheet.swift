import MailFeatures
import MailModel
import SwiftUI

struct RemindSheet: View {
    let phone: PhoneMail
    let target: RemindTarget
    @Environment(\.dismiss) private var dismiss
    @Environment(\.touch) private var theme

    var body: some View {
        let now = Date()
        let presets = TimePresets().presets(for: .snooze, now: now).filter { $0.date != nil }
        VStack(spacing: theme.tokens.space5) {
            ZStack {
                Text("Remind me")
                    .font(theme.headline)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                HStack {
                    CircleIconButton(systemImage: "xmark", label: "Close", size: 44) { dismiss() }
                    Spacer()
                }
            }
            Text("The conversation leaves the list and comes back at the time you pick.")
                .font(theme.snippet)
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 0) {
                ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                    Button {
                        if let date = preset.date { phone.remind(target.thread, until: date, source: target.source) }
                    } label: {
                        HStack {
                            Text(preset.title)
                                .foregroundStyle(theme.textPrimary)
                            Spacer()
                            if let date = preset.date {
                                Text(Self.when(date, now: now))
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                        .font(theme.body)
                        .padding(.horizontal, theme.tokens.space5)
                        .frame(minHeight: 54)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < presets.count - 1 {
                        Rectangle().fill(theme.hairline).frame(height: theme.tokens.borderWidthHairline)
                            .padding(.leading, theme.tokens.space5)
                    }
                }
            }
            .cardSurface()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.tokens.space4)
        .padding(.top, theme.tokens.space4)
    }

    static func when(_ date: Date, now: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: now, to: date).day ?? 0
        if days < 6 { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}
