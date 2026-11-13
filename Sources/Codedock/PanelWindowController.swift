import AppKit
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.codedock", category: "Panel")

private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Ensures first click on a nonactivatingPanel fires SwiftUI actions
/// instead of being consumed for key-window activation.
/// Also guards against NSHostingView constraint-update re-entrancy crash:
/// during updateConstraints(), SwiftUI may invalidate the view graph and
/// call setNeedsUpdateConstraints again, which AppKit forbids.
private class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// When true, the deferred handler is setting super — don't re-defer.
    private var applyingDeferred = false

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Always defer `needsUpdateConstraints = true` to the next run-loop turn.
    /// During AppKit's display-cycle (constraint-update or layout phases),
    /// calling setNeedsUpdateConstraints synchronously re-enters
    /// `_postWindowNeedsUpdateConstraints` and throws.  Deferring avoids
    /// that entirely; the one-tick delay is imperceptible.
    override var needsUpdateConstraints: Bool {
        get { super.needsUpdateConstraints }
        set {
            if applyingDeferred {
                super.needsUpdateConstraints = newValue
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.applySuperNeedsUpdateConstraints(newValue)
            }
        }
    }

    private func applySuperNeedsUpdateConstraints(_ value: Bool) {
        applyingDeferred = true
        super.needsUpdateConstraints = value
        applyingDeferred = false
    }

    override var needsLayout: Bool {
        get { super.needsLayout }
        set {
            if applyingDeferred {
                super.needsLayout = newValue
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.applySuperNeedsLayout(newValue)
            }
        }
    }

    private func applySuperNeedsLayout(_ value: Bool) {
        applyingDeferred = true
        super.needsLayout = value
        applyingDeferred = false
    }
}

struct PanelScreenHopFrames {
    let outgoing: NSRect
    let incoming: NSRect
}

struct PanelScreenHopMotion {
    let outgoingOffset: CGFloat
    let incomingOffset: CGFloat
    let fadeOutDuration: TimeInterval
    let incomingPauseDuration: TimeInterval
    let fadeInDuration: TimeInterval
}

enum DockPopupEdge: Equatable {
    case bottom
    case left
    case right
}

enum DockPopupLayout {
    static let edgeGap: CGFloat = 8
    /// Space between the visible-frame edge and the popup body. The Dock's
    /// magnified icons can extend beyond `NSScreen.visibleFrame`.
    static let bottomMagnificationClearance: CGFloat = 32
    /// Covers a 14pt shadow shifted down by 5pt without clipping its fade.
    static let bottomShadowInset: CGFloat = 20
}

enum DockHoverAutoCollapse {
    static func shouldSchedule(
        openedByDockHover: Bool,
        isDockIconHovered: Bool,
        isPopupHovered: Bool,
        collapseOnMouseLeave: Bool,
        surface: IslandSurface
    ) -> Bool {
        openedByDockHover
            && !isDockIconHovered
            && !isPopupHovered
            && collapseOnMouseLeave
            && surface == .sessionList
    }
}

@MainActor
class PanelWindowController: NSObject, NSWindowDelegate {
    private enum ScreenHopMetrics {
        static let outgoingOffset: CGFloat = 18
        static let incomingOffset: CGFloat = 30
        static let fadeOutDuration: TimeInterval = 0.14
        static let incomingPauseDuration: TimeInterval = 0.06
        static let fadeInDuration: TimeInterval = 0.34
    }

    nonisolated static func screenHopMotion() -> PanelScreenHopMotion {
        PanelScreenHopMotion(
            outgoingOffset: ScreenHopMetrics.outgoingOffset,
            incomingOffset: ScreenHopMetrics.incomingOffset,
            fadeOutDuration: ScreenHopMetrics.fadeOutDuration,
            incomingPauseDuration: ScreenHopMetrics.incomingPauseDuration,
            fadeInDuration: ScreenHopMetrics.fadeInDuration
        )
    }

    private var panel: NSPanel?
    private var hostingView: NotchHostingView<NotchPanelView>?
    private let appState: AppState
    private var dockAnchorPoint: NSPoint?
    private var lastDockPopupEdge: DockPopupEdge = .bottom

    nonisolated static func screenHopFrames(
        oldFrame: NSRect,
        newFrame: NSRect
    ) -> PanelScreenHopFrames {
        let motion = screenHopMotion()
        return PanelScreenHopFrames(
            outgoing: oldFrame.offsetBy(dx: 0, dy: motion.outgoingOffset),
            incoming: newFrame.offsetBy(dx: 0, dy: motion.incomingOffset)
        )
    }

    nonisolated static func isPointInDockArea(
        _ point: NSPoint,
        screenFrame: NSRect,
        visibleFrame: NSRect
    ) -> Bool {
        guard screenFrame.contains(point) else { return false }

        let dockOnLeft = visibleFrame.minX > screenFrame.minX && point.x < visibleFrame.minX
        let dockOnRight = visibleFrame.maxX < screenFrame.maxX && point.x > visibleFrame.maxX
        let dockOnBottom = visibleFrame.minY > screenFrame.minY && point.y < visibleFrame.minY
        return dockOnLeft || dockOnRight || dockOnBottom
    }

    nonisolated static func dockEdge(
        screenFrame: NSRect,
        visibleFrame: NSRect
    ) -> DockPopupEdge {
        let leftInset = max(0, visibleFrame.minX - screenFrame.minX)
        let rightInset = max(0, screenFrame.maxX - visibleFrame.maxX)
        let bottomInset = max(0, visibleFrame.minY - screenFrame.minY)

        if leftInset > bottomInset && leftInset >= rightInset {
            return .left
        }
        if rightInset > bottomInset && rightInset > leftInset {
            return .right
        }
        return .bottom
    }

    /// Resolves the Dock edge from the click position. The proximity fallback
    /// covers auto-hidden Docks, whose reserved visible-frame inset is zero.
    nonisolated static func dockEdgeForAnchor(
        _ point: NSPoint,
        screenFrame: NSRect,
        visibleFrame: NSRect,
        proximity: CGFloat = 96
    ) -> DockPopupEdge? {
        guard screenFrame.contains(point) else { return nil }

        if visibleFrame.minX > screenFrame.minX && point.x < visibleFrame.minX {
            return .left
        }
        if visibleFrame.maxX < screenFrame.maxX && point.x > visibleFrame.maxX {
            return .right
        }
        if visibleFrame.minY > screenFrame.minY && point.y < visibleFrame.minY {
            return .bottom
        }

        let candidates: [(DockPopupEdge, CGFloat)] = [
            (.left, point.x - screenFrame.minX),
            (.right, screenFrame.maxX - point.x),
            (.bottom, point.y - screenFrame.minY),
        ]
        guard let nearest = candidates.min(by: { $0.1 < $1.1 }),
              nearest.1 <= proximity else { return nil }
        return nearest.0
    }

    nonisolated static func dockPopupFrame(
        size: NSSize,
        anchorPoint: NSPoint,
        edge: DockPopupEdge,
        visibleFrame: NSRect,
        gap: CGFloat = DockPopupLayout.edgeGap
    ) -> NSRect {
        let minX = visibleFrame.minX + gap
        let maxX = max(minX, visibleFrame.maxX - size.width - gap)
        let minY = visibleFrame.minY + gap
        let maxY = max(minY, visibleFrame.maxY - size.height - gap)
        let clampX: (CGFloat) -> CGFloat = { min(max($0, minX), maxX) }
        let clampY: (CGFloat) -> CGFloat = { min(max($0, minY), maxY) }

        let origin: NSPoint
        switch edge {
        case .bottom:
            // Position the popup body at the requested clearance while leaving
            // enough window space below it for the shadow to fade naturally.
            let magnificationSafeY = minY
                + DockPopupLayout.bottomMagnificationClearance
                - DockPopupLayout.bottomShadowInset
            origin = NSPoint(
                x: clampX(anchorPoint.x - size.width / 2),
                y: min(magnificationSafeY, maxY)
            )
        case .left:
            origin = NSPoint(
                x: minX,
                y: clampY(anchorPoint.y - size.height / 2)
            )
        case .right:
            origin = NSPoint(
                x: maxX,
                y: clampY(anchorPoint.y - size.height / 2)
            )
        }

        return NSRect(origin: origin, size: size)
    }

    private func panelSize(for screen: NSScreen) -> NSSize {
        let maxSessions = CGFloat(max(2, UserDefaults.standard.integer(forKey: SettingsKey.maxVisibleSessions)))
        let maxH = max(320, maxSessions * 90 + 92)
        let visibleFrame = screen.visibleFrame
        let width = min(620, max(1, visibleFrame.width - 24))
        let height = min(maxH, max(1, visibleFrame.height - 24))
        return NSSize(width: width, height: height)
    }

    private var panelSize: NSSize {
        panelSize(for: chosenScreen())
    }

    private var visibilityTimer: Timer?
    private var autoScreenPoller: Timer?
    private var fullscreenPoller: Timer?
    private var sessionObservationTask: Task<Void, Never>?
    private var fullscreenLatch = false
    private var settingsObservers: [NSObjectProtocol] = []
    private var globalClickMonitor: Any?
    private var lastChosenScreenSignature = ""
    private var isAnimatingScreenHop = false
    private var dragStartMouseX: CGFloat?
    private var dragStartPanelX: CGFloat?
    private var isDraggingPanel = false
    private var localDragMonitor: Any?
    private var dockHoverCollapseTask: Task<Void, Never>?
    private var isDockIconHovered = false
    private var isPopupHovered = false
    private var openedByDockHover = false
    private var lastDisplayChoice = ""
    private var lastNotchHeightMode = SettingsDefaults.notchHeightMode
    private var lastCustomNotchHeight = SettingsDefaults.customNotchHeight

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func showPanel(anchorPoint: NSPoint? = nil) {
        if let anchorPoint {
            rememberDockAnchor(anchorPoint)
        }
        let screen = chosenScreen()
        let contentView = makeHostingView(for: screen)
        self.hostingView = contentView

        let size = panelSize
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.acceptsMouseMovedEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .readOnly
        panel.contentView = contentView
        panel.delegate = self

        self.panel = panel
        self.lastChosenScreenSignature = ScreenDetector.signature(for: screen)
        self.lastDockPopupEdge = currentDockPopupEdge(for: screen)

        setupHorizontalDragMonitor()
        updatePosition()
        updateVisibility()

        // Screen change observer
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCurrentScreen(forceRebuild: true)
                // macOS may not have finished updating NSScreen.screens when the notification fires.
                // Rebuild again after a short delay to pick up the final screen configuration.
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.refreshCurrentScreen(forceRebuild: true)
            }
        }

        // Active space change — check fullscreen
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.refreshCurrentScreen()
                if self.isActiveSpaceFullscreen() {
                    self.fullscreenLatch = true
                    self.updateVisibility()
                    self.startFullscreenExitPoller()
                } else {
                    // Non-fullscreen space: clear any stale latch immediately so the panel
                    // doesn't stay hidden for up to 1.5s while the exit poller catches up (#104).
                    if self.fullscreenLatch {
                        self.fullscreenLatch = false
                        self.fullscreenPoller?.invalidate()
                        self.fullscreenPoller = nil
                    }
                    self.updateVisibility()
                }
            }
        }

        // Frontmost app change
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.refreshCurrentScreen()
                if !self.fullscreenLatch { self.updateVisibility() }
            }
        }

        // Observe session changes via @Observable tracking
        sessionObservationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                withObservationTracking {
                    _ = self?.appState.sessions
                    _ = self?.appState.surface
                } onChange: {
                    Task { @MainActor in self?.updateVisibility() }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        // Observe settings changes (display choice, panel height)
        observeSettingsChanges()
        configureAutoScreenPolling()

        // Global click monitor: close panel + repost click when clicking outside
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self = self, self.appState.surface.isExpanded else { return }
                // Don't close during approval/question
                switch self.appState.surface {
                case .approvalCard, .questionCard: return
                default: break
                }
                // Don't collapse if click is within the panel frame (event leaked on external display)
                if let panelFrame = self.panel?.frame {
                    let clickLocation = NSEvent.mouseLocation
                    if panelFrame.contains(clickLocation) { return }
                    if self.isDockAreaClick(clickLocation) { return }
                }
                withAnimation(NotchAnimation.close) {
                    self.appState.surface = .collapsed
                    self.appState.cancelCompletionQueue()
                }
                self.updateVisibility()
            }
        }
    }

    func revealForUserInteraction(anchorPoint: NSPoint? = nil) {
        guard let panel else { return }
        if let anchorPoint {
            rememberDockAnchor(anchorPoint)
        }
        refreshCurrentScreen()
        updatePosition()
        panel.orderFrontRegardless()
        MascotAnimationGate.shared.setPanelVisible(true)
    }

    func dockIconHoverDidEnter(openedPanel: Bool) {
        isDockIconHovered = true
        dockHoverCollapseTask?.cancel()
        dockHoverCollapseTask = nil
        if openedPanel {
            openedByDockHover = true
        }
    }

    func dockIconHoverDidExit() {
        isDockIconHovered = false
        scheduleDockHoverCollapseIfNeeded()
    }

    func refreshVisibility() {
        updateVisibility()
    }

    private func rememberDockAnchor(_ point: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              Self.dockEdgeForAnchor(
                point,
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame
              ) != nil else { return }
        dockAnchorPoint = point
    }

    private func isDockAreaClick(_ point: NSPoint) -> Bool {
        NSScreen.screens.contains { screen in
            Self.dockEdgeForAnchor(
                point,
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame
            ) != nil
        }
    }

    private func makeHostingView(for screen: NSScreen) -> NotchHostingView<NotchPanelView> {
        let hasNotch = ScreenDetector.screenHasNotch(screen)
        let notchHeight = ScreenDetector.topBarHeight(for: screen)
        let notchW = ScreenDetector.notchWidth(for: screen)

        let rootView = NotchPanelView(
            appState: appState,
            hasNotch: hasNotch,
            notchHeight: notchHeight,
            notchW: notchW,
            screenWidth: screen.frame.width,
            popupEdge: currentDockPopupEdge(for: screen),
            onHoverChanged: { [weak self] hovering in
                self?.popupHoverDidChange(hovering)
            }
        )
        let contentView = NotchHostingView(rootView: rootView)
        contentView.sizingOptions = []
        contentView.translatesAutoresizingMaskIntoConstraints = true
        return contentView
    }

    /// Rebuild the SwiftUI view when the target screen changes
    /// (notchHeight, notchWidth, hasNotch may be different)
    private func rebuildForCurrentScreen(_ screen: NSScreen) {
        guard let panel = panel else { return }
        let contentView = makeHostingView(for: screen)
        self.hostingView = contentView
        panel.contentView = contentView
        lastChosenScreenSignature = ScreenDetector.signature(for: screen)
        lastDockPopupEdge = currentDockPopupEdge(for: screen)
        updatePosition()
    }

    private func refreshCurrentScreen(forceRebuild: Bool = false) {
        if isAnimatingScreenHop { return }

        let screen = chosenScreen()
        let signature = ScreenDetector.signature(for: screen)
        let popupEdge = currentDockPopupEdge(for: screen)

        if forceRebuild || popupEdge != lastDockPopupEdge {
            rebuildForCurrentScreen(screen)
            return
        }

        if signature != lastChosenScreenSignature {
            animateScreenHop(to: screen, signature: signature)
        }
    }

    private func animateScreenHop(to screen: NSScreen, signature: String) {
        guard let panel = panel else {
            rebuildForCurrentScreen(screen)
            return
        }

        if !panel.isVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            rebuildForCurrentScreen(screen)
            panel.alphaValue = 1
            return
        }

        isAnimatingScreenHop = true
        let oldFrame = panel.frame
        let newFrame = panelFrame(for: screen)
        let motion = Self.screenHopMotion()
        let frames = Self.screenHopFrames(oldFrame: oldFrame, newFrame: newFrame)
        let targetSignature = signature

        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(frames.outgoing, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard let panel = self.panel else {
                    self.isAnimatingScreenHop = false
                    return
                }

                let targetScreen = NSScreen.screens.first {
                    ScreenDetector.signature(for: $0) == targetSignature
                } ?? self.chosenScreen()

                self.rebuildForCurrentScreen(targetScreen)
                panel.alphaValue = 0
                panel.setFrame(frames.incoming, display: true)

                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(motion.incomingPauseDuration * 1_000_000_000))
                    guard let self = self else { return }
                    guard let panel = self.panel else {
                        self.isAnimatingScreenHop = false
                        return
                    }

                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = motion.fadeInDuration
                        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
                        panel.animator().alphaValue = 1
                        panel.animator().setFrame(newFrame, display: true)
                    } completionHandler: { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.lastChosenScreenSignature = targetSignature
                            self?.isAnimatingScreenHop = false
                        }
                    }
                }
            }
        }
    }

    private func observeSettingsChanges() {
        lastDisplayChoice = SettingsManager.shared.displayChoice
        lastNotchHeightMode = SettingsManager.shared.notchHeightMode.rawValue
        lastCustomNotchHeight = SettingsManager.shared.customNotchHeight
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let newChoice = SettingsManager.shared.displayChoice
                let newHeightMode = SettingsManager.shared.notchHeightMode.rawValue
                let newCustomHeight = SettingsManager.shared.customNotchHeight
                if newChoice != self.lastDisplayChoice {
                    self.lastDisplayChoice = newChoice
                    self.refreshCurrentScreen(forceRebuild: true)
                    self.configureAutoScreenPolling()
                } else if newHeightMode != self.lastNotchHeightMode
                    || abs(newCustomHeight - self.lastCustomNotchHeight) > 0.001 {
                    self.lastNotchHeightMode = newHeightMode
                    self.lastCustomNotchHeight = newCustomHeight
                    self.refreshCurrentScreen(forceRebuild: true)
                } else {
                    self.updateVisibility()
                    self.updatePosition()
                }
            }
        }
        settingsObservers.append(observer)
    }

    private func configureAutoScreenPolling() {
        autoScreenPoller?.invalidate()
        autoScreenPoller = nil

        guard SettingsManager.shared.displayChoice == "auto" else { return }

        // Screen-parameter / Space-change / frontmost-app notifications already cover the
        // common cases. This poller is a fallback for the rare path where a window is
        // dragged to another display without switching focus — a low cadence is enough
        // and every tick runs a full CGWindowListCopyWindowInfo, which was measurably
        // contributing to Energy Impact (#92).
        autoScreenPoller = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCurrentScreen()
            }
        }
    }

    private func updatePosition() {
        guard let panel = panel else { return }
        let screen = chosenScreen()
        panel.setFrame(panelFrame(for: screen), display: true)
    }

    private func panelFrame(for screen: NSScreen) -> NSRect {
        let size = panelSize(for: screen)
        let edge = currentDockPopupEdge(for: screen)
        let anchor = dockAnchorPoint.flatMap { screen.frame.contains($0) ? $0 : nil }
            ?? defaultDockAnchor(on: screen, edge: edge)
        var frame = Self.dockPopupFrame(
            size: size,
            anchorPoint: anchor,
            edge: edge,
            visibleFrame: screen.visibleFrame
        )

        let dragOffset = SettingsManager.shared.allowHorizontalDrag
            ? CGFloat(SettingsManager.shared.panelHorizontalOffset)
            : 0
        if edge == .bottom && dockAnchorPoint == nil && dragOffset != 0 {
            frame.origin.x = clampedX(
                frame.origin.x + dragOffset,
                panelWidth: size.width,
                on: screen
            )
        }
        return frame
    }

    private func defaultDockAnchor(on screen: NSScreen, edge: DockPopupEdge) -> NSPoint {
        switch edge {
        case .bottom:
            return NSPoint(x: screen.visibleFrame.midX, y: screen.frame.minY)
        case .left:
            return NSPoint(x: screen.frame.minX, y: screen.visibleFrame.midY)
        case .right:
            return NSPoint(x: screen.frame.maxX, y: screen.visibleFrame.midY)
        }
    }

    private func clampedX(_ desiredX: CGFloat, panelWidth: CGFloat, on screen: NSScreen) -> CGFloat {
        let gap = DockPopupLayout.edgeGap
        let visibleFrame = screen.visibleFrame
        let minX = visibleFrame.minX + gap
        let maxX = max(minX, visibleFrame.maxX - panelWidth - gap)
        return min(max(desiredX, minX), maxX)
    }

    private func setupHorizontalDragMonitor() {
        let dragThreshold: CGFloat = 5

        localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let panel = self.panel,
                  SettingsManager.shared.allowHorizontalDrag,
                  self.dockAnchorPoint == nil,
                  self.currentDockPopupEdge(for: self.chosenScreen()) == .bottom else { return event }

            switch event.type {
            case .leftMouseDown:
                if event.window === panel {
                    self.dragStartMouseX = NSEvent.mouseLocation.x
                    self.dragStartPanelX = panel.frame.origin.x
                    self.isDraggingPanel = false
                }
            case .leftMouseDragged:
                if let startMouseX = self.dragStartMouseX,
                   let startPanelX = self.dragStartPanelX {
                    let deltaX = NSEvent.mouseLocation.x - startMouseX
                    // Only start moving after exceeding threshold
                    if !self.isDraggingPanel {
                        guard abs(deltaX) > dragThreshold else { return event }
                        self.isDraggingPanel = true
                    }
                    let screen = self.chosenScreen()
                    let size = panel.frame.size
                    let newX = self.clampedX(startPanelX + deltaX, panelWidth: size.width, on: screen)
                    let fixedY = self.panelFrame(for: screen).origin.y
                    panel.setFrameOrigin(NSPoint(x: newX, y: fixedY))
                }
            case .leftMouseUp:
                if self.isDraggingPanel, let panel = self.panel {
                    let screen = self.chosenScreen()
                    let size = panel.frame.size
                    let edge = self.currentDockPopupEdge(for: screen)
                    let anchor = self.dockAnchorPoint.flatMap { screen.frame.contains($0) ? $0 : nil }
                        ?? self.defaultDockAnchor(on: screen, edge: edge)
                    let baseX = Self.dockPopupFrame(
                        size: size,
                        anchorPoint: anchor,
                        edge: edge,
                        visibleFrame: screen.visibleFrame
                    ).origin.x
                    let offset = panel.frame.origin.x - baseX
                    SettingsManager.shared.panelHorizontalOffset = Double(offset)
                }
                self.dragStartMouseX = nil
                self.dragStartPanelX = nil
                self.isDraggingPanel = false
            default:
                break
            }
            return event
        }
    }

    /// Choose which screen to display on based on displayChoice setting
    private func chosenScreen() -> NSScreen {
        if let anchor = dockAnchorPoint,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) {
            return screen
        }

        let choice = SettingsManager.shared.displayChoice

        // Handle specific screen index: "screen_0", "screen_1", etc.
        if choice.hasPrefix("screen_"),
           let index = Int(choice.dropFirst(7)),
           index < NSScreen.screens.count {
            return NSScreen.screens[index]
        }

        // "auto" — prefer notch screen, fallback to main
        return ScreenDetector.preferredScreen
    }

    private func currentDockPopupEdge(for screen: NSScreen) -> DockPopupEdge {
        if let anchor = dockAnchorPoint,
           screen.frame.contains(anchor),
           let edge = Self.dockEdgeForAnchor(
            anchor,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
           ) {
            return edge
        }
        return Self.dockEdge(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
    }

    /// Poll every 1.5s while in fullscreen; stop when fullscreen ends
    private func startFullscreenExitPoller() {
        fullscreenPoller?.invalidate()
        fullscreenPoller = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else { timer.invalidate(); return }
                if !self.isActiveSpaceFullscreen() {
                    self.fullscreenLatch = false
                    self.updateVisibility()
                    timer.invalidate()
                    self.fullscreenPoller = nil
                }
            }
        }
    }

    /// Update panel visibility based on settings
    private func updateVisibility() {
        guard let panel = panel else { return }
        if appState.surface != .sessionList {
            openedByDockHover = false
            dockHoverCollapseTask?.cancel()
            dockHoverCollapseTask = nil
        }
        let settings = SettingsManager.shared
        if settings.hideInFullscreen && fullscreenLatch {
            panel.orderOut(nil)
            MascotAnimationGate.shared.setPanelVisible(false)
            return
        }

        if !appState.surface.isExpanded {
            panel.orderOut(nil)
            MascotAnimationGate.shared.setPanelVisible(false)
            return
        }

        updatePosition()
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        MascotAnimationGate.shared.setPanelVisible(true)
    }

    private func popupHoverDidChange(_ hovering: Bool) {
        isPopupHovered = hovering
        if hovering {
            dockHoverCollapseTask?.cancel()
            dockHoverCollapseTask = nil
        } else {
            scheduleDockHoverCollapseIfNeeded()
        }
    }

    private func scheduleDockHoverCollapseIfNeeded() {
        dockHoverCollapseTask?.cancel()
        dockHoverCollapseTask = nil

        guard DockHoverAutoCollapse.shouldSchedule(
            openedByDockHover: openedByDockHover,
            isDockIconHovered: isDockIconHovered,
            isPopupHovered: isPopupHovered,
            collapseOnMouseLeave: SettingsManager.shared.collapseOnMouseLeave,
            surface: appState.surface
        ) else { return }

        dockHoverCollapseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(NotchHoverInteraction.collapseDelay * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self, DockHoverAutoCollapse.shouldSchedule(
                openedByDockHover: self.openedByDockHover,
                isDockIconHovered: self.isDockIconHovered,
                isPopupHovered: self.isPopupHovered,
                collapseOnMouseLeave: SettingsManager.shared.collapseOnMouseLeave,
                surface: self.appState.surface
            ) else { return }

            self.openedByDockHover = false
            withAnimation(NotchAnimation.close) {
                self.appState.surface = .collapsed
                self.appState.cancelCompletionQueue()
            }
            self.updateVisibility()
        }
    }

    private func isActiveSpaceFullscreen() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }

        let screen = chosenScreen()

        // Primary: check if frontmost app has a window covering the entire screen
        if let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] {
            for window in windowList {
                guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                      pid == frontApp.processIdentifier,
                      let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                      let bounds = window[kCGWindowBounds as String] as? [String: Any],
                      let w = bounds["Width"] as? CGFloat,
                      let h = bounds["Height"] as? CGFloat else { continue }
                if w >= screen.frame.width && h >= screen.frame.height {
                    return true
                }
            }
        }

        return false
    }

    /// Fast check: is the terminal running the active session the foreground app?
    /// Main-thread safe — no AppleScript or subprocess calls.
    func isActiveTerminalForeground() -> Bool {
        guard let sessionId = appState.activeSessionId,
              let session = appState.sessions[sessionId],
              session.termApp != nil else { return false }
        return TerminalVisibilityDetector.isTerminalFrontmostForSession(session)
    }

    func windowDidMove(_ notification: Notification) {
        // Drag is handled by setupHorizontalDragMonitor — no correction needed here.
    }

    deinit {
        dockHoverCollapseTask?.cancel()
        autoScreenPoller?.invalidate()
        fullscreenPoller?.invalidate()
        for observer in settingsObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localDragMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
