import AppKit

/// Pins an image as a floating always-on-top panel ("screenshot sticky note").
/// Basic version: draggable, double-click to close. Polish (zoom, opacity,
/// context menu) lives in a follow-up pass.
@MainActor
final class PinController {
    private static var panels: [NSPanel] = []

    static func pin(image: NSImage, at rect: CGRect?) {
        var size = image.size
        let maxDimension: CGFloat = 480
        if size.width > maxDimension || size.height > maxDimension {
            let scale = min(maxDimension / size.width, maxDimension / size.height)
            size = NSSize(width: size.width * scale, height: size.height * scale)
        }

        let origin: NSPoint
        if let rect {
            origin = NSPoint(x: rect.minX, y: rect.minY)
        } else if let screen = NSScreen.main {
            origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                             y: screen.visibleFrame.midY - size.height / 2)
        } else {
            origin = .zero
        }

        let panel = PinPanel(contentRect: NSRect(origin: origin, size: size),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let imageView = PinImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        panel.contentView = imageView

        panel.orderFrontRegardless()
        panels.append(panel)
    }

    static func close(_ panel: NSPanel) {
        panel.orderOut(nil)
        panels.removeAll { $0 === panel }
    }
}

final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

final class PinImageView: NSImageView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let panel = window as? NSPanel {
            PinController.close(panel)
            return
        }
        super.mouseDown(with: event)
    }
}
