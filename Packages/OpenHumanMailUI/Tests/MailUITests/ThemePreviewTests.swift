#if os(macOS)
import AppKit
import MailTheme
import SwiftUI
import Testing
@testable import MailUI

struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = buffer
    }

    func at(_ x: CGFloat, _ y: CGFloat, scale: CGFloat) -> (Int, Int, Int) {
        let px = Int(x * scale), py = Int(y * scale)
        let i = (py * width + px) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }
}

func matches(_ pixel: (Int, Int, Int), _ color: ThemeColor, tolerance: Int = 3) -> Bool {
    abs(pixel.0 - Int((color.red * 255).rounded())) <= tolerance && abs(pixel.1 - Int((color.green * 255).rounded())) <= tolerance
        && abs(pixel.2 - Int((color.blue * 255).rounded())) <= tolerance
}

@MainActor
func writeSnapshot(_ image: CGImage, _ name: String) throws {
    guard let dir = ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] else { return }
    let rep = NSBitmapImageRep(cgImage: image)
    let png = try #require(rep.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
}

@MainActor
@Suite struct ThemePreviewTests {
    @Test(arguments: [("light", BuiltinThemeID.light, ThemeAppearance.light), ("dark", BuiltinThemeID.dark, .dark),
                      ("paper", BuiltinThemeID.paper, .light), ("midnight", BuiltinThemeID.midnight, .dark)])
    func previewDrawsTheThemeTokens(_ name: String, _ id: String, _ appearance: ThemeAppearance) throws {
        let theme = ThemeLibrary.builtIn.resolve(themeID: id, appearance: appearance)
        let renderer = ImageRenderer(content: ThemePreviewView(theme: theme))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        try writeSnapshot(image, "theme-preview-\(name)")
        #expect(image.width == Int(ThemePreviewView.baseSize.width * 2))
        let pixels = try #require(Pixels(image))
        let k = 0.62
        let toolbar = theme.component.toolbar.height * k
        let banner = theme.component.banner.height * k
        #expect(matches(pixels.at(ThemePreviewView.baseSize.width / 2 - 20, 2, scale: 2), theme.component.toolbar.bg), "toolbar")
        let bannerY = toolbar + 1 + banner / 2
        #expect(matches(pixels.at(ThemePreviewView.baseSize.width - 10, bannerY, scale: 2), theme.bgWarningSubtle), "banner")
        let rowsTop = toolbar + 1 + banner + theme.component.row.groupHeaderHeight * k * 0.8
        let cursorY = rowsTop + theme.rowHeight * k * 1.5
        #expect(matches(pixels.at(0.5, cursorY, scale: 2), theme.component.row.cursorBar), "cursor bar")
        #expect(matches(pixels.at(4, cursorY, scale: 2), theme.component.row.bgCursor), "cursor fill")
        let plainY = rowsTop + theme.rowHeight * k * 3.5
        #expect(matches(pixels.at(4, plainY, scale: 2), theme.bgWindow), "window")
    }

    @Test func accentChangesTheCursorBar() throws {
        let iris = ThemeLibrary.builtIn.resolve(ThemePreferences(accentID: "iris"), appearance: .light)
        let renderer = ImageRenderer(content: ThemePreviewView(theme: iris))
        let pixels = try #require(renderer.cgImage.flatMap(Pixels.init))
        let k = 0.62
        let rowsTop = iris.component.toolbar.height * k + 1 + iris.component.banner.height * k + iris.component.row.groupHeaderHeight * k * 0.8
        #expect(matches(pixels.at(0.5, rowsTop + iris.rowHeight * k * 1.5, scale: 1), iris.accentRing))
    }

    @Test func thumbnailsRenderOncePerTheme() {
        let cache = ThemeThumbnailCache()
        let light = ResolvedTheme.light
        let first = cache.thumbnail(for: light)
        #expect(first?.width == Int(ThemePreviewView.baseSize.width * 0.4 * 2))
        _ = cache.thumbnail(for: light)
        #expect(cache.renderCount == 1)
        _ = cache.thumbnail(for: ResolvedTheme.dark)
        #expect(cache.renderCount == 2)
    }

    @Test(arguments: [AppearanceMode.light, .dark, .system])
    func appearanceSettingsLaysOut(_ mode: AppearanceMode) throws {
        let store = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: mode)))
        store.systemAppearance = .dark
        let view = AppearanceSettingsView(store: store, fontFamilies: ["Inter", "Bad;Name"]).themed(by: store)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 1100)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0)
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let image = rep.cgImage { try writeSnapshot(image, "appearance-settings-\(mode.rawValue)") }
        let pixels = try #require(rep.cgImage.flatMap(Pixels.init))
        let scale = rep.size.width > 0 ? CGFloat(rep.pixelsWide) / rep.size.width : 1
        let left = pixels.at(4, 4, scale: scale), right = pixels.at(rep.size.width - 4, 4, scale: scale)
        #expect(abs(left.0 - right.0) <= 3 && abs(left.1 - right.1) <= 3 && abs(left.2 - right.2) <= 3,
                "the page draws one background edge to edge: \(left) and \(right)")
    }
}
#endif
