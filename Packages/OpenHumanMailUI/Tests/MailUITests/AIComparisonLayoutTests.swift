import CoreGraphics
import Testing
@testable import MailUI

struct AIComparisonLayoutTests {
    // Text that wraps at 7 pt a character into 16 pt lines under a 20 pt title, and keeps the lines a height holds
    static func measure(original: Int, version: Int) -> AIComparisonLayout.Measure {
        func lines(_ characters: Int, _ width: CGFloat) -> CGFloat {
            (CGFloat(characters) * 7 / max(width, 1)).rounded(.up)
        }
        func fit(_ needed: CGFloat, _ height: CGFloat?) -> CGFloat {
            guard let height else { return needed }
            return max(min(needed, ((height - 20) / 16).rounded(.down)), 1)
        }
        return AIComparisonLayout.Measure(
            original: { width, height in 20 + fit(lines(original, width), height) * 16 },
            version: { width, height in
                let content = min(lines(version, width) * 16 + 8, AIComposerPanel.previewMaxHeight)
                return height.map { min(20 + content, max($0, 36)) } ?? 20 + content
            },
            cut: { width in 20 + min(lines(original, width), 3) * 16 })
    }

    static let contents: [(Int, Int)] = [(4_000, 20), (20, 4_000), (4_000, 4_000), (30, 30), (400, 60), (60, 400)]

    @Test(arguments: contents)
    func aNarrowerPanelIsNeverShorter(_ original: Int, _ version: Int) {
        let measure = Self.measure(original: original, version: version)
        var previous: CGFloat = .infinity
        for step in stride(from: CGFloat(320), through: 1_000, by: 0.5) {
            let frames = AIComparisonLayout.frames(width: step, sideBySideWidth: 620, columnSpacing: 16, rowSpacing: 12,
                                                   measure: measure)
            #expect(frames.height <= previous, "\(original)/\(version) at \(step): \(frames.height) > \(previous)")
            #expect(frames.sideBySide == (step >= 620))
            #expect(frames.original.maxY <= frames.height && frames.version.maxY <= frames.height, "the parts fit")
            previous = frames.height
        }
    }

    @Test func sideBySideIsNeverTallerThanOneAboveTheOther() {
        for (original, version) in Self.contents {
            let measure = Self.measure(original: original, version: version)
            for width in [620, 640, 700, 900] as [CGFloat] {
                let wide = AIComparisonLayout.frames(width: width, sideBySideWidth: 620, columnSpacing: 16, rowSpacing: 12,
                                                     measure: measure)
                let stacked = AIComparisonLayout.frames(width: width, sideBySideWidth: .infinity, columnSpacing: 16,
                                                        rowSpacing: 12, measure: measure)
                #expect(wide.sideBySide && !stacked.sideBySide)
                #expect(wide.height <= stacked.height, "\(original)/\(version) at \(width)")
            }
        }
    }

    @Test func oneAboveTheOtherCutsTheOriginalToItsLines() {
        let frames = AIComparisonLayout.frames(width: 480, sideBySideWidth: 620, columnSpacing: 16, rowSpacing: 12,
                                               measure: Self.measure(original: 4_000, version: 20))
        #expect(frames.original == CGRect(x: 0, y: 0, width: 480, height: 20 + 3 * 16))
        #expect(frames.version.minY == frames.original.maxY + 12)
        let short = AIComparisonLayout.frames(width: 480, sideBySideWidth: 620, columnSpacing: 16, rowSpacing: 12,
                                              measure: Self.measure(original: 30, version: 20))
        #expect(short.original.height == 36, "a one-line original keeps its one line")
    }

    @Test func sideBySideSplitsTheWidth() {
        let frames = AIComparisonLayout.frames(width: 816, sideBySideWidth: 620, columnSpacing: 16, rowSpacing: 12,
                                               measure: Self.measure(original: 60, version: 60))
        #expect(frames.original.width == 400 && frames.version.width == 400)
        #expect(frames.version.minX == 416)
        #expect(frames.original.minY == 0 && frames.version.minY == 0)
    }
}
