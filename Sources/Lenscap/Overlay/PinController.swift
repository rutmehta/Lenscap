import AppKit
import UniformTypeIdentifiers

/// Pins an image as a floating always-on-top panel ("screenshot sticky note").
/// Draggable by background, scroll to resize, ⌥-scroll for opacity,
/// right-click context menu, double-click to close.
@MainActor
final class PinController {
    private static var panels: [NSPanel] = []

    static func pin(image: NSImage, at rect: CGRect?) {
        var size = image.size
        if size.width <= 0 || size.height <= 0 {
            size = NSSize(width: 320, height: 200)
        }
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
        panel.fittedSize = size
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let imageView = PinImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        // Stronger border in light mode where a pale screenshot would otherwise blend in.
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        imageView.layer?.borderColor = isDark
            ? NSColor.white.withAlphaComponent(0.3).cgColor
            : NSColor.black.withAlphaComponent(0.25).cgColor
        panel.contentView = imageView

        // Gentle scale-in.
        let finalFrame = NSRect(origin: origin, size: size)
        let startFrame = finalFrame.insetBy(dx: finalFrame.width * 0.04, dy: finalFrame.height * 0.04)
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }

        panels.append(panel)
    }

    static func close(_ panel: NSPanel) {
        panel.orderOut(nil)
        panels.removeAll { $0 === panel }
    }

    static func closeAll() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

final class PinPanel: NSPanel {
    /// Size the pin was created at (already fitted to the 480pt cap); scaling is relative to this.
    var fittedSize = NSSize(width: 320, height: 200)
    private(set) var scale: CGFloat = 1

    override var canBecomeKey: Bool { false }

    /// Rescales the panel around its center, clamped to 0.2×–3× of the fitted size.
    func setScale(_ newScale: CGFloat, animated: Bool = false) {
        let clamped = min(max(newScale, 0.2), 3.0)
        scale = clamped
        let size = NSSize(width: fittedSize.width * clamped, height: fittedSize.height * clamped)
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let newFrame = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                              width: size.width, height: size.height)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(newFrame, display: true)
            }
        } else {
            setFrame(newFrame, display: true)
        }
    }
}

final class PinImageView: NSImageView {
    private var pinPanel: PinPanel? { window as? PinPanel }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let panel = window as? NSPanel {
            PinController.close(panel)
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: - Scroll: resize / opacity

    override func scrollWheel(with event: NSEvent) {
        guard let panel = pinPanel else { return }
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / 100
            : event.scrollingDeltaY / 20
        if event.modifierFlags.contains(.option) {
            panel.alphaValue = min(max(panel.alphaValue + delta, 0.25), 1.0)
        } else {
            // Line-based scroll wheels arrive in coarse steps; a short animation smooths them.
            panel.setScale(panel.scale * (1 + delta), animated: !event.hasPreciseScrollingDeltas)
        }
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(makeItem("Copy Image", action: #selector(copyImageAction)))
        menu.addItem(makeItem("Save As…", action: #selector(saveAsAction)))
        menu.addItem(makeItem("Annotate", action: #selector(annotateAction)))
        menu.addItem(.separator())
        menu.addItem(makeItem("100% Size", action: #selector(fullSizeAction)))
        menu.addItem(makeItem("50% Size", action: #selector(halfSizeAction)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Close Pin", action: #selector(closePinAction)))
        menu.addItem(makeItem("Close All Pins", action: #selector(closeAllPinsAction)))
        return menu
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func copyImageAction() {
        guard let image else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        HUD.show("Image copied", symbol: "doc.on.clipboard")
    }

    @objc private func saveAsAction() {
        guard let image, let cgImage = image.lenscapCGImage,
              let data = ImageWriter.pngData(cgImage) else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "Pinned Screenshot.png"
        savePanel.directoryURL = SettingsStore.shared.saveDirectory
        NSApp.activate(ignoringOtherApps: true)
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try data.write(to: url)
            } catch {
                HUD.show("Save failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func annotateAction() {
        guard let image else { return }
        AppCoordinator.shared.openEditor(image: image, sourceURL: nil)
    }

    @objc private func fullSizeAction() {
        pinPanel?.setScale(1, animated: true)
    }

    @objc private func halfSizeAction() {
        pinPanel?.setScale(0.5, animated: true)
    }

    @objc private func closePinAction() {
        guard let panel = window as? NSPanel else { return }
        PinController.close(panel)
    }

    @objc private func closeAllPinsAction() {
        PinController.closeAll()
    }
}
