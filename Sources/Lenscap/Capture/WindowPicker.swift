import AppKit
import ScreenCaptureKit

/// Interactive window picker: dims every screen, highlights the window under the
/// cursor with its app name + title, and returns the chosen `SCWindow` on click.
@MainActor
final class WindowPickerController {
    private static var current: WindowPickerController?

    private var windows: [WindowPickerWindow] = []
    private var candidates: [SCWindow] = []
    private let completion: @MainActor (SCWindow?) -> Void
    private var finished = false
    private var keyMonitor: Any?
    private var hovered: SCWindow?

    static func pickWindow(completion: @escaping @MainActor (SCWindow?) -> Void) {
        // Only one picking session at a time.
        current?.finish(with: nil)
        let controller = WindowPickerController(completion: completion)
        current = controller
        controller.begin()
    }

    private init(completion: @escaping @MainActor (SCWindow?) -> Void) {
        self.completion = completion
    }

    // MARK: - Lifecycle

    private func begin() {
        Task { @MainActor in
            do {
                let content = try await CaptureEngine.shareableContent()
                guard !finished else { return }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                // `content.windows` is ordered front-to-back, so the first hit wins.
                candidates = content.windows.filter { window in
                    window.isOnScreen &&
                    window.windowLayer == 0 &&
                    window.frame.width > 40 && window.frame.height > 40 &&
                    window.owningApplication?.processID != ownPID
                }
                present()
            } catch {
                HUD.show("Could not list windows: \(error.localizedDescription)")
                finish(with: nil)
            }
        }
    }

    private func present() {
        for screen in NSScreen.screens {
            let window = WindowPickerWindow(screen: screen, controller: self)
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
        updateHover(at: NSEvent.mouseLocation)
    }

    func finish(with result: SCWindow?) {
        guard !finished else { return }
        finished = true
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        WindowPickerController.current = nil
        completion(result)
    }

    /// Backup monitor so ⎋ cancels no matter which overlay window is key.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return event }
                if event.keyCode == 53 { // Escape
                    self.finish(with: nil)
                    return nil
                }
                return event
            }
        }
    }

    // MARK: - Hit testing

    /// Recomputes the window under `mouse` (global AppKit coordinates) and redraws on change.
    /// Our own overlay windows are never candidates (filtered by pid up front).
    func updateHover(at mouse: NSPoint) {
        guard let primary = NSScreen.screens.first else { return }
        // Global AppKit (bottom-left) → CG global (top-left, anchored at the primary display).
        let cgPoint = CGPoint(x: mouse.x, y: primary.frame.maxY - mouse.y)
        let hit = candidates.first { $0.frame.contains(cgPoint) }
        guard hit?.windowID != hovered?.windowID else { return }
        hovered = hit
        windows.forEach { $0.contentView?.needsDisplay = true }
    }

    func commitHover() {
        finish(with: hovered)
    }

    /// Hovered window's frame converted from CG global (top-left) to AppKit global (bottom-left).
    var hoveredFrame: NSRect? {
        guard let hovered, let primary = NSScreen.screens.first else { return nil }
        let frame = hovered.frame
        return NSRect(x: frame.origin.x,
                      y: primary.frame.maxY - (frame.origin.y + frame.height),
                      width: frame.width,
                      height: frame.height)
    }

    var hoveredLabel: String? {
        guard let hovered else { return nil }
        let app = hovered.owningApplication?.applicationName ?? "Unknown"
        if let title = hovered.title, !title.isEmpty, title != app {
            return "\(app) — \(title)"
        }
        return app
    }
}

final class WindowPickerWindow: NSWindow {
    let assignedScreen: NSScreen

    init(screen: NSScreen, controller: WindowPickerController) {
        assignedScreen = screen
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = WindowPickerView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                    controller: controller)
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

final class WindowPickerView: NSView {
    private weak var controller: WindowPickerController?
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, controller: WindowPickerController) {
        self.controller = controller
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
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - Events

    override func mouseMoved(with event: NSEvent) {
        controller?.updateHover(at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.updateHover(at: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        controller?.updateHover(at: NSEvent.mouseLocation)
        controller?.commitHover()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            controller?.finish(with: nil)
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.25)

        guard let controller,
              let globalFrame = controller.hoveredFrame,
              let windowOrigin = window?.frame.origin else {
            dim.setFill()
            bounds.fill()
            drawPrompt()
            return
        }

        let local = globalFrame.offsetBy(dx: -windowOrigin.x, dy: -windowOrigin.y)
        guard local.intersects(bounds) else {
            dim.setFill()
            bounds.fill()
            drawPrompt()
            return
        }

        // Dim everything except the hovered window.
        let highlight = NSBezierPath(roundedRect: local, xRadius: 8, yRadius: 8)
        let path = NSBezierPath(rect: bounds)
        path.append(highlight)
        path.windingRule = .evenOdd
        dim.setFill()
        path.fill()

        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        highlight.fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(roundedRect: local.insetBy(dx: -1.5, dy: -1.5), xRadius: 9, yRadius: 9)
        border.lineWidth = 3
        border.stroke()

        if let label = controller.hoveredLabel {
            drawLabel(label, in: local)
        }
    }

    private func drawLabel(_ text: String, in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        var size = text.size(withAttributes: attributes)
        size.width = min(size.width, rect.width - 32, bounds.width - 32)
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.maxY - size.height - 20)
        origin.x = min(max(origin.x, bounds.minX + 16), bounds.maxX - size.width - 16)
        origin.y = min(max(origin.y, bounds.minY + 16), bounds.maxY - size.height - 16)

        let background = NSRect(x: origin.x - 10, y: origin.y - 6, width: size.width + 20, height: size.height + 12)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: background, xRadius: 6, yRadius: 6).fill()
        text.draw(in: NSRect(origin: origin, size: size), withAttributes: attributes)
    }

    private func drawPrompt() {
        let text = "Click a window to capture — ⎋ to cancel"
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
