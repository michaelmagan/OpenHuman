import Testing
@testable import MailTheme

@Test func hexParsing() throws {
    let c = try #require(ThemeColor(hex: "#2563EB"))
    #expect(c.css == "#2563eb")
    #expect(ThemeColor(hex: "#2563EB80")?.css == "rgba(37,99,235,0.502)")
    #expect(ThemeColor(hex: "2563EB") == nil)
    #expect(ThemeColor(hex: "#25") == nil)
    #expect(ThemeColor(hex: "#zzzzzz") == nil)
}

@Test func lightMatchesDesignSpec() {
    let t = ThemeTokens.light
    #expect(t.bgWindow.css == "#ffffff")
    #expect(t.textPrimary.css == "#1a1c20")
    #expect(t.bgRowSelected.css == "#eff1f5")
    #expect(t.accentRing.css == "#6d72c0")
    #expect(t.rowHeight == 40)
    #expect(t.typeBody.size == 13 && t.typeBody.lineHeight == 18)
}

@Test func avatarFillIsStable() {
    let t = ThemeTokens.light
    #expect(t.avatarFill(for: "dana@example.com") == t.avatarFill(for: "DANA@example.com"))
    #expect(t.avatarFills.contains(t.avatarFill(for: "sam@example.org")))
}
