import XCTest

/// Placement of the Dynamic Island on notched and plain displays.
final class IslandGeometryTests: XCTestCase {
    /// 14" MacBook Pro in points: 1512 × 982, 32 pt menu bar with a 200 pt notch.
    static let notched = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 656, height: 32),
        auxiliaryTopRight: CGRect(x: 856, y: 950, width: 656, height: 32)
    )

    /// External 1920 × 1080 display placed to the right of the main one, 24 pt menu bar.
    static let plain = ScreenMetrics(
        frame: CGRect(x: 1512, y: -98, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1512, y: -98, width: 1920, height: 1056),
        safeAreaTop: 0,
        auxiliaryTopLeft: nil,
        auxiliaryTopRight: nil
    )

    static let panel = CGSize(width: 480, height: 560)

    func testNotchIsDerivedFromTheAuxiliaryAreas() {
        XCTAssertTrue(Self.notched.hasNotch)
        XCTAssertEqual(Self.notched.notch, CGRect(x: 656, y: 950, width: 200, height: 32))
        XCTAssertEqual(Self.notched.menuBarHeight, 32)
        XCTAssertEqual(Self.plain.notch, nil)
        XCTAssertEqual(Self.plain.menuBarHeight, 24)
    }

    func testCollapsedShapeIsExactlyTheNotch() {
        let geometry = IslandGeometry(screen: Self.notched, panelSize: Self.panel)
        XCTAssertEqual(geometry.collapsed, Self.notched.notch)
        XCTAssertEqual(geometry.windowRect(for: .collapsed), geometry.collapsed)
        XCTAssertEqual(geometry.stripHeight, 32)
    }

    func testExpandedAndFlashHangFromTheNotchCentre() {
        let geometry = IslandGeometry(screen: Self.notched, panelSize: Self.panel)
        for phase in [IslandGeometry.Phase.flash, .prompt, .form, .expanded] {
            let rect = geometry.rect(for: phase)
            XCTAssertEqual(rect.maxY, 982)
            XCTAssertEqual(rect.midX, 756)
            XCTAssertTrue(Self.notched.frame.contains(rect))
            let window = geometry.windowRect(for: phase)
            XCTAssertTrue(window.contains(rect))
            XCTAssertEqual(window.maxY, 982)
            XCTAssertTrue(Self.notched.frame.contains(window))
        }
        XCTAssertEqual(geometry.expanded.size, CGSize(
            width: 480 + IslandGeometry.panelHorizontalPadding * 2,
            height: 32 + 560 + IslandGeometry.panelBottomPadding
        ))
        XCTAssertEqual(geometry.flash.size, CGSize(width: 340, height: 32 + 48))
    }

    func testPlainDisplayGetsAPillOnTheMenuBar() {
        let geometry = IslandGeometry(screen: Self.plain, panelSize: Self.panel)
        XCTAssertEqual(geometry.collapsed.size, CGSize(width: 140, height: 22))
        XCTAssertEqual(geometry.collapsed.maxY, Self.plain.frame.maxY)
        XCTAssertEqual(geometry.collapsed.midX, Self.plain.frame.midX)
        XCTAssertTrue(Self.plain.frame.contains(geometry.expanded))
        XCTAssertEqual(geometry.expanded.midX, Self.plain.frame.midX)
    }

    func testRectsStayInsideANarrowScreen() {
        let narrow = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 400, height: 500),
            visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 476),
            safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
        )
        let geometry = IslandGeometry(screen: narrow, panelSize: Self.panel)
        // Wider and taller than the screen: still centred and still hanging from the top.
        XCTAssertEqual(geometry.expanded.midX, 200)
        XCTAssertEqual(geometry.expanded.maxY, 500)
        XCTAssertEqual(geometry.windowRect(for: .expanded).maxY, 500)
    }
}
