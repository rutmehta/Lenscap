import AppKit

/// Thin border drawn around the recorded region for the duration of a recording.
/// Excluded from the capture itself via the stream's content filter, so it is
/// visible to the user but never appears in the video.
@MainActor
final class RecordingOutlineController {
    private var window: NSWindow?

    /// `rect` is the recorded region in global AppKit coordinates.
    func show(around rect: CGRect, on screen: NSScreen) {
        let padding: CGFloat = 3
        let frame = rect.insetBy(dx: -padding, dy: -padding).intersection(screen.frame)
        guard !frame.isEmpty else { return }

        let outlineWindow = NSWindow(contentRect: frame, styleMask: .borderless,
                                     backing: .buffered, defer: false)
        outlineWindow.isOpaque = false
        outlineWindow.backgroundColor = .clear
        outlineWindow.hasShadow = false
        outlineWindow.ignoresMouseEvents = true
        outlineWindow.isReleasedWhenClosed = false
        outlineWindow.level = .statusBar
        outlineWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = RecordingOutlineView(frame: NSRect(origin: .zero, size: frame.size))
        view.recordedRect = NSRect(x: rect.minX - frame.minX, y: rect.minY - frame.minY,
                                   width: rect.width, height: rect.height)
        outlineWindow.contentView = view
        outlineWindow.orderFrontRegardless()
        window = outlineWindow
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

private final class RecordingOutlineView: NSView {
    var recordedRect: NSRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 5

        // Contrast hairline just outside the red stroke so the border reads on any background.
        let outerRect = recordedRect.insetBy(dx: -1.25, dy: -1.25)
        let outer = NSBezierPath(roundedRect: outerRect, xRadius: radius + 1.25, yRadius: radius + 1.25)
        outer.lineWidth = 3.5
        NSColor.black.withAlphaComponent(0.25).setStroke()
        outer.stroke()

        let inner = NSBezierPath(roundedRect: recordedRect, xRadius: radius, yRadius: radius)
        inner.lineWidth = 1.5
        NSColor.systemRed.withAlphaComponent(0.9).setStroke()
        inner.stroke()

        // Four short L-shaped corner ticks so the border reads as an intentional frame.
        let tickLength: CGFloat = 14
        let ticks = NSBezierPath()
        ticks.lineWidth = 3
        ticks.lineCapStyle = .round
        ticks.lineJoinStyle = .round

        let r = recordedRect
        // Bottom-left
        ticks.move(to: NSPoint(x: r.minX, y: r.minY + tickLength))
        ticks.line(to: NSPoint(x: r.minX, y: r.minY + radius))
        ticks.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.minY + radius),
                        radius: radius, startAngle: 180, endAngle: 270, clockwise: false)
        ticks.line(to: NSPoint(x: r.minX + tickLength, y: r.minY))
        // Bottom-right
        ticks.move(to: NSPoint(x: r.maxX - tickLength, y: r.minY))
        ticks.line(to: NSPoint(x: r.maxX - radius, y: r.minY))
        ticks.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.minY + radius),
                        radius: radius, startAngle: 270, endAngle: 360, clockwise: false)
        ticks.line(to: NSPoint(x: r.maxX, y: r.minY + tickLength))
        // Top-right
        ticks.move(to: NSPoint(x: r.maxX, y: r.maxY - tickLength))
        ticks.line(to: NSPoint(x: r.maxX, y: r.maxY - radius))
        ticks.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.maxY - radius),
                        radius: radius, startAngle: 0, endAngle: 90, clockwise: false)
        ticks.line(to: NSPoint(x: r.maxX - tickLength, y: r.maxY))
        // Top-left
        ticks.move(to: NSPoint(x: r.minX + tickLength, y: r.maxY))
        ticks.line(to: NSPoint(x: r.minX + radius, y: r.maxY))
        ticks.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.maxY - radius),
                        radius: radius, startAngle: 90, endAngle: 180, clockwise: false)
        ticks.line(to: NSPoint(x: r.minX, y: r.maxY - tickLength))

        NSColor.systemRed.setStroke()
        ticks.stroke()
    }
}
