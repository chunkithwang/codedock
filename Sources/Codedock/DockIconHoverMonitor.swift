import AppKit
import ApplicationServices

struct DockHoverElementIdentity: Equatable {
    let role: String?
    let subrole: String?
    let title: String?
    let anchorPoint: NSPoint?

    init(
        role: String?,
        subrole: String?,
        title: String?,
        anchorPoint: NSPoint? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.anchorPoint = anchorPoint
    }
}

enum DockIconHoverMatcher {
    static func matches(_ element: DockHoverElementIdentity?, appName: String) -> Bool {
        guard let element, element.role == "AXDockItem" else { return false }
        if let subrole = element.subrole, subrole != "AXApplicationDockItem" {
            return false
        }

        let expectedName = normalized(appName)
        let actualName = normalized(element.title ?? "")
        return !expectedName.isEmpty && actualName == expectedName
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum DockCoordinateSpace {
    static func appKitCenter(
        accessibilityPosition: CGPoint,
        size: CGSize,
        menuBarScreenMaxY: CGFloat
    ) -> NSPoint {
        NSPoint(
            x: accessibilityPosition.x + size.width / 2,
            y: menuBarScreenMaxY - accessibilityPosition.y - size.height / 2
        )
    }
}

@MainActor
final class DockIconHoverMonitor {
    private static let pollingInterval: TimeInterval = 0.1

    private let appName: String
    private let accessibilityTrustedProvider: () -> Bool
    private let accessibilityPrompt: () -> Void
    private let cursorLocationProvider: () -> CGPoint?
    private let hoveredElementProvider: (CGPoint) -> DockHoverElementIdentity?
    private let anchorPointProvider: () -> NSPoint
    private let onHoverExit: () -> Void
    private let onHoverEnter: (NSPoint) -> Void

    private(set) var hoverTimer: Timer?
    private(set) var isHoveringAppIcon = false

    init(
        appName: String,
        accessibilityTrustedProvider: @escaping () -> Bool = { AXIsProcessTrusted() },
        accessibilityPrompt: @escaping () -> Void = DockAccessibility.promptIfNeeded,
        cursorLocationProvider: @escaping () -> CGPoint? = {
            CGEvent(source: nil)?.location
        },
        hoveredElementProvider: @escaping (CGPoint) -> DockHoverElementIdentity? = {
            DockAccessibility.elementIdentity(at: $0)
        },
        anchorPointProvider: @escaping () -> NSPoint = { NSEvent.mouseLocation },
        onHoverExit: @escaping () -> Void = {},
        onHoverEnter: @escaping (NSPoint) -> Void
    ) {
        self.appName = appName
        self.accessibilityTrustedProvider = accessibilityTrustedProvider
        self.accessibilityPrompt = accessibilityPrompt
        self.cursorLocationProvider = cursorLocationProvider
        self.hoveredElementProvider = hoveredElementProvider
        self.anchorPointProvider = anchorPointProvider
        self.onHoverExit = onHoverExit
        self.onHoverEnter = onHoverEnter
    }

    func start(promptForAccessibility: Bool = true) {
        guard hoverTimer?.isValid != true else { return }
        if promptForAccessibility && !accessibilityTrustedProvider() {
            accessibilityPrompt()
        }

        let timer = Timer(timeInterval: Self.pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkCurrentHover()
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
        checkCurrentHover()
    }

    func stop() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        isHoveringAppIcon = false
    }

    func checkCurrentHover() {
        guard accessibilityTrustedProvider(),
              let cursorLocation = cursorLocationProvider() else {
            let didExit = isHoveringAppIcon
            isHoveringAppIcon = false
            if didExit { onHoverExit() }
            return
        }

        let element = hoveredElementProvider(cursorLocation)
        let isHovering = DockIconHoverMatcher.matches(element, appName: appName)
        let didEnter = isHovering && !isHoveringAppIcon
        let didExit = !isHovering && isHoveringAppIcon
        isHoveringAppIcon = isHovering

        if didEnter {
            onHoverEnter(element?.anchorPoint ?? anchorPointProvider())
        } else if didExit {
            onHoverExit()
        }
    }
}

private enum DockAccessibility {
    static func promptIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func elementIdentity(at point: CGPoint) -> DockHoverElementIdentity? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var hoveredElement: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(point.y),
            &hoveredElement
        )
        guard result == .success, let hoveredElement else { return nil }

        return DockHoverElementIdentity(
            role: stringAttribute(kAXRoleAttribute as CFString, from: hoveredElement),
            subrole: stringAttribute(kAXSubroleAttribute as CFString, from: hoveredElement),
            title: stringAttribute(kAXTitleAttribute as CFString, from: hoveredElement),
            anchorPoint: appKitCenter(of: hoveredElement)
        )
    }

    private static func appKitCenter(of element: AXUIElement) -> NSPoint? {
        guard let position = pointAttribute(kAXPositionAttribute as CFString, from: element),
              let size = sizeAttribute(kAXSizeAttribute as CFString, from: element),
              let menuBarScreen = NSScreen.screens.first else { return nil }

        return DockCoordinateSpace.appKitCenter(
            accessibilityPosition: position,
            size: size,
            menuBarScreenMaxY: menuBarScreen.frame.maxY
        )
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func pointAttribute(_ attribute: CFString, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let accessibilityValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetType(accessibilityValue) == .cgPoint,
              AXValueGetValue(accessibilityValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(_ attribute: CFString, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let accessibilityValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetType(accessibilityValue) == .cgSize,
              AXValueGetValue(accessibilityValue, .cgSize, &size) else { return nil }
        return size
    }
}
