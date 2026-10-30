import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// How a floating overlay panel is drawn: Liquid Glass, or a system material when Reduce Transparency is on.
public enum NativeOverlaySurface: Sendable, Hashable {
    case glass
    case material

    /// Reduce Transparency always gets the material.
    public static func resolve(_ requested: NativeOverlaySurface, reduceTransparency: Bool) -> NativeOverlaySurface {
        reduceTransparency ? .material : requested
    }
}

extension EnvironmentValues {
    /// The surface overlay panels ask for. Off-screen renders ask for `.material`, because a window capture leaves
    /// glass blank.
    @Entry public var nativeOverlaySurface: NativeOverlaySurface = .glass
}

/// The surface the shown overlay panel resolved to.
struct OverlaySurfacePreference: PreferenceKey {
    static let defaultValue: NativeOverlaySurface? = nil

    static func reduce(value: inout NativeOverlaySurface?, nextValue: () -> NativeOverlaySurface?) {
        value = value ?? nextValue()
    }
}

/// A floating panel over the window (palette, pickers, shortcut help, the ask panel): Liquid Glass with the system
/// corner radius, near the top of the window. It follows the window's light or dark appearance and takes only the
/// accent from the theme. A click outside closes it, and nothing under it moves.
struct OverlayPanel<Content: View>: View {
    let width: CGFloat
    var top: CGFloat = OverlayMetrics.pickerTop
    var topRatio: CGFloat = 0
    var label: String? = nil
    let dismiss: () -> Void
    /// Receives the space the panel floats in.
    @ViewBuilder let content: (CGSize) -> Content
    @Environment(\.nativeOverlaySurface) private var requested
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let surface = NativeOverlaySurface.resolve(requested, reduceTransparency: reduceTransparency)
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)
                    .accessibilityHidden(true)
                content(proxy.size)
                    .transaction { $0.disablesAnimations = true }
                    .frame(width: min(width, max(proxy.size.width - OverlayMetrics.windowMargin, 280)))
                    .overlaySurface(surface)
                    .padding(.top, max(top, (proxy.size.height * topRatio).rounded()))
                    .accessibilityElement(children: .contain)
                    .overlayAccessibilityLabel(label)
                    .accessibilityAddTraits(.isModal)
                    .preference(key: OverlaySurfacePreference.self, value: surface)
            }
        }
    }
}

extension View {
    @MainActor @ViewBuilder
    func overlaySurface(_ surface: NativeOverlaySurface) -> some View {
        let shape = RoundedRectangle(cornerRadius: NativeMetrics.Overlay.cornerRadius, style: .continuous)
        switch surface {
        case .glass:
            clipShape(shape)
                .contentShape(shape)
                .glassEffect(.regular, in: shape)
        case .material:
            clipShape(shape)
                .contentShape(shape)
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.separator, lineWidth: 1))
                .shadow(color: .black.opacity(OverlayMetrics.materialShadowOpacity),
                        radius: OverlayMetrics.materialShadowRadius, y: OverlayMetrics.materialShadowY)
        }
    }

    @MainActor @ViewBuilder
    fileprivate func overlayAccessibilityLabel(_ label: String?) -> some View {
        if let label { accessibilityLabel(label) } else { self }
    }

    /// The large field at the top of an overlay: the system font at 17 pt with the system placeholder, straight on the
    /// panel, at a fixed line height so typing never moves the rows below.
    @MainActor func overlayField() -> some View {
        textFieldStyle(.plain)
            .font(.system(size: NativeMetrics.Overlay.paletteFieldTextSize))
            .overlayFieldLine()
    }

    @MainActor fileprivate func overlayFieldLine() -> some View {
        #if canImport(AppKit)
        frame(height: OverlayFieldLine.height)
        #else
        fixedSize(horizontal: false, vertical: true)
        #endif
    }

    /// A row's frame inside an overlay list: the selection plate inset from the panel edge, content inset from the
    /// plate, a fixed height.
    @MainActor func overlayRowLayout(isSelected: Bool, height: CGFloat) -> some View {
        padding(.horizontal, OverlayMetrics.rowPaddingX)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background(OverlaySelectionPlate(isSelected: isSelected))
            .contentShape(Rectangle())
    }
}

#if canImport(AppKit)
@MainActor
enum OverlayFieldLine {
    private static var measured: CGFloat?

    static var height: CGFloat {
        if let measured { return measured }
        let field = NSTextField(string: "Ag")
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: NativeMetrics.Overlay.paletteFieldTextSize)
        let height = ceil(field.intrinsicContentSize.height)
        measured = height
        return height
    }
}
#endif

/// The panel's title above its field, in the system section-header style.
struct OverlayHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: NativeMetrics.Text.caption, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, OverlayMetrics.panelInsetX)
            .frame(maxWidth: .infinity, minHeight: OverlayMetrics.headerHeight, maxHeight: OverlayMetrics.headerHeight,
                   alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The field row: a monochrome SF Symbol, the field, and optional trailing content (a scope, a hint).
struct OverlayFieldRow<Field: View, Trailing: View>: View {
    let symbol: String
    var symbolColor: Color? = nil
    @ViewBuilder let field: Field
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: OverlayMetrics.fieldSpacing) {
            Image(systemName: symbol)
                .font(.system(size: NativeMetrics.Overlay.paletteFieldTextSize))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(symbolColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .frame(width: OverlayMetrics.symbolColumn)
                .accessibilityHidden(true)
            field
            trailing
        }
        .padding(.horizontal, OverlayMetrics.panelInsetX)
        .frame(height: OverlayMetrics.pickerInputHeight)
        .layoutPriority(1)
    }
}

extension OverlayFieldRow where Trailing == EmptyView {
    init(symbol: String, symbolColor: Color? = nil, @ViewBuilder field: () -> Field) {
        self.init(symbol: symbol, symbolColor: symbolColor, field: field) { EmptyView() }
    }
}

/// A group title inside an overlay list, like a sidebar section header.
struct OverlaySectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: NativeMetrics.Text.caption, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, OverlayMetrics.panelInsetX)
            .padding(.bottom, OverlayMetrics.sectionHeaderBottom)
            .frame(maxWidth: .infinity, minHeight: OverlayMetrics.sectionHeaderHeight,
                   maxHeight: OverlayMetrics.sectionHeaderHeight, alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The highlight behind the cursor row. The keys stay in the field, so a `List` selection would turn grey; this is
/// the subtle accent plate instead, with the row's own text colours. Increase Contrast adds an accent outline.
struct OverlaySelectionPlate: View {
    let isSelected: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: OverlayMetrics.plateRadius, style: .continuous)
        shape
            .fill(isSelected ? AnyShapeStyle(TintShapeStyle.tint.opacity(NativeMetrics.List.selectedAlpha)) : AnyShapeStyle(Color.clear))
            .overlay {
                if isSelected, contrast == .increased { shape.strokeBorder(.tint, lineWidth: 1) }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A clickable row in an overlay list. Arrows, Return and the number keys stay on the field; a click runs the row.
struct OverlayRow<Label: View>: View {
    let isSelected: Bool
    var height: CGFloat = OverlayMetrics.rowHeight
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label.overlayRowLayout(isSelected: isSelected, height: height)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, OverlayMetrics.plateInsetX)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A row's leading SF Symbol: monochrome, secondary, red for destructive actions.
struct OverlayRowSymbol: View {
    let symbol: String
    var isDestructive = false

    var body: some View {
        Group {
            if symbol.isEmpty {
                Color.clear
            } else {
                Image(systemName: symbol)
                    .font(.system(size: OverlayMetrics.rowSymbolSize))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(isDestructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            }
        }
        .frame(width: OverlayMetrics.symbolColumn, height: OverlayMetrics.symbolColumn)
        .accessibilityHidden(true)
    }
}

/// A row's title with the letters that matched the query in semibold.
struct OverlayMatchText: View {
    let text: String
    let matched: [Int]

    var body: some View {
        Text(attributed)
            .font(.system(size: NativeMetrics.Text.body))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)
        let strong = Font.system(size: NativeMetrics.Text.body, weight: .semibold)
        for offset in Set(matched) where offset >= 0 && offset < text.count {
            let start = result.characters.index(result.startIndex, offsetBy: offset)
            let end = result.characters.index(after: start)
            result[start..<end].font = strong
        }
        return result
    }
}

/// A shortcut at the trailing edge of a row, quiet like a menu's key equivalent. The row's accessibility value
/// carries the keys.
struct OverlayShortcutHint: View {
    let keys: [String]

    init(_ keys: [String]) { self.keys = keys }

    init(_ key: String) { self.keys = [key] }

    var body: some View {
        Text(keys.joined(separator: " "))
            .font(.system(size: NativeMetrics.Text.secondary))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// What an overlay acts on, beside its field: a quiet capsule that truncates in the middle.
struct OverlayScopeChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: NativeMetrics.Tag.textSize, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, NativeMetrics.Tag.paddingX)
            .frame(height: NativeMetrics.Tag.height)
            .background(.quaternary, in: Capsule(style: .continuous))
            .frame(maxWidth: OverlayMetrics.scopeMaxWidth, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .help(text)
            .accessibilityHidden(true)
    }
}

/// Hints and notes under an overlay's list, in secondary caption text.
struct OverlayFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: OverlayMetrics.footerSpacing) {
            content
            Spacer(minLength: 0)
        }
        .font(.system(size: NativeMetrics.Text.caption))
        .foregroundStyle(.secondary)
        .padding(.horizontal, OverlayMetrics.panelInsetX)
        .padding(.vertical, OverlayMetrics.footerPaddingY)
        .frame(maxWidth: .infinity, minHeight: OverlayMetrics.footerHeight, alignment: .leading)
    }
}

/// One key hint in a footer: "↵ Run".
struct OverlayFooterHint: View {
    let key: String
    let text: String

    init(_ key: String, _ text: String) {
        self.key = key
        self.text = text
    }

    var body: some View {
        HStack(spacing: OverlayMetrics.footerKeyGap) {
            Text(key).fontWeight(.medium)
            Text(text)
        }
        .lineLimit(1)
        .fixedSize()
    }
}
