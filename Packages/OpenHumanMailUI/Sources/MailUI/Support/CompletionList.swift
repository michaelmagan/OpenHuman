import Foundation
import MailFeatures
import MailModel
import MailTheme
import Observation
import OpenHumanCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

public enum CompletionKey: Sendable, Hashable {
    case up, down, accept, escape
}

public enum CompletionOutcome: Sendable, Hashable {
    case ignored, moved, dismissed
    case accepted(EmailAddress)
}

// The suggestions under a person field: looks people up as the text changes, keeps the highlighted row, and
// answers the arrow keys, Return/Tab and Escape. The list floats over the form, so nothing here affects layout.
@MainActor @Observable
public final class CompletionListModel {
    public private(set) var query = ""
    public private(set) var items: [EmailAddress] = []
    public private(set) var cursor = 0
    public private(set) var isDismissed = false

    @ObservationIgnored public var suggest: (@Sendable (String) async -> [EmailAddress])?
    @ObservationIgnored public let limit: Int
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var lookup: Task<Void, Never>?

    nonisolated public static let visibleRows = 6
    nonisolated public static let defaultLimit = 8

    public init(limit: Int = CompletionListModel.defaultLimit, debounce: Duration = .milliseconds(80),
                suggest: (@Sendable (String) async -> [EmailAddress])? = nil) {
        self.limit = max(limit, 1)
        self.debounce = debounce
        self.suggest = suggest
    }

    isolated deinit { lookup?.cancel() }

    public var isShowing: Bool { !isDismissed && !items.isEmpty && !query.isEmpty }

    public var selected: EmailAddress? {
        guard isShowing, items.indices.contains(cursor) else { return nil }
        return items[cursor]
    }

    public func update(query text: String, excluding: Set<String> = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = trimmed != query
        if changed { isDismissed = false }
        query = trimmed
        lookup?.cancel()
        guard !trimmed.isEmpty, let suggest else {
            items = []
            cursor = 0
            return
        }
        // Until the new answer arrives, only the rows that still fit the text stay, so Return never picks a stale one
        if changed {
            items = Self.filtered(items.filter { Self.matches($0, prefix: trimmed) }, excluding: excluding, limit: limit)
            cursor = 0
        }
        let debounce = self.debounce
        lookup = Task { [weak self] in
            if debounce > .zero { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled else { return }
            let found = await suggest(trimmed)
            guard !Task.isCancelled else { return }
            self?.receive(found, for: trimmed, excluding: excluding)
        }
    }

    public func receive(_ found: [EmailAddress], for query: String, excluding: Set<String> = []) {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines) == self.query else { return }
        items = Self.filtered(found, excluding: excluding, limit: limit)
        cursor = 0
    }

    // Shows rows another model looked up, such as a recipient field that keeps its own lookup and highlight
    public func mirror(query text: String, items found: [EmailAddress], cursor index: Int) {
        lookup?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != query {
            isDismissed = false
            query = trimmed
        }
        let rows = Array(found.prefix(limit))
        if rows != items { items = rows }
        let chosen = rows.indices.contains(index) ? index : 0
        if chosen != cursor { cursor = chosen }
    }

    public func move(by delta: Int) {
        guard isShowing else { return }
        cursor = min(max(cursor + delta, 0), items.count - 1)
    }

    public func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        cursor = index
    }

    public func dismiss() {
        lookup?.cancel()
        isDismissed = true
    }

    public func clear() {
        lookup?.cancel()
        query = ""
        items = []
        cursor = 0
        isDismissed = false
    }

    public func handle(_ key: CompletionKey) -> CompletionOutcome {
        guard isShowing else { return .ignored }
        switch key {
        case .up:
            move(by: -1)
            return .moved
        case .down:
            move(by: 1)
            return .moved
        case .accept:
            guard let chosen = selected else { return .ignored }
            clear()
            return .accepted(chosen)
        case .escape:
            dismiss()
            return .dismissed
        }
    }

    public func settle() async { await lookup?.value }

    nonisolated public static func filtered(_ found: [EmailAddress], excluding: Set<String>, limit: Int) -> [EmailAddress] {
        var seen = Set(excluding.map { $0.lowercased() })
        var kept: [EmailAddress] = []
        for address in found {
            let key = address.email.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            kept.append(address)
            if kept.count >= limit { break }
        }
        return kept
    }

    // The address, the whole name or any word of the name starts with the typed text
    nonisolated public static func matches(_ address: EmailAddress, prefix: String) -> Bool {
        let needle = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        let name = address.name?.lowercased() ?? ""
        let words = [address.email.lowercased(), name] + name.split(whereSeparator: \.isWhitespace).map(String.init)
        return words.contains { $0.hasPrefix(needle) }
    }

    nonisolated public static func typed(_ address: EmailAddress) -> String {
        guard let name = address.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return address.email }
        return "\(name) <\(address.email)>"
    }

    nonisolated public static func detail(_ address: EmailAddress) -> String? {
        guard let name = address.name, !name.isEmpty, name != address.email else { return nil }
        return address.email
    }
}

public enum CompletionListMetrics {
    public static let rowHeight: CGFloat = 36
    public static let inset: CGFloat = 5
    public static let cornerRadius: CGFloat = 10
    public static let rowRadius: CGFloat = 6
    public static let minWidth: CGFloat = 220

    public static func height(rows: Int) -> CGFloat {
        CGFloat(min(max(rows, 0), CompletionListModel.visibleRows)) * rowHeight + 2 * inset
    }
}

public struct CompletionListView: View {
    let model: CompletionListModel
    let label: String
    let identifier: String
    let accessory: (@MainActor (EmailAddress) -> String?)?
    let accept: (EmailAddress) -> Void
    @Environment(\.theme) private var theme

    public init(model: CompletionListModel, label: String, identifier: String,
                accessory: (@MainActor (EmailAddress) -> String?)? = nil, accept: @escaping (EmailAddress) -> Void) {
        self.model = model
        self.label = label
        self.identifier = identifier
        self.accessory = accessory
        self.accept = accept
    }

    public var body: some View {
        let scrolls = model.items.count > CompletionListModel.visibleRows
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.offset) { index, address in
                        row(address, index: index).id(index)
                    }
                }
                .padding(CompletionListMetrics.inset)
            }
            .scrollDisabled(!scrolls)
            .scrollIndicators(scrolls ? .automatic : .hidden)
            .onChange(of: model.cursor) { _, now in proxy.scrollTo(now) }
        }
        .frame(height: CompletionListMetrics.height(rows: model.items.count))
        .background(RoundedRectangle(cornerRadius: CompletionListMetrics.cornerRadius, style: .continuous)
            .fill(theme.component.popover.bg.color))
        .overlay(RoundedRectangle(cornerRadius: CompletionListMetrics.cornerRadius, style: .continuous)
            .strokeBorder(theme.component.popover.border.color, lineWidth: theme.borderWidthHairline))
        .clipShape(RoundedRectangle(cornerRadius: CompletionListMetrics.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func row(_ address: EmailAddress, index: Int) -> some View {
        let chosen = index == model.cursor
        let title = RecipientParser.displayName(address)
        let detail = CompletionListModel.detail(address)
        let extra = chosen ? accessory?(address) : nil
        return Button { accept(address) } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .font(.body)
                        .foregroundStyle(theme.textPrimary.color)
                    if let detail {
                        Text(verbatim: detail)
                            .font(.subheadline)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 0)
                if let extra {
                    Text(verbatim: extra)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: CompletionListMetrics.rowHeight,
                   maxHeight: CompletionListMetrics.rowHeight, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: CompletionListMetrics.rowRadius, style: .continuous)
                .fill(chosen ? Self.selectionFill : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { model.select(index) } }
        .accessibilityLabel(title)
        .accessibilityValue([detail, extra].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    // The quiet system highlight, as in a list that does not have the keys: the field keeps the caret, so the
    // highlighted row is marked without the strong selection colour and its text keeps its own colours
    static var selectionFill: Color {
        #if os(macOS)
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        #else
        Color.secondary.opacity(0.16)
        #endif
    }
}

// Shows a completion list outside the view's own layout. A host that can float a window over its content installs
// one; without it, callers draw the list in place.
public struct FloatingCompletion: @unchecked Sendable {
    public struct Request {
        public let list: CompletionListModel
        public let isPresented: Bool
        public let theme: ResolvedTheme
        public let label: String
        public let identifier: String
        public let accessory: (@MainActor (EmailAddress) -> String?)?
        public let accept: @MainActor (EmailAddress) -> Void

        public init(list: CompletionListModel, isPresented: Bool, theme: ResolvedTheme, label: String, identifier: String,
                    accessory: (@MainActor (EmailAddress) -> String?)? = nil,
                    accept: @escaping @MainActor (EmailAddress) -> Void) {
            self.list = list
            self.isPresented = isPresented
            self.theme = theme
            self.label = label
            self.identifier = identifier
            self.accessory = accessory
            self.accept = accept
        }
    }

    public let anchor: @MainActor (Request) -> AnyView

    public init(anchor: @escaping @MainActor (Request) -> AnyView) {
        self.anchor = anchor
    }
}

extension EnvironmentValues {
    @Entry public var floatingCompletion: FloatingCompletion? = nil
}
