import Foundation
import MailFeatures
import MailModel
import Testing
@testable import MailUI

@MainActor
@Suite struct SplitInboxPickerTests {
    static func tabs(_ count: Int) -> [MailTab] {
        (0..<count).map { index in
            MailTab(location: index == 0 ? .system(.inbox) : .split(SplitKey("s\(index)")), title: "Split \(index)",
                    unread: index, total: index * 10)
        }
    }

    @Test func upToSixSplitsAreSegmentsAndTheRestGoInMore() {
        let few = SplitInboxPicker.layout(Self.tabs(4))
        #expect(few.segments == Self.tabs(4) && few.overflow.isEmpty)
        let six = SplitInboxPicker.layout(Self.tabs(NativeMetrics.Toolbar.maxSplitSegments))
        #expect(six.segments.count == 6 && six.overflow.isEmpty)
        let many = SplitInboxPicker.layout(Self.tabs(9))
        #expect(many.segments == Array(Self.tabs(9).prefix(6)))
        #expect(many.overflow == Array(Self.tabs(9).suffix(3)), "the order is kept, so a choice in More moves nothing")
        #expect(SplitInboxPicker.layout([]).segments.isEmpty)
    }

    @Test func aSegmentReadsNameThenCount() {
        let tab = MailTab(location: .splitOther, title: "Other", unread: 12, total: 4_598)
        #expect(SplitInboxPicker.segmentTitle(tab, count: 12) == "Other 12")
        #expect(SplitInboxPicker.segmentTitle(tab, count: 0) == "Other", "no count when there is nothing")
        #expect(SplitInboxPicker.segmentTitle(tab, count: 4_598) == "Other 999+")
    }

    @Test func theTabsRoleNeedsMacOS27AndTheFeatureFlag() {
        #expect(SplitInboxPicker.style(for: .macOS26) == .segmented)
        if #available(macOS 27, iOS 27, *) {
            #expect(SplitInboxPicker.style(for: .macOS27) == .tabs)
        } else {
            #expect(SplitInboxPicker.style(for: .macOS27) == .segmented)
        }
        NativeFeatures.withOverride(.macOS26) {
            #expect(SplitInboxPicker.style(for: NativeFeatures.current) == .segmented, "the fallback can be checked on 27")
        }
    }
}
