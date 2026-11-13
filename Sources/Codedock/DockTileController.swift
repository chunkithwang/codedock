import AppKit
import CodedockCore
import Observation
import SwiftUI

enum DockTileMode: Equatable {
    case idle
    case working
    case approval
    case question
    case completion
}

struct DockTilePresentation: Equatable {
    let mode: DockTileMode
    let source: String
    let badgeLabel: String?

    var shouldAnimate: Bool { mode != .idle }

    static func make(
        status: AgentStatus,
        source: String,
        activeSessionCount: Int,
        hasCompletion: Bool
    ) -> DockTilePresentation {
        let mode: DockTileMode
        switch status {
        case .waitingApproval:
            mode = .approval
        case .waitingQuestion:
            mode = .question
        case .processing, .running:
            mode = .working
        case .idle:
            mode = hasCompletion ? .completion : .idle
        }

        let badgeLabel: String?
        switch activeSessionCount {
        case ...0:
            badgeLabel = nil
        case 1...99:
            badgeLabel = String(activeSessionCount)
        default:
            badgeLabel = "99+"
        }

        return DockTilePresentation(
            mode: mode,
            source: source,
            badgeLabel: badgeLabel
        )
    }
}

struct DockTileActivity: Equatable {
    let status: AgentStatus
    let rotationSources: [String]
    let activeSessionCount: Int
}

/// Build a stable, source-level rotation list for the highest-priority active
/// state. Multiple sessions from the same Agent share one Dock turn.
func deriveDockTileActivity(from sessions: [String: SessionSnapshot]) -> DockTileActivity {
    let summary = deriveSessionSummary(from: sessions)
    guard summary.status != .idle else {
        return DockTileActivity(
            status: .idle,
            rotationSources: [],
            activeSessionCount: summary.activeSessionCount
        )
    }

    let sources = Set(
        sessions.values.lazy
            .filter { $0.status == summary.status }
            .map(\.source)
    ).sorted { lhs, rhs in
        let normalizedLeft = lhs.lowercased()
        let normalizedRight = rhs.lowercased()
        if normalizedLeft != normalizedRight {
            return normalizedLeft < normalizedRight
        }
        return lhs < rhs
    }

    return DockTileActivity(
        status: summary.status,
        rotationSources: sources,
        activeSessionCount: summary.activeSessionCount
    )
}

enum DockTileGeometry {
    /// A custom NSDockTile content view is optically smaller than the Dock's
    /// normal application-icon rendering. Enlarge the shared icon canvas just
    /// enough to remove that double-inset while preserving the asset's own
    /// transparent safety margin. Idle and animated states both use this rect.
    private static let iconScale: CGFloat = 1.08
    private static let mascotScale: CGFloat = 0.74
    /// Clawd's visible work-scene pixels are slightly left-heavy even though
    /// its SwiftUI frame is geometrically centered. Shift the frame by the
    /// measured visual-center delta so the black gutters read evenly.
    private static let clawdWorkingCorrection: CGFloat = 0.013
    /// These work scenes share a 16-column viewport whose visible art spans
    /// columns 0...15. Their frames are geometrically centered, but the extra
    /// right-side column makes the rendered pixels read left-heavy. The value
    /// below is measured across multiple animation frames and sources.
    private static let leftHeavyWorkingCorrection: CGFloat = 0.030
    private static let leftHeavyWorkingSources: Set<String> = [
        "gemini", "google-antigravity",
        "cursor", "cursor-cli",
        "trae", "traecn", "traecli",
        "copilot",
        "qoder", "qoder-cli", "qoderwork",
        "droid",
        "codebuddy", "codybuddycn",
        "stepfun",
        "opencode",
        "qwen",
        "antigravity",
        "workbuddy",
        "hermes",
        "kimi",
        "pi", "omp",
    ]
    private static let centeredWorkingSources: Set<String> = [
        "codex", "cline", "kiro", "openclaw",
    ]

    static func iconRect(in bounds: NSRect) -> NSRect {
        let width = bounds.width * iconScale
        let height = bounds.height * iconScale
        return NSRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    /// Preserve the mascot-to-icon proportion when the shared icon canvas is
    /// optically enlarged. This keeps every agent consistent with the idle icon.
    static func mascotSize(in bounds: NSRect) -> CGFloat {
        let iconRect = iconRect(in: bounds)
        return min(iconRect.width, iconRect.height) * mascotScale
    }

    static func mascotRect(
        in bounds: NSRect,
        source: String,
        mode: DockTileMode
    ) -> NSRect {
        let side = mascotSize(in: bounds)
        let horizontalCorrection = side * horizontalCorrectionRatio(
            source: source,
            mode: mode
        )
        return NSRect(
            x: bounds.midX - side / 2 + horizontalCorrection,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )
    }

    private static func horizontalCorrectionRatio(
        source: String,
        mode: DockTileMode
    ) -> CGFloat {
        // Approval/question scenes have symmetric glow and alert geometry.
        // Applying the work-scene correction there would move them off-center.
        guard mode == .working || mode == .completion else { return 0 }

        let normalizedSource = source.lowercased()
        if leftHeavyWorkingSources.contains(normalizedSource) {
            return leftHeavyWorkingCorrection
        }
        if centeredWorkingSources.contains(normalizedSource) {
            return 0
        }
        // MascotView routes every unrecognized source to Clawd, so fallback
        // agents such as ZCode need the same measured correction as Claude.
        return clawdWorkingCorrection
    }
}

@MainActor
protocol DockTileDisplaying: AnyObject {
    var size: NSSize { get }
    var contentView: NSView? { get set }
    var badgeLabel: String? { get set }
    func display()
}

extension NSDockTile: DockTileDisplaying {}

@MainActor
final class DockTileController {
    /// Match MascotTimeline's effective 20 fps floor. NSDockTile does not keep
    /// an off-window TimelineView ticking, so this timer owns Dock frame time.
    private static let frameInterval: TimeInterval = 1.0 / 20.0
    private let dockTile: any DockTileDisplaying
    private let tileView: NSImageView
    private let baseIcon: NSImage
    private let reduceMotionProvider: () -> Bool
    private let frameTimeProvider: () -> TimeInterval
    private let reconciliationInterval: TimeInterval
    private let rotationInterval: TimeInterval
    private weak var appState: AppState?
    private(set) var animationTimer: Timer?
    private(set) var rotationTimer: Timer?
    private var reconciliationTimer: Timer?
    private(set) var renderedFrameTime: TimeInterval = 0
    private var presentation = DockTilePresentation(
        mode: .idle,
        source: "claude",
        badgeLabel: nil
    )
    private var rotationSources: [String] = []
    private var rotationIndex = 0
    private var isSystemAwake = true
    private var workspaceObservers: [NSObjectProtocol] = []

    var isAnimating: Bool { animationTimer?.isValid == true }
    var isRotating: Bool { rotationTimer?.isValid == true }
    var displayedSource: String { presentation.source }

    init(
        dockTile: any DockTileDisplaying,
        baseIcon: NSImage,
        reduceMotionProvider: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        },
        frameTimeProvider: @escaping () -> TimeInterval = {
            Date().timeIntervalSinceReferenceDate
        },
        reconciliationInterval: TimeInterval = 1.0,
        rotationInterval: TimeInterval = 2.0
    ) {
        self.dockTile = dockTile
        self.baseIcon = baseIcon
        self.reduceMotionProvider = reduceMotionProvider
        self.frameTimeProvider = frameTimeProvider
        self.reconciliationInterval = reconciliationInterval
        self.rotationInterval = rotationInterval
        let tileView = NSImageView(frame: NSRect(origin: .zero, size: dockTile.size))
        tileView.imageScaling = .scaleAxesIndependently
        tileView.image = baseIcon
        self.tileView = tileView
    }

    func start(observing appState: AppState) {
        self.appState = appState
        tileView.frame = NSRect(origin: .zero, size: dockTile.size)
        tileView.autoresizingMask = [.width, .height]
        tileView.wantsLayer = true
        tileView.layer?.backgroundColor = NSColor.clear.cgColor
        dockTile.contentView = tileView
        installWorkspaceObservers()
        observeAppState()
        startReconciliationTimer()
    }

    func stop() {
        animationTimer?.invalidate()
        animationTimer = nil
        rotationTimer?.invalidate()
        rotationTimer = nil
        rotationSources = []
        rotationIndex = 0
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil
        appState = nil

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()

        dockTile.badgeLabel = nil
        dockTile.contentView = nil
        dockTile.display()
    }

    private func observeAppState() {
        guard let appState else { return }

        let nextPresentation = withObservationTracking {
            makePresentation(from: appState)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeAppState()
            }
        }

        apply(nextPresentation)
    }

    /// Derive the Dock state from the source-of-truth sessions. AppState keeps
    /// cached aggregate fields for the rest of the UI, but the Dock tile must
    /// recover even if a mutation path temporarily misses refreshDerivedState().
    private func makePresentation(from appState: AppState) -> DockTilePresentation {
        let activity = deriveDockTileActivity(from: appState.sessions)
        let source = updateRotationSources(
            activity.rotationSources,
            fallbackSource: appState.primarySource
        )

        return DockTilePresentation.make(
            status: activity.status,
            source: source,
            activeSessionCount: activity.activeSessionCount,
            hasCompletion: appState.glanceCompletionActive || appState.justCompletedSessionId != nil
        )
    }

    /// Preserve the currently visible Agent when possible so session updates do
    /// not restart the carousel or cause an unrelated visual jump.
    private func updateRotationSources(
        _ nextSources: [String],
        fallbackSource: String
    ) -> String {
        let currentSource = presentation.source
        rotationSources = nextSources

        if let currentIndex = nextSources.firstIndex(of: currentSource) {
            rotationIndex = currentIndex
            return currentSource
        }

        rotationIndex = 0
        return nextSources.first ?? fallbackSource
    }

    private func apply(_ nextPresentation: DockTilePresentation) {
        presentation = nextPresentation
        dockTile.badgeLabel = nextPresentation.badgeLabel
        renderCurrentFrame()
        updateAnimationTimer()
        updateRotationTimer()
        dockTile.display()
    }

    private var reduceMotion: Bool {
        reduceMotionProvider()
    }

    private var shouldAnimateMascot: Bool {
        presentation.shouldAnimate && !reduceMotion && isSystemAwake
    }

    private func makeContent() -> DockTileContent {
        DockTileContent(
            presentation: presentation,
            baseIcon: baseIcon,
            tileSize: dockTile.size,
            animationTime: renderedFrameTime
        )
    }

    private func updateAnimationTimer() {
        guard shouldAnimateMascot else {
            let needsStaticRefresh = animationTimer != nil || renderedFrameTime != 0
            animationTimer?.invalidate()
            animationTimer = nil
            renderedFrameTime = 0
            if needsStaticRefresh {
                renderCurrentFrame()
                dockTile.display()
            }
            return
        }

        if animationTimer?.isValid == true { return }
        animationTimer?.invalidate()
        animationTimer = nil

        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDockTile()
            }
        }
        timer.tolerance = Self.frameInterval / 8
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
        refreshDockTile()
    }

    private var shouldRotateSources: Bool {
        rotationSources.count > 1 && !reduceMotion && isSystemAwake
    }

    private func updateRotationTimer() {
        guard shouldRotateSources else {
            rotationTimer?.invalidate()
            rotationTimer = nil
            return
        }

        if rotationTimer?.isValid == true { return }
        rotationTimer?.invalidate()
        rotationTimer = nil

        let timer = Timer(timeInterval: rotationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advanceRotation()
            }
        }
        timer.tolerance = min(rotationInterval / 10, 0.1)
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    private func advanceRotation() {
        guard shouldRotateSources else {
            updateRotationTimer()
            return
        }

        rotationIndex = (rotationIndex + 1) % rotationSources.count
        let nextSource = rotationSources[rotationIndex]
        guard nextSource != presentation.source else { return }

        presentation = DockTilePresentation(
            mode: presentation.mode,
            source: nextSource,
            badgeLabel: presentation.badgeLabel
        )
        renderCurrentFrame()
        dockTile.display()
    }

    private func startReconciliationTimer() {
        guard reconciliationTimer?.isValid != true else { return }
        reconciliationTimer?.invalidate()

        // Observation is still the fast path, but this low-frequency check
        // recovers if a callback or frame timer is dropped in the background.
        let timer = Timer(timeInterval: reconciliationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileDockTile()
            }
        }
        timer.tolerance = min(reconciliationInterval / 5, 0.2)
        RunLoop.main.add(timer, forMode: .common)
        reconciliationTimer = timer
    }

    private func reconcileDockTile() {
        guard let appState else { return }

        let nextPresentation = makePresentation(from: appState)
        let contentViewWasDetached = dockTile.contentView !== tileView
        if contentViewWasDetached {
            dockTile.contentView = tileView
        }

        if nextPresentation != presentation {
            apply(nextPresentation)
            return
        }

        var needsDisplay = contentViewWasDetached
        if dockTile.badgeLabel != nextPresentation.badgeLabel {
            dockTile.badgeLabel = nextPresentation.badgeLabel
            needsDisplay = true
        }
        updateAnimationTimer()
        updateRotationTimer()
        if needsDisplay {
            renderCurrentFrame()
            dockTile.display()
        }
    }

    private func refreshDockTile() {
        renderedFrameTime = frameTimeProvider()
        renderCurrentFrame()
        dockTile.display()
    }

    /// NSDockTile snapshots `contentView` synchronously. Updating an off-window
    /// NSHostingView's root only schedules a later SwiftUI render, so the Dock
    /// kept receiving the same stale pixels while the frame timer advanced.
    /// ImageRenderer produces the requested timeline frame immediately, and
    /// NSImageView gives AppKit a concrete bitmap to snapshot.
    private func renderCurrentFrame() {
        let renderer = ImageRenderer(content: makeContent())
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        renderer.proposedSize = ProposedViewSize(
            width: dockTile.size.width,
            height: dockTile.size.height
        )
        if let image = renderer.nsImage {
            image.size = dockTile.size
            tileView.image = image
        }
        tileView.needsDisplay = true
    }

    private func installWorkspaceObservers() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.setSystemAwake(false)
                }
            })
        }

        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.setSystemAwake(true)
                }
            })
        }

        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                renderCurrentFrame()
                updateAnimationTimer()
                updateRotationTimer()
                dockTile.display()
            }
        })
    }

    private func setSystemAwake(_ isAwake: Bool) {
        guard isSystemAwake != isAwake else {
            // A duplicate wake notification is still a useful opportunity to
            // recover a frame timer that did not survive display sleep.
            if isAwake {
                updateAnimationTimer()
                updateRotationTimer()
            }
            return
        }
        isSystemAwake = isAwake
        renderCurrentFrame()
        updateAnimationTimer()
        updateRotationTimer()
        dockTile.display()
    }
}

private struct DockTileContent: View {
    let presentation: DockTilePresentation
    let baseIcon: NSImage
    let tileSize: NSSize
    let animationTime: TimeInterval

    var body: some View {
        Group {
            if presentation.mode == .idle {
                baseIconView
            } else {
                animatedIconView
            }
        }
        .frame(width: tileSize.width, height: tileSize.height)
        .clipped()
    }

    private var baseIconView: some View {
        Image(nsImage: baseIcon)
            .resizable()
            .interpolation(.high)
            .frame(width: iconRect.width, height: iconRect.height)
            .position(x: iconRect.midX, y: iconRect.midY)
            .frame(width: tileSize.width, height: tileSize.height)
    }

    private var animatedIconView: some View {
        ZStack(alignment: .center) {
            // The black fill is masked by the real app icon, so it changes the
            // animation background without introducing another shape.
            Color.black

            MascotView(
                source: presentation.source,
                status: mascotStatus,
                size: mascotSize,
                animationsActiveOverride: false,
                timelineReferenceTimeOverride: animationTime
            )
            .frame(
                width: mascotRect.width,
                height: mascotRect.height,
                alignment: .center
            )
            .position(x: mascotRect.midX, y: mascotRect.midY)
        }
        .frame(width: tileSize.width, height: tileSize.height)
        .mask(baseIconView)
    }

    private var mascotRect: NSRect {
        DockTileGeometry.mascotRect(
            in: NSRect(origin: .zero, size: tileSize),
            source: presentation.source,
            mode: presentation.mode
        )
    }

    private var iconRect: NSRect {
        DockTileGeometry.iconRect(in: NSRect(origin: .zero, size: tileSize))
    }

    private var mascotSize: CGFloat { mascotRect.width }

    private var mascotStatus: MascotAgentStatus {
        switch presentation.mode {
        case .idle:
            return .idle
        case .working, .completion:
            return .processing
        case .approval:
            return .waitingApproval
        case .question:
            return .waitingQuestion
        }
    }
}
