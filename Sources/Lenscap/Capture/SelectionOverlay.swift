import AppKit

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
    }

    func finish(with result: SelectionResult?) {
        guard !finished else { return }
        finished = true
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        SelectionOverlayController.current = nil
        completion(result)
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
    private var trackingArea: NSTrackingArea?

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

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        currentPoint = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = selectionRect, rect.width >= 4, rect.height >= 4 else {
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

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            controller?.finish(with: nil)
        case 36, 76: // Return / keypad Enter → full screen
            controller?.finish(with: SelectionResult(rect: screen.frame, screen: screen, wantsFullScreen: true))
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.25)

        if let rect = selectionRect, dragStart != nil {
            // Dim everything except the selection.
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
        } else {
            dim.setFill()
            bounds.fill()
            if let currentPoint {
                drawCrosshair(at: currentPoint)
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

    private func drawSizeLabel(for rect: NSRect) {
        let scale = screen.backingScaleFactor
        let text = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
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
