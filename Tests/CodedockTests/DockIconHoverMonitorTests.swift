import AppKit
import XCTest
@testable import Codedock

@MainActor
final class DockIconHoverMonitorTests: XCTestCase {
    func testDockIconCenterConvertsFromAccessibilityToAppKitCoordinates() {
        XCTAssertEqual(
            DockCoordinateSpace.appKitCenter(
                accessibilityPosition: CGPoint(x: 4, y: 448),
                size: CGSize(width: 64, height: 64),
                menuBarScreenMaxY: 900
            ),
            NSPoint(x: 36, y: 420)
        )
    }

    func testMatcherRecognizesOnlyTheRequestedApplicationDockItem() {
        let codedock = DockHoverElementIdentity(
            role: "AXDockItem",
            subrole: "AXApplicationDockItem",
            title: "codedock"
        )
        let otherApp = DockHoverElementIdentity(
            role: "AXDockItem",
            subrole: "AXApplicationDockItem",
            title: "Finder"
        )
        let dockFolder = DockHoverElementIdentity(
            role: "AXDockItem",
            subrole: "AXDirectoryDockItem",
            title: "codedock"
        )

        XCTAssertTrue(DockIconHoverMatcher.matches(codedock, appName: "codedock"))
        XCTAssertFalse(DockIconHoverMatcher.matches(otherApp, appName: "codedock"))
        XCTAssertFalse(DockIconHoverMatcher.matches(dockFolder, appName: "codedock"))
    }

    func testMonitorTriggersOncePerHoverEntry() {
        var hoveredElement: DockHoverElementIdentity?
        var anchors: [NSPoint] = []
        let expectedAnchor = NSPoint(x: 640, y: 32)
        let monitor = DockIconHoverMonitor(
            appName: "codedock",
            accessibilityTrustedProvider: { true },
            accessibilityPrompt: {},
            cursorLocationProvider: { CGPoint(x: 640, y: 868) },
            hoveredElementProvider: { _ in hoveredElement },
            anchorPointProvider: { expectedAnchor },
            onHoverEnter: { anchors.append($0) }
        )

        hoveredElement = DockHoverElementIdentity(
            role: "AXDockItem",
            subrole: "AXApplicationDockItem",
            title: "codedock"
        )
        monitor.checkCurrentHover()
        monitor.checkCurrentHover()

        XCTAssertEqual(anchors, [expectedAnchor])
        XCTAssertTrue(monitor.isHoveringAppIcon)

        hoveredElement = nil
        monitor.checkCurrentHover()
        hoveredElement = DockHoverElementIdentity(
            role: "AXDockItem",
            subrole: "AXApplicationDockItem",
            title: "codedock"
        )
        monitor.checkCurrentHover()

        XCTAssertEqual(anchors, [expectedAnchor, expectedAnchor])
    }

    func testMonitorAnchorsPopupAtDockIconCenterInsteadOfCursorEntryPoint() {
        let iconCenter = NSPoint(x: 36, y: 420)
        let hoveredElement = DockHoverElementIdentity(
            role: "AXDockItem",
            subrole: "AXApplicationDockItem",
            title: "codedock",
            anchorPoint: iconCenter
        )
        var anchors: [NSPoint] = []
        let monitor = DockIconHoverMonitor(
            appName: "codedock",
            accessibilityTrustedProvider: { true },
            accessibilityPrompt: {},
            cursorLocationProvider: { CGPoint(x: 2, y: 500) },
            hoveredElementProvider: { _ in hoveredElement },
            anchorPointProvider: { NSPoint(x: 2, y: 400) },
            onHoverEnter: { anchors.append($0) }
        )

        monitor.checkCurrentHover()

        XCTAssertEqual(anchors, [iconCenter])
    }

    func testMonitorTriggersOnceWhenPointerLeavesAppIcon() {
        var hoveredElement: DockHoverElementIdentity? = DockHoverElementIdentity(
            role: "AXDockItem",
            subrole: "AXApplicationDockItem",
            title: "codedock"
        )
        var exitCount = 0
        let monitor = DockIconHoverMonitor(
            appName: "codedock",
            accessibilityTrustedProvider: { true },
            accessibilityPrompt: {},
            cursorLocationProvider: { CGPoint.zero },
            hoveredElementProvider: { _ in hoveredElement },
            onHoverExit: { exitCount += 1 },
            onHoverEnter: { _ in }
        )

        monitor.checkCurrentHover()
        hoveredElement = nil
        monitor.checkCurrentHover()
        monitor.checkCurrentHover()

        XCTAssertEqual(exitCount, 1)
        XCTAssertFalse(monitor.isHoveringAppIcon)
    }

    func testMonitorDoesNotInspectOrTriggerWithoutAccessibilityPermission() {
        var inspectionCount = 0
        var triggerCount = 0
        let monitor = DockIconHoverMonitor(
            appName: "codedock",
            accessibilityTrustedProvider: { false },
            accessibilityPrompt: {},
            cursorLocationProvider: { CGPoint.zero },
            hoveredElementProvider: { _ in
                inspectionCount += 1
                return DockHoverElementIdentity(
                    role: "AXDockItem",
                    subrole: "AXApplicationDockItem",
                    title: "codedock"
                )
            },
            anchorPointProvider: { .zero },
            onHoverEnter: { _ in triggerCount += 1 }
        )

        monitor.checkCurrentHover()

        XCTAssertEqual(inspectionCount, 0)
        XCTAssertEqual(triggerCount, 0)
        XCTAssertFalse(monitor.isHoveringAppIcon)
    }
}
