import SwiftUI

extension View {
    /// A floating card (palette, pickers, banners) on Liquid Glass. Reduce Transparency is handled by the system.
    public func nativeGlassCard(cornerRadius: CGFloat = NativeMetrics.Overlay.cornerRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(.background.opacity(NativeMetrics.Banner.backingOpacity), in: shape)
            .glassEffect(.regular, in: shape)
    }

    /// A floating capsule under the toolbar (banners, notices). It floats over the rows, so a window-background fill
    /// under the glass keeps its text off the row text behind it.
    public func nativeGlassCapsule() -> some View {
        background(.background.opacity(NativeMetrics.Banner.backingOpacity), in: Capsule(style: .continuous))
            .glassEffect(.regular, in: Capsule(style: .continuous))
    }

    /// Toolbar glyphs: SF Symbols at 15 pt regular, hierarchical.
    public func nativeToolbarSymbol() -> some View {
        font(.system(size: NativeMetrics.Toolbar.symbolSize, weight: .regular))
            .symbolRenderingMode(.hierarchical)
    }
}

/// A toolbar item's content: always a `Label`, so the title shows in "Icon and Text", the overflow menu and
/// customization, and serves as the accessibility label.
public struct NativeToolbarLabel: View {
    let title: String
    let systemImage: String

    public init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        Label(title, systemImage: systemImage)
            .nativeToolbarSymbol()
    }
}

/// A stroked keycap for hint lines, menus and the palette. Text and stroke use hierarchical styles, so the keycap
/// follows the surrounding foreground (white inside an accent selection).
public struct NativeKeycap: View {
    let key: String

    public init(_ key: String) { self.key = key }

    public var body: some View {
        Text(key)
            .font(.system(size: NativeMetrics.Keycap.textSize, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, NativeMetrics.Keycap.paddingX)
            .frame(minWidth: NativeMetrics.Keycap.minWidth, minHeight: NativeMetrics.Keycap.height)
            .overlay {
                RoundedRectangle(cornerRadius: NativeMetrics.Keycap.cornerRadius, style: .continuous)
                    .strokeBorder(.tertiary, lineWidth: NativeMetrics.Keycap.strokeWidth)
            }
            .fixedSize()
            .accessibilityLabel(Text(key))
    }
}

/// A tinted capsule for labels and tags. `text` must keep 4.5:1 on the tint at `NativeMetrics.Tag.fillOpacity`;
/// the theme's label chip colours do.
public struct NativeTagCapsule: View {
    let title: String
    let tint: Color
    let text: Color

    public init(_ title: String, tint: Color, text: Color) {
        self.title = title
        self.tint = tint
        self.text = text
    }

    public var body: some View {
        Text(title)
            .font(.system(size: NativeMetrics.Tag.textSize, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(text)
            .padding(.horizontal, NativeMetrics.Tag.paddingX)
            .frame(height: NativeMetrics.Tag.height)
            .background(tint.opacity(NativeMetrics.Tag.fillOpacity), in: Capsule(style: .continuous))
            .fixedSize()
    }
}

/// How a selected row looks. `system` is the system list selection: the accent colour with white text while the
/// window is key, the quiet unemphasized colour otherwise. `tint` is the translucent accent plate, with the row's own
/// text colours.
public enum NativeSelectionStyle: Sendable, Hashable {
    case system
    case tint

    @MainActor public static var current: NativeSelectionStyle {
        NativeFeatures.current.systemListSelection ? .system : .tint
    }
}

/// The highlight behind the cursor row of a list whose keys stay in a field (palette, pickers). A `List` selection
/// turns grey while its field has focus, so these rows draw the plate themselves. Put `nativeSelectionForeground` on
/// the row's content so its text turns white on the accent fill.
public struct NativeSelectionPlate: View {
    public enum Look: Sendable, Hashable {
        case hidden
        case accent
        case unemphasized
        case tint
        case inactiveTint

        public static func of(isSelected: Bool, isEmphasized: Bool, style: NativeSelectionStyle) -> Look {
            guard isSelected else { return .hidden }
            switch style {
            case .system: return isEmphasized ? .accent : .unemphasized
            case .tint: return isEmphasized ? .tint : .inactiveTint
            }
        }

        /// The row's text turns white only on the full accent fill.
        public var whiteText: Bool { self == .accent }

        var fill: AnyShapeStyle {
            switch self {
            case .hidden: AnyShapeStyle(Color.clear)
            case .accent: AnyShapeStyle(TintShapeStyle.tint)
            case .unemphasized: AnyShapeStyle(Self.unemphasizedFill)
            case .tint: AnyShapeStyle(TintShapeStyle.tint.opacity(NativeMetrics.List.selectedAlpha))
            case .inactiveTint: AnyShapeStyle(Color.primary.opacity(NativeMetrics.List.inactiveSelectedAlpha))
            }
        }

        private static var unemphasizedFill: Color {
            #if os(macOS)
            Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
            #else
            Color.secondary.opacity(0.16)
            #endif
        }
    }

    let isSelected: Bool
    let isEmphasized: Bool
    let style: NativeSelectionStyle?
    let insetX: CGFloat

    /// `style` nil follows `NativeFeatures.current`.
    public init(isSelected: Bool, isEmphasized: Bool = true, style: NativeSelectionStyle? = nil,
                insetX: CGFloat = NativeMetrics.List.plateInsetX) {
        self.isSelected = isSelected
        self.isEmphasized = isEmphasized
        self.style = style
        self.insetX = insetX
    }

    public var look: Look { Look.of(isSelected: isSelected, isEmphasized: isEmphasized, style: style ?? .current) }

    public var body: some View {
        RoundedRectangle(cornerRadius: NativeMetrics.List.plateCornerRadius, style: .continuous)
            .fill(look.fill)
            .padding(.horizontal, insetX)
            .padding(.vertical, NativeMetrics.List.plateInsetY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// The row's base text style: white on the accent selection, `.primary` otherwise. Hierarchical styles inside the
    /// row (`.secondary`, keycap strokes) follow it.
    @MainActor public func nativeSelectionForeground(isSelected: Bool, isEmphasized: Bool = true,
                                                     style: NativeSelectionStyle? = nil) -> some View {
        let look = NativeSelectionPlate.Look.of(isSelected: isSelected, isEmphasized: isEmphasized, style: style ?? .current)
        return foregroundStyle(look.whiteText ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
    }
}
