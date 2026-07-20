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
        loadLoupeSources()
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

    // MARK: - Loupe source

    /// One-shot full-display capture per screen, used as the magnifier's zoom source.
    /// Excludes our own overlay windows so the loupe shows true, undimmed pixels.
    /// Silently skipped when capture fails (e.g. no screen-recording permission).
    private func loadLoupeSources() {
        let excludedIDs = windows.map { CGWindowID($0.windowNumber) }
        let targets = windows
        Task { @MainActor in
            guard let content = try? await CaptureEngine.shareableContent() else { return }
            let excluded = content.windows.filter { excludedIDs.contains($0.windowID) }
            for window in targets {
                guard !self.finished else { return }
                guard let display = try? CaptureEngine.display(for: window.assignedScreen, in: content) else { continue }
                let filter = SCContentFilter(display: display, excludingWindows: excluded)
                let config = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                config.width = Int(filter.contentRect.width * scale)
                config.height = Int(filter.contentRect.height * scale)
                config.showsCursor = false
                config.captureResolution = .best
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                              configuration: config) else { continue }
                guard !self.finished else { return }
                (window.contentView as? SelectionView)?.loupeSource = image
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

    /// Full-display capture used as the magnifier source; nil until it arrives (or never, without permission).
    var loupeSource: CGImage? {
        didSet { needsDisplay = true }
    }

    init(frame: NSRect, controller: SelectionOverlayController, screen: NSScreen, prompt: String?) {
        self.controller = controller
        self.screen = screen
        self.prompt = prompt
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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

            NSColor.white.setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()

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

    /// Magnifier loupe: a circle showing an 8× zoom of the captured pixels around
    /// the cursor, with a box marking the exact pixel under it. Skipped until the
    /// one-shot display capture arrives.
    private func drawLoupe(at point: NSPoint) {
        guard let source = loupeSource, bounds.width > 0 else { return }
        let diameter: CGFloat = 120
        let zoom: CGFloat = 8
        let offset: CGFloat = 24

        var origin = NSPoint(x: point.x + offset, y: point.y + offset)
        if origin.x + diameter > bounds.maxX { origin.x = point.x - offset - diameter }
        if origin.y + diameter > bounds.maxY { origin.y = point.y - offset - diameter }
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - diameter)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - diameter)
        let loupeRect = NSRect(origin: origin, size: NSSize(width: diameter, height: diameter))
        let center = NSPoint(x: loupeRect.midX, y: loupeRect.midY)

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        NSBezierPath(ovalIn: loupeRect).addClip()
        NSColor.black.setFill()
        loupeRect.fill()
        // Draw the whole capture scaled so the cursor's point lands at the loupe center;
        // crisp pixels, no smoothing.
        context.interpolationQuality = .none
        context.draw(source, in: CGRect(x: center.x - point.x * zoom,
                                        y: center.y - point.y * zoom,
                                        width: bounds.width * zoom,
                                        height: bounds.height * zoom))
        context.restoreGState()

        // Center pixel indicator.
        let pixelsPerPoint = CGFloat(source.width) / bounds.width
        let pixelSide = max(zoom / max(pixelsPerPoint, 1), 2)
        let pixelRect = NSRect(x: center.x - pixelSide / 2, y: center.y - pixelSide / 2,
                               width: pixelSide, height: pixelSide)
        NSColor.black.withAlphaComponent(0.8).setStroke()
        let inner = NSBezierPath(rect: pixelRect.insetBy(dx: -1, dy: -1))
        inner.lineWidth = 1
        inner.stroke()
        NSColor.white.setStroke()
        let marker = NSBezierPath(rect: pixelRect)
        marker.lineWidth = 1
        marker.stroke()

        // Ring.
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let ring = NSBezierPath(ovalIn: loupeRect.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 2
        ring.stroke()
    }

    private func drawSizeLabel(for rect: NSRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        var origin = NSPoint(x: rect.maxX - size.width - 6, y: rect.minY - size.height - 10)
        if origin.y < 0 { origin.y = rect.minY + 6 }
        if origin.x < 0 { origin.x = rect.minX + 6 }

        let background = NSRect(x: origin.x - 5, y: origin.y - 3, width: size.width + 10, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
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
        let background = NSRect(x: origin.x - 12, y: origin.y - 7, width: size.width + 24, height: size.height + 14)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: background, xRadius: 8, yRadius: 8).fill()
        text.draw(at: origin, withAttributes: attributes)
    }
}
