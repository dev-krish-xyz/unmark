import AppKit
import SwiftUI

/// Location of the camera housing on the built-in display, in global screen coordinates.
struct NotchGeometry: Equatable {
    let screenID: CGDirectDisplayID
    let rect: CGRect

    /// Nil when no connected display has a notch (older Macs, external-only, clamshell).
    static func current() -> NotchGeometry? {
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
                  let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { continue }
            let frame = screen.frame
            let width = frame.width - left.width - right.width
            let height = screen.safeAreaInsets.top
            guard width > 0 else { continue }
            // Round inward so the sensor never overlaps usable menu bar pixels.
            let minX = (frame.minX + left.width).rounded(.up)
            let maxX = (frame.minX + left.width + width).rounded(.down)
            let rect = CGRect(x: minX, y: frame.maxY - height, width: maxX - minX, height: height)
            return NotchGeometry(screenID: id, rect: rect)
        }
        return nil
    }
}

/// Borderless, non-activating panel that never becomes key or appears in window cycling.
private final class IslandPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        // Above the menu bar, below pop-up menus. No .fullScreenAuxiliary, so the island is
        // never drawn over full-screen apps.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Fills exactly the camera housing (pixels that do not exist), so it never covers menu bar items.
private final class SensorView: NSView {
    var onHoverChange: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func draw(_ dirtyRect: NSRect) {
        // Nearly transparent fill keeps the window hit-testable; it sits behind the camera housing.
        NSColor.black.withAlphaComponent(0.01).setFill()
        dirtyRect.fill()
    }
}

/// Owns the two notch panels: a hover sensor and a click-through display.
@MainActor
final class NotchController {
    private let model: AppModel
    private var geometry: NotchGeometry?
    private var sensor: IslandPanel?
    private var display: IslandPanel?

    init(model: AppModel) {
        self.model = model
    }

    var hasNotch: Bool { geometry != nil }

    /// Recomputes geometry and shows, moves or removes the panels. Call on launch and on any
    /// display configuration change.
    func update() {
        let newGeometry = NotchGeometry.current()
        guard newGeometry != geometry || (newGeometry != nil && display == nil) else {
            applyHoverPreference()
            return
        }
        teardown()
        geometry = newGeometry
        guard let geometry else { return }

        let metrics = IslandMetrics(notch: geometry.rect.size)
        let canvas = metrics.canvas
        let displayFrame = CGRect(x: geometry.rect.midX - canvas.width / 2, y: geometry.rect.maxY - canvas.height,
                                  width: canvas.width, height: canvas.height)
        let display = IslandPanel(frame: displayFrame)
        display.ignoresMouseEvents = true
        let hosting = NSHostingView(rootView: NotchView(model: model, metrics: metrics))
        hosting.sizingOptions = []
        display.contentView = hosting
        display.orderFrontRegardless()
        self.display = display

        let sensor = IslandPanel(frame: geometry.rect)
        sensor.ignoresMouseEvents = false
        let view = SensorView(frame: CGRect(origin: .zero, size: geometry.rect.size))
        view.onHoverChange = { [weak self] inside in
            guard let self else { return }
            inside ? self.model.hoverBegan() : self.model.hoverEnded()
        }
        sensor.contentView = view
        self.sensor = sensor
        applyHoverPreference()
    }

    func applyHoverPreference() {
        guard let sensor else { return }
        if Preferences.hoverToClean {
            sensor.orderFrontRegardless()
        } else {
            sensor.orderOut(nil)
            model.hoverEnded()
        }
    }

    func teardown() {
        sensor?.close()
        display?.close()
        sensor = nil
        display = nil
        geometry = nil
    }
}
