import AppKit
import XCTest
@testable import Codedock

final class PanelWindowControllerTests: XCTestCase {
    func testDockHoverAutoCollapseWaitsUntilPointerLeavesIconAndPopup() {
        XCTAssertFalse(DockHoverAutoCollapse.shouldSchedule(
            openedByDockHover: true,
            isDockIconHovered: true,
            isPopupHovered: false,
            collapseOnMouseLeave: true,
            surface: .sessionList
        ))
        XCTAssertFalse(DockHoverAutoCollapse.shouldSchedule(
            openedByDockHover: true,
            isDockIconHovered: false,
            isPopupHovered: true,
            collapseOnMouseLeave: true,
            surface: .sessionList
        ))
        XCTAssertTrue(DockHoverAutoCollapse.shouldSchedule(
            openedByDockHover: true,
            isDockIconHovered: false,
            isPopupHovered: false,
            collapseOnMouseLeave: true,
            surface: .sessionList
        ))
    }

    func testDockHoverAutoCollapseDoesNotCloseManualOrCriticalSurfaces() {
        XCTAssertFalse(DockHoverAutoCollapse.shouldSchedule(
            openedByDockHover: false,
            isDockIconHovered: false,
            isPopupHovered: false,
            collapseOnMouseLeave: true,
            surface: .sessionList
        ))
        XCTAssertFalse(DockHoverAutoCollapse.shouldSchedule(
            openedByDockHover: true,
            isDockIconHovered: false,
            isPopupHovered: false,
            collapseOnMouseLeave: true,
            surface: .approvalCard(sessionId: "session")
        ))
        XCTAssertFalse(DockHoverAutoCollapse.shouldSchedule(
            openedByDockHover: true,
            isDockIconHovered: false,
            isPopupHovered: false,
            collapseOnMouseLeave: false,
            surface: .sessionList
        ))
    }

    func testScreenHopMotionUsesMoreVisibleTiming() {
        let motion = PanelWindowController.screenHopMotion()

        XCTAssertEqual(motion.outgoingOffset, 18)
        XCTAssertEqual(motion.incomingOffset, 30)
        XCTAssertEqual(motion.fadeOutDuration, 0.14, accuracy: 0.001)
        XCTAssertEqual(motion.incomingPauseDuration, 0.06, accuracy: 0.001)
        XCTAssertEqual(motion.fadeInDuration, 0.34, accuracy: 0.001)
    }

    func testScreenHopFramesRetractOldFrameAndDropIntoNewFrame() {
        let oldFrame = NSRect(x: 100, y: 820, width: 420, height: 180)
        let newFrame = NSRect(x: 1800, y: 900, width: 420, height: 180)

        let frames = PanelWindowController.screenHopFrames(
            oldFrame: oldFrame,
            newFrame: newFrame
        )

        XCTAssertEqual(frames.outgoing.origin.x, oldFrame.origin.x)
        XCTAssertEqual(frames.outgoing.origin.y, oldFrame.origin.y + 18)
        XCTAssertEqual(frames.outgoing.size, oldFrame.size)

        XCTAssertEqual(frames.incoming.origin.x, newFrame.origin.x)
        XCTAssertEqual(frames.incoming.origin.y, newFrame.origin.y + 30)
        XCTAssertEqual(frames.incoming.size, newFrame.size)
    }

    func testDockAreaDetectionHandlesBottomLeftAndRightDockPositions() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

        XCTAssertTrue(PanelWindowController.isPointInDockArea(
            NSPoint(x: 720, y: 20),
            screenFrame: screen,
            visibleFrame: NSRect(x: 0, y: 70, width: 1440, height: 806)
        ))
        XCTAssertTrue(PanelWindowController.isPointInDockArea(
            NSPoint(x: 20, y: 400),
            screenFrame: screen,
            visibleFrame: NSRect(x: 72, y: 0, width: 1368, height: 876)
        ))
        XCTAssertTrue(PanelWindowController.isPointInDockArea(
            NSPoint(x: 1420, y: 400),
            screenFrame: screen,
            visibleFrame: NSRect(x: 0, y: 0, width: 1368, height: 876)
        ))
    }

    func testDockAreaDetectionDoesNotTreatMenuBarOrDesktopAsDock() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = NSRect(x: 0, y: 70, width: 1440, height: 806)

        XCTAssertFalse(PanelWindowController.isPointInDockArea(
            NSPoint(x: 720, y: 888),
            screenFrame: screen,
            visibleFrame: visible
        ))
        XCTAssertFalse(PanelWindowController.isPointInDockArea(
            NSPoint(x: 720, y: 400),
            screenFrame: screen,
            visibleFrame: visible
        ))
    }

    func testDockEdgeDetectionHandlesBottomLeftAndRightLayouts() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

        XCTAssertEqual(PanelWindowController.dockEdge(
            screenFrame: screen,
            visibleFrame: NSRect(x: 0, y: 70, width: 1440, height: 806)
        ), .bottom)
        XCTAssertEqual(PanelWindowController.dockEdge(
            screenFrame: screen,
            visibleFrame: NSRect(x: 72, y: 0, width: 1368, height: 876)
        ), .left)
        XCTAssertEqual(PanelWindowController.dockEdge(
            screenFrame: screen,
            visibleFrame: NSRect(x: 0, y: 0, width: 1368, height: 876)
        ), .right)
    }

    func testDockAnchorDetectionSupportsAutoHiddenDock() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 876)

        XCTAssertEqual(PanelWindowController.dockEdgeForAnchor(
            NSPoint(x: 720, y: 24),
            screenFrame: screen,
            visibleFrame: visible
        ), .bottom)
        XCTAssertEqual(PanelWindowController.dockEdgeForAnchor(
            NSPoint(x: 24, y: 450),
            screenFrame: screen,
            visibleFrame: visible
        ), .left)
        XCTAssertNil(PanelWindowController.dockEdgeForAnchor(
            NSPoint(x: 720, y: 450),
            screenFrame: screen,
            visibleFrame: visible
        ))
    }

    func testBottomDockPopupCentersAboveAnchor() {
        let frame = PanelWindowController.dockPopupFrame(
            size: NSSize(width: 580, height: 360),
            anchorPoint: NSPoint(x: 900, y: 30),
            edge: .bottom,
            visibleFrame: NSRect(x: 0, y: 70, width: 1440, height: 806)
        )

        XCTAssertEqual(frame.midX, 900, accuracy: 0.001)
        XCTAssertEqual(frame.minY, 90, accuracy: 0.001)
        XCTAssertEqual(
            frame.minY + DockPopupLayout.bottomShadowInset,
            110,
            accuracy: 0.001
        )
    }

    func testBottomDockPopupMagnificationClearanceDoesNotPushPastTopEdge() {
        let visible = NSRect(x: 0, y: 70, width: 1440, height: 376)
        let frame = PanelWindowController.dockPopupFrame(
            size: NSSize(width: 580, height: 360),
            anchorPoint: NSPoint(x: 720, y: 30),
            edge: .bottom,
            visibleFrame: visible
        )

        XCTAssertEqual(frame.minY, visible.minY + DockPopupLayout.edgeGap, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, visible.maxY - DockPopupLayout.edgeGap, accuracy: 0.001)
    }

    func testBottomDockPopupClampsToVisibleScreenEdges() {
        let visible = NSRect(x: 0, y: 70, width: 1440, height: 806)
        let size = NSSize(width: 580, height: 360)

        let left = PanelWindowController.dockPopupFrame(
            size: size,
            anchorPoint: NSPoint(x: 20, y: 30),
            edge: .bottom,
            visibleFrame: visible
        )
        let right = PanelWindowController.dockPopupFrame(
            size: size,
            anchorPoint: NSPoint(x: 1420, y: 30),
            edge: .bottom,
            visibleFrame: visible
        )

        XCTAssertEqual(left.minX, visible.minX + DockPopupLayout.edgeGap, accuracy: 0.001)
        XCTAssertEqual(right.maxX, visible.maxX - DockPopupLayout.edgeGap, accuracy: 0.001)
    }

    func testSideDockPopupsStayBesideDockAndInsideVisibleFrame() {
        let size = NSSize(width: 580, height: 360)
        let leftVisible = NSRect(x: 72, y: 0, width: 1368, height: 876)
        let rightVisible = NSRect(x: 0, y: 0, width: 1368, height: 876)

        let left = PanelWindowController.dockPopupFrame(
            size: size,
            anchorPoint: NSPoint(x: 24, y: 450),
            edge: .left,
            visibleFrame: leftVisible
        )
        let right = PanelWindowController.dockPopupFrame(
            size: size,
            anchorPoint: NSPoint(x: 1420, y: 450),
            edge: .right,
            visibleFrame: rightVisible
        )

        XCTAssertEqual(left.minX, leftVisible.minX + DockPopupLayout.edgeGap, accuracy: 0.001)
        XCTAssertEqual(right.maxX, rightVisible.maxX - DockPopupLayout.edgeGap, accuracy: 0.001)
        XCTAssertTrue(leftVisible.contains(left))
        XCTAssertTrue(rightVisible.contains(right))
    }
}
