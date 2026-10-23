import AppKit
import MailFeatures
import MailRender
import MailTheme

/// Find in the conversation: a floating Liquid Glass capsule at the top right of the reader. It covers the
/// conversation rather than pushing it down.
@MainActor
final class ReaderFindBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    let status: NSTextField
    let glass = NSGlassEffectView()
    var onFind: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?
    static let height: CGFloat = 36

    init(theme: ThemeTokens) {
        status = readerLabel("", theme.typeMeta, theme.textSecondary)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = Self.height / 2
        addSubview(glass)
        field.placeholderString = "Find in conversation"
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityLabel("Find in conversation")
        let previous = ReaderButton.icon("chevron.up", help: "Previous match  ⇧⌘G", theme: theme) { [weak self] in self?.find(backwards: true) }
        previous.setAccessibilityLabel("Previous match")
        let next = ReaderButton.icon("chevron.down", help: "Next match  ⌘G", theme: theme) { [weak self] in self?.find(backwards: false) }
        next.setAccessibilityLabel("Next match")
        let done = ReaderButton.link("Done", theme: theme) { [weak self] in self?.onClose?() }
        let row = NSStackView(views: [field, status, previous, next, done])
        row.spacing = theme.space2
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)
        glass.contentView = content
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            content.topAnchor.constraint(equalTo: glass.topAnchor),
            content.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 220),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: theme.space3),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -theme.space4),
            row.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Find")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func submit() { find(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true) }

    func find(backwards: Bool) {
        let text = field.stringValue
        guard !text.isEmpty else { return }
        onFind?(text, backwards)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        return false
    }
}

@MainActor
final class LinkPreviewView: NSView {
    private let label: NSTextField
    private let theme: ThemeTokens
    private(set) var text = ""

    init(theme: ThemeTokens) {
        self.theme = theme
        label = readerLabel("", theme.typeLabel, theme.textOnToast)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = theme.bgToast.nsColor.cgColor
        layer?.cornerRadius = theme.radiusMD
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: theme.space3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -theme.space3),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 640),
        ])
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ url: URL?, suspicious: SuspiciousLink?) {
        guard let url else {
            isHidden = true
            text = ""
            return
        }
        if let suspicious {
            let shows = suspicious.displayedDestination.map { "Shows \($0) · " } ?? ""
            text = "⚠︎ \(shows)Opens \(suspicious.actualHost ?? suspicious.actualDestination)"
        } else {
            text = ReaderFormatting.hoverText(url)
        }
        label.stringValue = text
        label.textColor = (suspicious == nil ? theme.textOnToast : theme.textWarning).nsColor
        isHidden = false
    }
}

@MainActor
final class LinkConfirmationViewController: NSViewController {
    let warning: ReaderFormatting.LinkWarning
    private let theme: ThemeTokens
    var onOpen: (() -> Void)?
    var onCancel: (() -> Void)?

    init(warning: ReaderFormatting.LinkWarning, theme: ThemeTokens) {
        self.warning = warning
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let title = readerLabel(warning.title, theme.typeBodyStrong, theme.textPrimary)
        var views: [NSView] = [title]
        for line in warning.lines { views.append(readerLabel(line, theme.typeBody, theme.textSecondary, lines: 3)) }
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\r"
        let open = NSButton(title: "Open Link", target: self, action: #selector(open(_:)))
        open.keyEquivalent = ""
        let buttons = NSStackView(views: [open, cancel])
        buttons.spacing = theme.space3
        views.append(buttons)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = theme.space3
        stack.edgeInsets = NSEdgeInsets(top: theme.space5, left: theme.space5, bottom: theme.space5, right: theme.space5)
        stack.setCustomSpacing(theme.space5, after: views[views.count - 2])
        stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        view = stack
    }

    @objc func open(_ sender: Any?) { onOpen?() }
    @objc func cancel(_ sender: Any?) { onCancel?() }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
