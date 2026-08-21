import AppKit
import ScreenCaptureKit


/// Result of an area selection. `rect` is in global AppKit coordinates (origin bottom-left);
/// `screen` is the screen the drag happened on. `wantsFullScreen` is set when the user
/// pressed ⏎ to choose the whole screen instead of dragging.
struct SelectionResult {
    let rect: CGRect
    let screen: NSScreen
    var wantsFullScreen: Bool = false
}

/// Full-screen dimming overlay with crosshair + drag-to-select, shown on every display.
@MainActor
final class SelectionOverlayController {
    private static var current: SelectionOverlayController?

    private var windows: [SelectionWindow] = []
    private let completion: @MainActor (SelectionResult?) -> Void
    private var finished = false
    private var keyMonitor: Any?

    /// True while the space bar is held; dragging then moves the selection instead of resizing.
    private(set) var isSpaceDown = false

    static func selectRect(prompt: String? = nil, completion: @escaping @MainActor (SelectionResult?) -> Void) {
        // Only one selection session at a time.
        current?.finish(with: nil)
        let controller = SelectionOverlayController(completion: completion)
        current = controller
        controller.present(prompt: prompt)
    }

    private init(completion: @escaping @MainActor (SelectionResult?) -> Void) {
        self.completion = completion
    }

    private func present(prompt: String?) {
        for screen in NSScreen.screens {
            let window = SelectionWindow(screen: screen, controller: self, prompt: prompt)
            windows.append(window)
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        if let mouseScreen = NSScreen.underMouse,
           let window = windows.first(where: { $0.assignedScreen == mouseScreen }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            windows.first?.makeKeyAndOrderFront(nil)
        }
        installKeyMonitor()
        if SettingsStore.shared.showMagnifier {
            Task { @MainActor in await self.loadLoupeSources() }
        }
    }

    /// One-shot per-screen capture (own windows excluded, so pixels are undimmed)
    /// that backs the magnifier loupe. Skipped silently when Screen Recording
    /// permission is missing — the overlay works fine without it.
    private func loadLoupeSources() async {
        guard let content = try? await CaptureEngine.shareableContent() else { return }
        let ownApp = content.applications.first { $0.processID == getpid() }
        for window in windows {
            guard !finished else { return }
            guard let display = content.displays.first(where: { $0.displayID == window.assignedScreen.displayID })
            else { continue }
            let filter: SCContentFilter
            if let ownApp {
                filter = SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: [])
            } else {
                filter = SCContentFilter(display: display, excludingWindows: [])
            }
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                          configuration: config),
                  !finished
            else { continue }
            (window.contentView as? SelectionView)?.setLoupeSource(image)
        }
    }

    func finish(with result: SelectionResult?) {
        guard !finished else { return }
        finished = true
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        SelectionOverlayController.current = nil
        completion(result)
    }

    // MARK: - Key handling

    /// Backup monitor so ⎋ cancels even when a non-key overlay window has the cursor,
    /// and so space (move-selection modifier) is tracked without keyboard focus games.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return event }
                switch (event.type, event.keyCode) {
                case (.keyDown, 53): // Escape
                    self.finish(with: nil)
                    return nil
                case (.keyDown, 49): // Space held → move mode
                    self.isSpaceDown = true
                    return nil
                case (.keyUp, 49):
                    self.isSpaceDown = false
                    return nil
                default:
                    return event
                }
            }
        }
    }

}

final class SelectionWindow: NSWindow {
    let assignedScreen: NSScreen

    init(screen: NSScreen, controller: SelectionOverlayController, prompt: String?) {
        assignedScreen = screen
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                 controller: controller, screen: screen, prompt: prompt)
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

final class SelectionView: NSView {
    private weak var controller: SelectionOverlayController?
    private let screen: NSScreen
    private let prompt: String?

    private var dragStart: NSPoint?
    private var currentPoint: NSPoint?
    private var isDragging = false
    private var trackingArea: NSTrackingArea?
    private var loupeSource: CGImage?

    func setLoupeSource(_ image: CGImage) {
        loupeSource = image
        needsDisplay = true
    }


    init(frame: NSRect, controller: SelectionOverlayController?, screen: NSScreen, prompt: String?) {
        self.controller = controller
        self.screen = screen
        self.prompt = prompt
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Snapshot-only setup used by DebugSnapshotController. It exercises the same
    /// selection drawing code without synthesizing a screenshot of the desktop.
    func setDebugSelection(start: NSPoint, current: NSPoint) {
        dragStart = start
        currentPoint = current
        isDragging = true
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private var selectionRect: NSRect? {
        guard let dragStart, let currentPoint else { return nil }
        return NSRect(x: min(dragStart.x, currentPoint.x),
                      y: min(dragStart.y, currentPoint.y),
                      width: abs(dragStart.x - currentPoint.x),
                      height: abs(dragStart.y - currentPoint.y))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        currentPoint = dragStart
        isDragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if controller?.isSpaceDown == true, let previous = currentPoint, let start = dragStart {
            // Space held: translate the whole selection instead of resizing it.
            dragStart = NSPoint(x: start.x + (point.x - previous.x),
                                y: start.y + (point.y - previous.y))
        }
        currentPoint = point
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        currentPoint = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        // Space-drag can push the selection past the screen edge; clamp to what
        // is actually capturable so the source rect stays on the display.
        guard let raw = selectionRect else {
            controller?.finish(with: nil)
            return
        }
        let rect = raw.intersection(bounds)
        guard rect.width >= 4, rect.height >= 4 else {
            controller?.finish(with: nil)
            return
        }
        // View coords are window coords; window fills the screen, so offset by its origin.
        guard let windowOrigin = window?.frame.origin else {
            controller?.finish(with: nil)
            return
        }
        let global = rect.offsetBy(dx: windowOrigin.x, dy: windowOrigin.y)
        controller?.finish(with: SelectionResult(rect: global, screen: screen))
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            controller?.finish(with: nil)
        case 36, 76: // Return / keypad Enter → full screen (the one under the cursor)
            let target = NSScreen.underMouse ?? screen
            controller?.finish(with: SelectionResult(rect: target.frame, screen: target, wantsFullScreen: true))
        case 49: // Space — handled by the controller's event monitor
            break
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.25)

        if let rect = selectionRect, isDragging {
            // Dim everything except the selection; prompt stays hidden while dragging.
            let path = NSBezierPath(rect: bounds)
            path.appendRect(rect)
            path.windingRule = .evenOdd
            dim.setFill()
            path.fill()

            // Dual stroke — dark outer, white inner — so the border reads on any background.
            NSColor.black.withAlphaComponent(0.35).setStroke()
            let outerBorder = NSBezierPath(rect: rect.insetBy(dx: -1.5, dy: -1.5))
            outerBorder.lineWidth = 1
            outerBorder.stroke()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
            drawCornerTicks(for: rect)

            drawSizeLabel(for: rect)
            if let currentPoint {
                drawLoupe(at: currentPoint)
            }
        } else {
            dim.setFill()
            bounds.fill()
            if let currentPoint {
                drawCrosshair(at: currentPoint)
                drawLoupe(at: currentPoint)
            }
            drawPrompt()
        }
    }

    /// Magnifier loupe: an 8x zoomed circle of the pixels around the cursor, drawn
    /// from the one-shot screen capture taken when the overlay appeared.
    private func drawLoupe(at point: NSPoint) {
        guard let source = loupeSource else { return }
        let diameter: CGFloat = 120
        let zoom: CGFloat = 8

        var origin = NSPoint(x: point.x + 24, y: point.y + 24)
        if origin.x + diameter > bounds.maxX - 8 { origin.x = point.x - diameter - 24 }
        if origin.y + diameter > bounds.maxY - 8 { origin.y = point.y - diameter - 24 }
        origin.x = max(origin.x, bounds.minX + 8)
        origin.y = max(origin.y, bounds.minY + 8)
        let loupeRect = NSRect(x: origin.x, y: origin.y, width: diameter, height: diameter)

        // View point → source pixels (CGImage origin is top-left).
        let scaleX = CGFloat(source.width) / bounds.width
        let scaleY = CGFloat(source.height) / bounds.height
        let cropSide = diameter / zoom
        let cropPixel = CGRect(x: (point.x - cropSide / 2) * scaleX,
                               y: (bounds.height - point.y - cropSide / 2) * scaleY,
                               width: cropSide * scaleX,
                               height: cropSide * scaleY)
        guard let crop = source.cropping(to: cropPixel) else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: loupeRect).addClip()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: crop, size: loupeRect.size)
            .draw(in: loupeRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        // Dual ring + center pixel indicator, matching the selection border style.
        NSColor.black.withAlphaComponent(0.4).setStroke()
        let outerRing = NSBezierPath(ovalIn: loupeRect.insetBy(dx: -1.25, dy: -1.25))
        outerRing.lineWidth = 2.5
        outerRing.stroke()
        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: loupeRect)
        ring.lineWidth = 1.5
        ring.stroke()
        let pixelBox = NSRect(x: loupeRect.midX - zoom / 2, y: loupeRect.midY - zoom / 2,
                              width: zoom, height: zoom)
        NSBezierPath(rect: pixelBox).stroke()
    }

    /// Short white ticks at the selection corners so the active rect reads at a glance.
    private func drawCornerTicks(for rect: NSRect) {
        guard rect.width >= 32, rect.height >= 32 else { return }
        let length: CGFloat = 12
        let ticks = NSBezierPath()
        ticks.lineWidth = 2
        let corners: [(NSPoint, CGFloat, CGFloat)] = [
            (NSPoint(x: rect.minX, y: rect.minY), 1, 1),
            (NSPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (NSPoint(x: rect.minX, y: rect.maxY), 1, -1),
            (NSPoint(x: rect.maxX, y: rect.maxY), -1, -1),
        ]
        for (corner, dx, dy) in corners {
            ticks.move(to: NSPoint(x: corner.x + dx * length, y: corner.y))
            ticks.line(to: corner)
            ticks.line(to: NSPoint(x: corner.x, y: corner.y + dy * length))
        }
        NSColor.white.setStroke()
        ticks.stroke()
    }

    private func drawCrosshair(at point: NSPoint) {
        NSColor.white.withAlphaComponent(0.6).setStroke()
        let horizontal = NSBezierPath()
        horizontal.move(to: NSPoint(x: 0, y: point.y))
        horizontal.line(to: NSPoint(x: bounds.maxX, y: point.y))
        horizontal.lineWidth = 1
        horizontal.stroke()
        let vertical = NSBezierPath()
        vertical.move(to: NSPoint(x: point.x, y: 0))
        vertical.line(to: NSPoint(x: point.x, y: bounds.maxY))
        vertical.lineWidth = 1
        vertical.stroke()
    }


    private func drawSizeLabel(for rect: NSRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        // Centered below the selection, flipped above when clipped; keeps clear of the
        // drag corner (where the cursor sits) far better than corner anchoring.
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 14)
        if origin.y < bounds.minY + 4 { origin.y = rect.minY + 8 }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)

        var background = NSRect(x: origin.x - 9, y: origin.y - 4, width: size.width + 18, height: size.height + 8)
        // If the cursor would sit on the pill, hop to the top edge of the selection.
        if let currentPoint, background.insetBy(dx: -12, dy: -12).contains(currentPoint) {
            origin.y = min(rect.maxY + 14, bounds.maxY - size.height - 8)
            background.origin.y = origin.y - 4
        }

        let pill = NSBezierPath(roundedRect: background,
                                xRadius: background.height / 2, yRadius: background.height / 2)
        NSColor.black.withAlphaComponent(0.72).setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.22).setStroke()
        pill.lineWidth = 0.5
        pill.stroke()
        text.draw(at: origin, withAttributes: attributes)
    }

    private func drawPrompt() {
        let text = prompt ?? "Drag to select an area — ⎋ to cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 80)
        let background = NSRect(x: origin.x - 14, y: origin.y - 8, width: size.width + 28, height: size.height + 16)
        let chip = NSBezierPath(roundedRect: background,
                                xRadius: background.height / 2, yRadius: background.height / 2)

        // Heads-up chip: soft shadow, dark translucent fill, hairline highlight border.
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -2), blur: 12,
                              color: NSColor.black.withAlphaComponent(0.35).cgColor)
            NSColor.black.withAlphaComponent(0.65).setFill()
            chip.fill()
            context.restoreGState()
        } else {
            NSColor.black.withAlphaComponent(0.65).setFill()
            chip.fill()
        }
        NSColor.white.withAlphaComponent(0.18).setStroke()
        chip.lineWidth = 0.5
        chip.stroke()
        text.draw(at: origin, withAttributes: attributes)
    }
}
