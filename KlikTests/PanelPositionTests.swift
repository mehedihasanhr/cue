import XCTest

/// Where the floating panels land for each position choice.
final class PanelPositionTests: XCTestCase {
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
    let window = CGSize(width: 700 + 48, height: 520 + 48) // 24 pt shadow margin each side

    /// The glass (the window minus its margin) for a position.
    private func glass(_ position: PanelPosition, pointer: CGPoint = CGPoint(x: 600, y: 500)) -> CGRect {
        let origin = position.origin(windowSize: window, margin: 24, pointer: pointer, visible: visible)
        return CGRect(x: origin.x + 24, y: origin.y + 24, width: 700, height: 520)
    }

    func testCornersAndEdgesSitInsideTheVisibleArea() {
        let inset = PanelPosition.inset
        XCTAssertEqual(glass(.topLeft).minX, inset)
        XCTAssertEqual(glass(.topLeft).maxY, 950 - inset)
        XCTAssertEqual(glass(.topRight).maxX, 1512 - inset)
        XCTAssertEqual(glass(.bottomLeft).minY, inset)
        XCTAssertEqual(glass(.bottomRight).maxX, 1512 - inset)
        XCTAssertEqual(glass(.bottomRight).minY, inset)
        XCTAssertEqual(glass(.top).midX, 756)
        XCTAssertEqual(glass(.top).maxY, 950 - inset)
        XCTAssertEqual(glass(.bottom).midX, 756)
        XCTAssertEqual(glass(.bottom).minY, inset)
        XCTAssertEqual(glass(.center).midX, 756)
        XCTAssertEqual(glass(.center).midY, 475)
        for position in PanelPosition.allCases {
            XCTAssertTrue(visible.insetBy(dx: inset - 0.5, dy: inset - 0.5).contains(glass(position)), "\(position)")
        }
    }

    func testPointerPlacementHangsFromThePointerAndStaysOnScreen() {
        let under = glass(.pointer, pointer: CGPoint(x: 600, y: 900))
        XCTAssertEqual(under.minX, 576)
        XCTAssertEqual(under.maxY, 912)
        // Near the bottom-right corner it is pushed back inside.
        let corner = glass(.pointer, pointer: CGPoint(x: 1500, y: 20))
        XCTAssertEqual(corner.maxX, 1512 - PanelPosition.inset)
        XCTAssertEqual(corner.minY, PanelPosition.inset)
    }
}
