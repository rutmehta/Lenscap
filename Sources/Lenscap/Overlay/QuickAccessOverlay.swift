import AppKit
import LenscapUXCore
import UniformTypeIdentifiers

/// Floating post-capture thumbnail in the bottom-left corner of the main screen
/// with quick actions (annotate, copy, save/reveal, pin, trash), drag-out support,
/// and a hover-aware auto-dismiss timer.
@MainActor
final class QuickAccessOverlayController: NSObject {
    static let shared = QuickAccessOverlayController()

    private var panel: NSPanel?
    private var item: CaptureItem?
    private var tempDragURL: URL?
    private weak var saveRevealButton: NSButton?

    private var dismissTask: Task<Void, Never>?
    private let lifecycle = QuickAccessLifecycle(now: { Date.timeIntervalSinceReferenceDate })
    private var generation = 0

    private override init() { super.init() }

    // MARK: - Presentation

    func show(_ item: CaptureItem) {
        teardown()
        generation &+= 1
        let captureGeneration = generation
        self.item = item

        lifecycle.show(id: captureGeneration, duration: max(2, SettingsStore.shared.quickAccessDuration))
        let content = buildContent(for: item, generation: captureGeneration)
        let size = content.frame.size
        let newPanel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.level = .statusBar
        newPanel.hasShadow = true
        newPanel.hidesOnDeactivate = false
        newPanel.becomesKeyOnlyIfNeeded = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.contentView = content

        let margin: CGFloat = 16
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let finalOrigin = NSPoint(x: visible.minX + margin, y: visible.minY + margin)
        let startOrigin = NSPoint(x: finalOrigin.x - size.width * 0.4, y: finalOrigin.y)

        newPanel.setFrameOrigin(startOrigin)
        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            // Quick ease-out with a hint of overshoot for a springy slide-in.
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 1.08, 0.25, 1)
            newPanel.animator().alphaValue = 1
            newPanel.animator().setFrame(NSRect(origin: finalOrigin, size: size), display: true)
        }

        panel = newPanel
        startDismissTimer(after: max(2, SettingsStore.shared.quickAccessDuration), generation: captureGeneration)
    }

    func contentViewForSnapshot() -> NSView? {
        panel?.contentView
    }

    func dismissForSnapshot() {
        guard let current = lifecycle.currentCaptureID else { return }
        dismissCurrent(generation: current)
    }

    // MARK: - Content

    private func buildContent(for item: CaptureItem, generation: Int) -> NSView {
        let padding: CGFloat = 8
        let barAreaHeight: CGFloat = 32

        let thumbSize = Self.fittedThumbnailSize(for: item.image)
        let width = max(thumbSize.width, 176) + padding * 2
        let height = thumbSize.height + padding * 2 + 1 + barAreaHeight

        let container = QuickAccessHoverView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.onHoverChange = { [weak self] inside in
            self?.handleHover(inside, generation: generation)
        }

        let effect = NSVisualEffectView(frame: container.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        effect.autoresizingMask = [.width, .height]
        container.addSubview(effect)

        // Thumbnail (drag source, double-click to open/annotate).
        let thumb = QuickAccessThumbnailView(frame: NSRect(x: (width - thumbSize.width) / 2,
                                                           y: barAreaHeight + 1 + padding,
                                                           width: thumbSize.width,
                                                           height: thumbSize.height))
        if item.image.size.width > 1, item.image.size.height > 1 {
            thumb.image = item.image
            thumb.imageScaling = .scaleProportionallyUpOrDown
        } else {
            thumb.image = NSImage(systemSymbolName: "film", accessibilityDescription: "Recording")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 32, weight: .regular))
            thumb.imageScaling = .scaleNone
            thumb.contentTintColor = .secondaryLabelColor
        }
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.masksToBounds = true
        thumb.layer?.borderWidth = 1
        thumb.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        thumb.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        thumb.toolTip = "Drag to another app — double-click to open"
        thumb.fileURLProvider = { [weak self] in self?.dragFileURL(for: generation) }
        thumb.onDragBegan = { [weak self] in self?.handleDragBegan(generation: generation) }
        thumb.onDragEnded = { [weak self] succeeded in
            self?.handleDragEnded(succeeded: succeeded, generation: generation)
        }
        thumb.onDoubleClick = { [weak self] in self?.handleDoubleClick(generation: generation) }
        effect.addSubview(thumb)

        // Hairline separator between thumbnail and action bar.
        let separator = NSView(frame: NSRect(x: 0, y: barAreaHeight, width: width, height: 1))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        separator.autoresizingMask = [.width]
        effect.addSubview(separator)

        // Action bar.
        let bar = NSStackView(frame: NSRect(x: 6, y: (barAreaHeight - 26) / 2, width: width - 12, height: 26))
        bar.orientation = .horizontal
        bar.spacing = 2
        bar.autoresizingMask = [.width]

        if item.kind == .screenshot {
            bar.addView(makeButton(symbol: "pencil.tip.crop.circle", tooltip: "Annotate",
                                   action: #selector(annotateAction(_:)), generation: generation), in: .leading)
        }
        bar.addView(makeButton(symbol: "doc.on.doc", tooltip: "Copy",
                               action: #selector(copyAction(_:)), generation: generation), in: .leading)
        let saveReveal = makeButton(symbol: item.fileURL != nil ? "folder" : "square.and.arrow.down",
                                    tooltip: item.fileURL != nil ? "Reveal in Finder" : "Save",
                                    action: #selector(saveRevealAction(_:)), generation: generation)
        saveRevealButton = saveReveal
        bar.addView(saveReveal, in: .leading)
        if item.kind == .screenshot {
            bar.addView(makeButton(symbol: "pin", tooltip: "Pin to screen",
                                   action: #selector(pinAction(_:)), generation: generation), in: .leading)
        }
        bar.addView(makeButton(symbol: "trash", tooltip: "Move to Trash",
                               action: #selector(trashAction(_:)), generation: generation), in: .leading)
        bar.addView(makeButton(symbol: "xmark", tooltip: "Close",
                               action: #selector(closeAction(_:)), generation: generation, quiet: true), in: .trailing)
        effect.addSubview(bar)

        return container
    }

    private func makeButton(symbol: String, tooltip: String, action: Selector,
                            generation: Int, quiet: Bool = false) -> NSButton {
        let pointSize: CGFloat = quiet ? 11 : 13
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)) ?? NSImage()
        let button = QuickAccessBarButton(image: image, target: self, action: action)
        button.tag = generation
        button.isBordered = false
        button.toolTip = tooltip
        button.contentTintColor = quiet ? .tertiaryLabelColor : .labelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 26),
        ])
        return button
    }

    private static func fittedThumbnailSize(for image: NSImage) -> NSSize {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return NSSize(width: 240, height: 135) }
        let scale = min(280 / size.width, 180 / size.height, 1)
        return NSSize(width: max(size.width * scale, 60), height: max(size.height * scale, 40))
    }

    // MARK: - Actions

    @objc private func annotateAction(_ sender: NSButton) {
        guard isCurrent(sender) else { return }
        guard let item, item.kind == .screenshot else { return }
        AppCoordinator.shared.openEditor(image: item.image, sourceURL: item.fileURL)
        dismissCurrent(generation: sender.tag)
    }

    @objc private func copyAction(_ sender: NSButton) {
        guard isCurrent(sender), let item else { return }
        var succeeded = false
        switch item.kind {
        case .screenshot:
            guard let cgImage = item.image.lenscapCGImage else { return }
            succeeded = ImageWriter.copyToClipboard(cgImage: cgImage, fileURL: item.fileURL)
            if succeeded { HUD.show("Copied to clipboard", symbol: "doc.on.clipboard") }
        case .video, .gif:
            guard let url = item.fileURL else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            succeeded = pasteboard.writeObjects([url as NSURL])
            if succeeded { HUD.show("File copied to clipboard", symbol: "doc.on.clipboard") }
        }
        if succeeded { dismissCurrent(generation: sender.tag) }
    }

    @objc private func saveRevealAction(_ sender: NSButton) {
        guard isCurrent(sender) else { return }
        guard var item else { return }
        if let url = item.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let cgImage = item.image.lenscapCGImage,
                  let url = ImageWriter.save(cgImage: cgImage,
                                             scale: CGFloat(cgImage.width) / max(1, item.image.size.width)) {
            item.fileURL = url
            self.item = item
            HistoryStore.shared.add(url: url, kind: item.kind)
            HUD.show("Saved", symbol: "checkmark.circle")
            updateSaveRevealButton()
        } else {
            HUD.show("Save failed")
        }
    }

    @objc private func pinAction(_ sender: NSButton) {
        guard isCurrent(sender) else { return }
        guard let item, item.kind == .screenshot else { return }
        PinController.pin(image: item.image, at: nil)
        dismissCurrent(generation: sender.tag)
    }

    @objc private func trashAction(_ sender: NSButton) {
        guard isCurrent(sender) else { return }
        if let url = item?.fileURL {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if let entry = HistoryStore.shared.entries.first(where: { $0.path == url.path }) {
                HistoryStore.shared.remove(entry, deleteFile: false)
            }
            HUD.show("Moved to Trash", symbol: "trash")
        }
        dismissCurrent(generation: sender.tag)
    }

    @objc private func closeAction(_ sender: NSButton) {
        guard isCurrent(sender) else { return }
        dismissCurrent(generation: sender.tag)
    }

    private func handleDoubleClick(generation: Int) {
        guard generation == self.generation else { return }
        guard let item else { return }
        switch item.kind {
        case .screenshot:
            AppCoordinator.shared.openEditor(image: item.image, sourceURL: item.fileURL)
            dismissCurrent(generation: generation)
        case .video, .gif:
            if let url = item.fileURL {
                NSWorkspace.shared.open(url)
            }
            dismissCurrent(generation: generation)
        }
    }

    private func updateSaveRevealButton() {
        saveRevealButton?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Reveal in Finder")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        saveRevealButton?.toolTip = "Reveal in Finder"
    }

    // MARK: - Drag support

    /// URL handed to the drag session; writes a temporary PNG when the capture is unsaved.
    private func dragFileURL(for generation: Int) -> URL? {
        guard generation == self.generation else { return nil }
        guard let item else { return nil }
        if let url = item.fileURL { return url }
        if let cached = tempDragURL { return cached }
        guard let cgImage = item.image.lenscapCGImage, let data = ImageWriter.pngData(cgImage) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lenscap \(UUID().uuidString.prefix(8)).png")
        do {
            try data.write(to: url)
        } catch {
            return nil
        }
        tempDragURL = url
        return url
    }

    /// Deletes the drag temp PNG after a grace period so an in-flight drop
    /// target still has time to copy from it.
    private func removeTempDragFile() {
        guard let url = tempDragURL else { return }
        tempDragURL = nil
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Dismiss timer and lifecycle transitions

    private func isCurrent(_ sender: NSButton) -> Bool {
        sender.tag == generation && panel != nil
    }

    private func startDismissTimer(after interval: TimeInterval, generation: Int) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            guard interval > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.lifecycle.timerFired(for: generation) else { return }
            self.dismissPanel(generation: generation)
        }
    }

    private func handleHover(_ inside: Bool, generation: Int) {
        guard generation == self.generation, panel != nil else { return }
        if inside {
            dismissTask?.cancel()
            dismissTask = nil
        }
        guard let remaining = lifecycle.hoverChanged(for: generation, inside: inside) else { return }
        if !inside {
            startDismissTimer(after: remaining, generation: generation)
        }
    }

    private func handleDragBegan(generation: Int) {
        guard generation == self.generation, panel != nil else { return }
        dismissTask?.cancel()
        dismissTask = nil
        _ = lifecycle.beginDrag(for: generation)
    }

    private func handleDragEnded(succeeded: Bool, generation: Int) {
        guard generation == self.generation, panel != nil else { return }
        let outcome: QuickAccessLifecycle.DragOutcome = succeeded ? .succeeded : .cancelled
        if lifecycle.finishDrag(for: generation, outcome: outcome) {
            dismissPanel(generation: generation)
        } else if let remaining = lifecycle.remainingTime(for: generation) {
            startDismissTimer(after: remaining, generation: generation)
        }
    }

    private func dismissCurrent(generation: Int) {
        guard generation == self.generation, panel != nil else { return }
        guard lifecycle.dismiss(for: generation) else { return }
        dismissPanel(generation: generation)
    }

    private func dismissPanel(generation: Int) {
        guard generation == self.generation, let dismissing = panel else { return }
        dismissTask?.cancel()
        dismissTask = nil
        panel = nil
        item = nil
        removeTempDragFile()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            dismissing.animator().alphaValue = 0
        }, completionHandler: {
            dismissing.orderOut(nil)
        })
    }

    /// Removes the current panel immediately (used when a new capture replaces it).
    private func teardown() {
        dismissTask?.cancel()
        dismissTask = nil
        if lifecycle.currentCaptureID == generation {
            _ = lifecycle.dismiss(for: generation)
        }
        panel?.orderOut(nil)
        panel = nil
        item = nil
        removeTempDragFile()
        saveRevealButton = nil
    }
}

// MARK: - Supporting views

/// Thumbnail that acts as a file drag source and reports double-clicks.
final class QuickAccessThumbnailView: NSImageView, NSDraggingSource {
    var fileURLProvider: (() -> URL?)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: ((Bool) -> Void)?
    var onDoubleClick: (() -> Void)?
    private var mouseDownEvent: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            mouseDownEvent = nil
            onDoubleClick?()
            return
        }
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downEvent = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - downEvent.locationInWindow.x
        let dy = event.locationInWindow.y - downEvent.locationInWindow.y
        guard hypot(dx, dy) > 4 else { return }
        mouseDownEvent = nil
        guard let url = fileURLProvider?() else { return }
        onDragBegan?()
        let draggingItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        draggingItem.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [draggingItem], event: downEvent, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        onDragEnded?(operation != [])
    }
}

/// Container that reports mouse enter/exit so the dismiss timer can pause on hover.
final class QuickAccessHoverView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }
}

/// Button that responds to the first click even when the app is inactive,
/// with a subtle rounded highlight on hover.
final class QuickAccessBarButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHoverHighlight(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHoverHighlight(false)
    }

    private func setHoverHighlight(_ inside: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            layer?.backgroundColor = inside
                ? NSColor.white.withAlphaComponent(0.16).cgColor
                : NSColor.clear.cgColor
        }
    }
}

extension NSImage {
    /// Best-effort CGImage conversion at the image's nominal size.
    var lenscapCGImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
