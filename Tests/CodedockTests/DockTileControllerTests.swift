import XCTest
import AppKit
@testable import Codedock
import CodedockCore

@MainActor
final class DockTileControllerTests: XCTestCase {
    func testIdlePresentationIsStaticAndHasNoBadge() {
        let presentation = DockTilePresentation.make(
            status: .idle,
            source: "codex",
            activeSessionCount: 0,
            hasCompletion: false
        )

        XCTAssertEqual(presentation.mode, .idle)
        XCTAssertFalse(presentation.shouldAnimate)
        XCTAssertNil(presentation.badgeLabel)
        XCTAssertEqual(presentation.source, "codex")
    }

    func testWorkingStatusesAnimateAndShowActiveSessionCount() {
        for status: AgentStatus in [.processing, .running] {
            let presentation = DockTilePresentation.make(
                status: status,
                source: "claude",
                activeSessionCount: 3,
                hasCompletion: false
            )

            XCTAssertEqual(presentation.mode, .working)
            XCTAssertTrue(presentation.shouldAnimate)
            XCTAssertEqual(presentation.badgeLabel, "3")
        }
    }

    func testInteractiveStatusesUseDistinctModes() {
        let approval = DockTilePresentation.make(
            status: .waitingApproval,
            source: "gemini",
            activeSessionCount: 1,
            hasCompletion: false
        )
        let question = DockTilePresentation.make(
            status: .waitingQuestion,
            source: "gemini",
            activeSessionCount: 1,
            hasCompletion: false
        )

        XCTAssertEqual(approval.mode, .approval)
        XCTAssertEqual(question.mode, .question)
        XCTAssertTrue(approval.shouldAnimate)
        XCTAssertTrue(question.shouldAnimate)
    }

    func testCompletionAnimatesOnlyWhileCompletionIsPresent() {
        let presentation = DockTilePresentation.make(
            status: .idle,
            source: "claude",
            activeSessionCount: 0,
            hasCompletion: true
        )

        XCTAssertEqual(presentation.mode, .completion)
        XCTAssertTrue(presentation.shouldAnimate)
    }

    func testBadgeCapsLargeSessionCounts() {
        let presentation = DockTilePresentation.make(
            status: .running,
            source: "claude",
            activeSessionCount: 120,
            hasCompletion: false
        )

        XCTAssertEqual(presentation.badgeLabel, "99+")
    }

    func testDockActivityBuildsStableUniqueSourceRotation() {
        let activity = deriveDockTileActivity(from: [
            "cursor": makeSession(source: "cursor", status: .processing),
            "codex-second": makeSession(source: "codex", status: .processing),
            "claude": makeSession(source: "claude", status: .processing),
            "codex-first": makeSession(source: "codex", status: .processing),
        ])

        XCTAssertEqual(activity.status, .processing)
        XCTAssertEqual(activity.rotationSources, ["claude", "codex", "cursor"])
        XCTAssertEqual(activity.activeSessionCount, 4)
    }

    func testDockActivityOnlyRotatesHighestPrioritySources() {
        let activity = deriveDockTileActivity(from: [
            "claude-approval": makeSession(source: "claude", status: .waitingApproval),
            "codex-running": makeSession(source: "codex", status: .running),
            "cursor-processing": makeSession(source: "cursor", status: .processing),
        ])

        XCTAssertEqual(activity.status, .waitingApproval)
        XCTAssertEqual(activity.rotationSources, ["claude"])
        XCTAssertEqual(activity.activeSessionCount, 3)
    }

    func testDockIconUsesCenteredOpticalScale() {
        let bounds = NSRect(x: 0, y: 0, width: 128, height: 128)
        let iconRect = DockTileGeometry.iconRect(in: bounds)

        XCTAssertEqual(iconRect.midX, bounds.midX, accuracy: 0.001)
        XCTAssertEqual(iconRect.midY, bounds.midY, accuracy: 0.001)
        XCTAssertEqual(iconRect.width, 138.24, accuracy: 0.001)
        XCTAssertEqual(iconRect.height, 138.24, accuracy: 0.001)
    }

    func testMascotPreservesItsScaleInsideTheEnlargedIcon() {
        let bounds = NSRect(x: 0, y: 0, width: 128, height: 128)

        XCTAssertEqual(DockTileGeometry.mascotSize(in: bounds), 102.2976, accuracy: 0.001)
    }

    func testMascotIsHorizontallyAndVerticallyCentered() {
        let bounds = NSRect(x: 0, y: 0, width: 128, height: 128)
        let mascotRect = DockTileGeometry.mascotRect(
            in: bounds,
            source: "codex",
            mode: .working
        )

        XCTAssertEqual(mascotRect.midX, bounds.midX, accuracy: 0.001)
        XCTAssertEqual(mascotRect.midY, bounds.midY, accuracy: 0.001)
        XCTAssertEqual(mascotRect.width, 102.2976, accuracy: 0.001)
        XCTAssertEqual(mascotRect.height, 102.2976, accuracy: 0.001)
    }

    func testClaudeAndFallbackMascotsUseMeasuredVisualCenterCorrection() {
        let bounds = NSRect(x: 0, y: 0, width: 128, height: 128)

        for source in ["claude", "zcode", "future-clawd-fallback"] {
            let mascotRect = DockTileGeometry.mascotRect(
                in: bounds,
                source: source,
                mode: .working
            )
            XCTAssertEqual(
                mascotRect.midX,
                bounds.midX + 102.2976 * 0.013,
                accuracy: 0.001,
                "Unexpected Clawd correction for \(source)"
            )
            XCTAssertEqual(mascotRect.midY, bounds.midY, accuracy: 0.001)
        }
    }

    func testLeftHeavyWorkingMascotsUseMeasuredVisualCenterCorrection() {
        let bounds = NSRect(x: 0, y: 0, width: 128, height: 128)
        let sources = [
            "google-antigravity", "gemini", "cursor", "trae",
            "copilot", "qoder", "droid", "codebuddy",
            "stepfun", "opencode", "qwen", "antigravity",
            "workbuddy", "hermes", "kimi", "pi",
        ]

        for source in sources {
            let mascotRect = DockTileGeometry.mascotRect(
                in: bounds,
                source: source,
                mode: .working
            )
            XCTAssertEqual(
                mascotRect.midX,
                bounds.midX + 102.2976 * 0.030,
                accuracy: 0.001,
                "Unexpected work-scene correction for \(source)"
            )
            XCTAssertEqual(mascotRect.midY, bounds.midY, accuracy: 0.001)
        }
    }

    func testAlreadyCenteredWorkingMascotsRemainGeometricallyCentered() {
        let bounds = NSRect(x: 0, y: 0, width: 128, height: 128)

        for source in ["codex", "cline", "kiro", "openclaw"] {
            let mascotRect = DockTileGeometry.mascotRect(
                in: bounds,
                source: source,
                mode: .working
            )
            XCTAssertEqual(
                mascotRect.midX,
                bounds.midX,
                accuracy: 0.001,
                "Centered mascot \(source) should not receive a correction"
            )
        }
    }

    func testInteractiveMascotsDoNotInheritWorkSceneCorrection() {
        let bounds = NSRect(x: 0, y: 0, width: 128, height: 128)

        for mode: DockTileMode in [.approval, .question] {
            for source in ["google-antigravity", "gemini", "claude", "cursor"] {
                let mascotRect = DockTileGeometry.mascotRect(
                    in: bounds,
                    source: source,
                    mode: mode
                )
                XCTAssertEqual(
                    mascotRect.midX,
                    bounds.midX,
                    accuracy: 0.001,
                    "Interactive \(source) mascot should stay centered in \(mode) mode"
                )
            }
        }
    }

    func testIdleAndAnimatedStatesShareTheEnlargedCenteredIconContainer() async throws {
        let dockTile = TestDockTile()
        let controller = DockTileController(
            dockTile: dockTile,
            baseIcon: makeInsetDockIcon(),
            reduceMotionProvider: { true }
        )
        let appState = AppState()
        controller.start(observing: appState)
        defer { controller.stop() }

        let idleBounds = try XCTUnwrap(renderedAlphaBounds(from: dockTile))

        appState.sessions["dock-shared-icon-container"] = makeSession(
            source: "antigravity",
            status: .processing
        )
        appState.refreshDerivedState()
        await Task.yield()

        let animatedBounds = try XCTUnwrap(renderedAlphaBounds(from: dockTile))

        for bounds in [idleBounds, animatedBounds] {
            XCTAssertEqual(bounds.midX, 64, accuracy: 1)
            XCTAssertEqual(bounds.midY, 64, accuracy: 1)
            XCTAssertEqual(bounds.width, 64 * 1.08, accuracy: 1)
            XCTAssertEqual(bounds.height, 64 * 1.08, accuracy: 1)
        }
        XCTAssertEqual(animatedBounds.midX, idleBounds.midX, accuracy: 0.5)
        XCTAssertEqual(animatedBounds.midY, idleBounds.midY, accuracy: 0.5)
        XCTAssertEqual(animatedBounds.width, idleBounds.width, accuracy: 0.5)
        XCTAssertEqual(animatedBounds.height, idleBounds.height, accuracy: 0.5)
    }

    func testRunningSessionStartsFramesAndIdleStopsThem() async {
        let dockTile = TestDockTile()
        var frameTime: TimeInterval = 100
        let controller = DockTileController(
            dockTile: dockTile,
            baseIcon: makeOpaqueDockIcon(),
            reduceMotionProvider: { false },
            frameTimeProvider: { frameTime }
        )
        let appState = AppState()
        controller.start(observing: appState)
        defer { controller.stop() }

        XCTAssertFalse(controller.isAnimating)

        var session = SessionSnapshot()
        session.source = "codex"
        session.status = .running
        appState.sessions["dock-animation"] = session
        appState.refreshDerivedState()
        await Task.yield()

        XCTAssertTrue(controller.isAnimating)
        XCTAssertEqual(controller.renderedFrameTime, 100)
        let displayCountAfterStart = dockTile.displayCount
        frameTime = 101
        try? await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertGreaterThan(dockTile.displayCount, displayCountAfterStart)
        XCTAssertEqual(controller.renderedFrameTime, 101)

        appState.sessions["dock-animation"]?.status = .idle
        appState.refreshDerivedState()
        await Task.yield()

        XCTAssertFalse(controller.isAnimating)
        XCTAssertEqual(controller.renderedFrameTime, 0)
    }

    func testRunningSessionPublishesDifferentRenderedDockFrames() async {
        let dockTile = TestDockTile(capturesDisplayedFrames: true)
        var frameTime: TimeInterval = 0
        let controller = DockTileController(
            dockTile: dockTile,
            baseIcon: makeOpaqueDockIcon(),
            reduceMotionProvider: { false },
            frameTimeProvider: { frameTime },
            reconciliationInterval: 60
        )
        let appState = AppState()
        controller.start(observing: appState)
        defer { controller.stop() }

        appState.sessions["dock-rendered-frames"] = makeSession(
            source: "codex",
            status: .running
        )
        appState.refreshDerivedState()
        await Task.yield()

        frameTime = 0.1
        controller.animationTimer?.fire()
        await Task.yield()

        XCTAssertGreaterThanOrEqual(dockTile.displayedFrameFingerprints.count, 2)
        XCTAssertGreaterThan(
            Set(dockTile.displayedFrameFingerprints).count,
            1,
            "A running Dock mascot must publish visibly different frames, not only advance its timer."
        )
    }

    func testReduceMotionKeepsSwiftUIMascotStatic() async {
        let dockTile = TestDockTile()
        let controller = DockTileController(
            dockTile: dockTile,
            baseIcon: NSImage(size: NSSize(width: 128, height: 128)),
            reduceMotionProvider: { true }
        )
        let appState = AppState()
        controller.start(observing: appState)
        defer { controller.stop() }

        var session = SessionSnapshot()
        session.source = "codex"
        session.status = .running
        appState.sessions["dock-reduce-motion"] = session
        appState.refreshDerivedState()
        await Task.yield()

        XCTAssertFalse(controller.isAnimating)
        XCTAssertNotNil(dockTile.contentView)
    }

    func testMultipleAgentsRotateInsideDockIconAndKeepTotalBadge() async {
        let dockTile = TestDockTile()
        let controller = DockTileController(
            dockTile: dockTile,
            baseIcon: NSImage(size: NSSize(width: 128, height: 128)),
            reduceMotionProvider: { false },
            rotationInterval: 60
        )
        let appState = AppState()
        appState.sessions["cursor"] = makeSession(source: "cursor", status: .processing)
        appState.sessions["codex"] = makeSession(source: "codex", status: .processing)
        appState.sessions["claude"] = makeSession(source: "claude", status: .processing)
        controller.start(observing: appState)
        defer { controller.stop() }

        XCTAssertTrue(controller.isRotating)
        XCTAssertEqual(controller.displayedSource, "claude")
        XCTAssertEqual(dockTile.badgeLabel, "3")

        controller.rotationTimer?.fire()
        await Task.yield()
        XCTAssertEqual(controller.displayedSource, "codex")
        XCTAssertEqual(dockTile.badgeLabel, "3")

        controller.rotationTimer?.fire()
        await Task.yield()
        XCTAssertEqual(controller.displayedSource, "cursor")
        XCTAssertEqual(dockTile.badgeLabel, "3")
    }

    func testRotationPreservesCurrentAgentWhenCandidateSetChanges() async {
        let dockTile = TestDockTile()
        let controller = DockTileController(
            dockTile: dockTile,
            baseIcon: NSImage(size: NSSize(width: 128, height: 128)),
            reduceMotionProvider: { false },
            rotationInterval: 60
        )
        let appState = AppState()
        appState.sessions["cursor"] = makeSession(source: "cursor", status: .processing)
        appState.sessions["codex"] = makeSession(source: "codex", status: .processing)
        appState.sessions["claude"] = makeSession(source: "claude", status: .processing)
        controller.start(observing: appState)
        defer { controller.stop() }

        controller.rotationTimer?.fire()
        await Task.yield()
        XCTAssertEqual(controller.displayedSource, "codex")

        appState.sessions.removeValue(forKey: "claude")
        await Task.yield()

        XCTAssertEqual(controller.displayedSource, "codex")
        XCTAssertEqual(dockTile.badgeLabel, "2")
        controller.rotationTimer?.fire()
        await Task.yield()
        XCTAssertEqual(controller.displayedSource, "cursor")
    }

    func testReduceMotionDisablesSourceRotation() async {
        let dockTile = TestDockTile()
        let controller = DockTileController(
            dockTile: dockTile,
            baseIcon: NSImage(size: NSSize(width: 128, height: 128)),
            reduceMotionProvider: { true },
            rotationInterval: 0.05
        )
        let appState = AppState()
        appState.sessions["claude"] = makeSession(source: "claude", status: .processing)
        appState.sessions["codex"] = makeSession(source: "codex", status: .processing)
        controller.start(observing: appState)
        defer { controller.stop() }

        XCTAssertFalse(controller.isRotating)
        XCTAssertEqual(controller.displayedSource, "claude")
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(controller.displayedSource, "claude")
    }

    func testSessionMutationStartsAnimationWithoutRefreshingCachedState() async {
        let dockTile = TestDockTile()
        let controller = DockTileController(
            dockTile: dockTile,
            baseIcon: NSImage(size: NSSize(width: 128, height: 128)),
            reduceMotionProvider: { false },
            reconciliationInterval: 0.05
        )
        let appState = AppState()
        controller.start(observing: appState)
        defer { controller.stop() }

        var session = SessionSnapshot()
        session.source = "codex"
        session.status = .running
        appState.sessions["dock-direct-session-state"] = session

        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(appState.status, .idle, "The test must leave the cached aggregate stale")
        XCTAssertTrue(controller.isAnimating)
        XCTAssertEqual(dockTile.badgeLabel, "1")
    }

    func testReconciliationRestartsAnInvalidatedFrameTimer() async {
        let dockTile = TestDockTile()
        let controller = DockTileController(
            dockTile: dockTile,
            baseIcon: NSImage(size: NSSize(width: 128, height: 128)),
            reduceMotionProvider: { false },
            reconciliationInterval: 0.05
        )
        let appState = AppState()
        controller.start(observing: appState)
        defer { controller.stop() }

        var session = SessionSnapshot()
        session.source = "codex"
        session.status = .running
        appState.sessions["dock-restart-timer"] = session
        appState.refreshDerivedState()
        await Task.yield()
        XCTAssertTrue(controller.isAnimating)

        let invalidatedTimer = controller.animationTimer
        invalidatedTimer?.invalidate()
        XCTAssertFalse(controller.isAnimating)

        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(controller.isAnimating)
        XCTAssertFalse(controller.animationTimer === invalidatedTimer)
    }

    func testReconciliationRestartsAnInvalidatedRotationTimer() async {
        let dockTile = TestDockTile()
        let controller = DockTileController(
            dockTile: dockTile,
            baseIcon: NSImage(size: NSSize(width: 128, height: 128)),
            reduceMotionProvider: { false },
            reconciliationInterval: 0.05,
            rotationInterval: 60
        )
        let appState = AppState()
        appState.sessions["claude"] = makeSession(source: "claude", status: .processing)
        appState.sessions["codex"] = makeSession(source: "codex", status: .processing)
        controller.start(observing: appState)
        defer { controller.stop() }

        XCTAssertTrue(controller.isRotating)
        let invalidatedTimer = controller.rotationTimer
        invalidatedTimer?.invalidate()
        XCTAssertFalse(controller.isRotating)

        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(controller.isRotating)
        XCTAssertFalse(controller.rotationTimer === invalidatedTimer)
    }

    func testRepeatedActiveIdleTransitionsKeepAnimationResponsive() async {
        let dockTile = TestDockTile()
        let controller = DockTileController(
            dockTile: dockTile,
            baseIcon: NSImage(size: NSSize(width: 128, height: 128)),
            reduceMotionProvider: { false },
            reconciliationInterval: 0.05
        )
        let appState = AppState()
        controller.start(observing: appState)
        defer { controller.stop() }

        var session = SessionSnapshot()
        session.source = "codex"
        session.status = .running
        appState.sessions["dock-repeated-transition"] = session
        await Task.yield()
        XCTAssertTrue(controller.isAnimating)

        appState.sessions["dock-repeated-transition"]?.status = .idle
        await Task.yield()
        XCTAssertFalse(controller.isAnimating)

        appState.sessions["dock-repeated-transition"]?.status = .processing
        await Task.yield()
        XCTAssertTrue(controller.isAnimating)
    }
}

private func makeSession(source: String, status: AgentStatus) -> SessionSnapshot {
    var session = SessionSnapshot()
    session.source = source
    session.status = status
    return session
}

private func makeOpaqueDockIcon(size: NSSize = NSSize(width: 128, height: 128)) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    image.unlockFocus()
    return image
}

private func makeInsetDockIcon(size: NSSize = NSSize(width: 128, height: 128)) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.clear.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    NSColor.white.setFill()
    NSBezierPath(
        rect: NSRect(
            x: size.width * 0.25,
            y: size.height * 0.25,
            width: size.width * 0.5,
            height: size.height * 0.5
        )
    ).fill()
    image.unlockFocus()
    return image
}

@MainActor
private func renderedAlphaBounds(from dockTile: TestDockTile) -> NSRect? {
    guard let imageView = dockTile.contentView as? NSImageView,
          let image = imageView.image,
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return nil }

    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    var minX = bitmap.pixelsWide
    var minY = bitmap.pixelsHigh
    var maxX = -1
    var maxY = -1

    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 else { continue }
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }

    guard maxX >= minX, maxY >= minY else { return nil }
    let xScale = image.size.width / CGFloat(bitmap.pixelsWide)
    let yScale = image.size.height / CGFloat(bitmap.pixelsHigh)
    return NSRect(
        x: CGFloat(minX) * xScale,
        y: CGFloat(minY) * yScale,
        width: CGFloat(maxX - minX + 1) * xScale,
        height: CGFloat(maxY - minY + 1) * yScale
    )
}

@MainActor
private final class TestDockTile: DockTileDisplaying {
    let size = NSSize(width: 128, height: 128)
    var contentView: NSView?
    var badgeLabel: String?
    private(set) var displayCount = 0
    private let capturesDisplayedFrames: Bool
    private(set) var displayedFrameFingerprints: [Data] = []

    init(capturesDisplayedFrames: Bool = false) {
        self.capturesDisplayedFrames = capturesDisplayedFrames
    }

    func display() {
        displayCount += 1
        guard capturesDisplayedFrames, let contentView else { return }

        if let imageView = contentView as? NSImageView,
           let image = imageView.image,
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let png = NSBitmapImageRep(cgImage: cgImage)
               .representation(using: .png, properties: [:]) {
            displayedFrameFingerprints.append(png)
            return
        }

        guard !contentView.bounds.isEmpty,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
        else { return }

        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            displayedFrameFingerprints.append(png)
        }
    }
}
