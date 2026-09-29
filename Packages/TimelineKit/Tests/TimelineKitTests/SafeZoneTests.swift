import CoreGraphics
import Foundation
import Testing
@testable import TimelineKit

@Suite("Social safe zones")
struct SafeZoneTests {
    private let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    @Test("Every covered area is inside the frame, and none covers its middle", arguments: SafeZonePlatform.allCases)
    func areasAreSane(_ platform: SafeZonePlatform) {
        #expect(!platform.covered.isEmpty)
        for area in platform.covered {
            #expect(unit.contains(area.rect), "\(platform.title): \(area.label) \(area.rect)")
            #expect(!area.rect.contains(CGPoint(x: 0.5, y: 0.5)), "\(platform.title): \(area.label) covers the middle")
            #expect(!area.label.isEmpty)
        }
    }

    @Test("What is left clear is the frame less the bars and the buttons", arguments: SafeZonePlatform.allCases)
    func clearArea(_ platform: SafeZonePlatform) {
        let clear = platform.clear
        #expect(clear.contains(CGPoint(x: 0.5, y: 0.5)))
        #expect(clear.height > 0.5 && clear.height < 0.9)
        #expect(clear.maxX < 1, "the buttons down the right-hand side are not clear")
        for area in platform.covered {
            #expect(clear.intersection(area.rect).width * clear.intersection(area.rect).height < 1e-9)
        }
    }

    @Test("The guides are for 9:16 frames only")
    func shape() {
        #expect(SafeZonePlatform.applies(to: CGSize(width: 1_080, height: 1_920)))
        #expect(SafeZonePlatform.applies(to: CGSize(width: 1_088, height: 1_920)), "rounded to even pixels")
        #expect(!SafeZonePlatform.applies(to: CGSize(width: 1_920, height: 1_080)))
        #expect(!SafeZonePlatform.applies(to: CGSize(width: 1_080, height: 1_350)))
        #expect(!SafeZonePlatform.applies(to: .zero))
    }
}
