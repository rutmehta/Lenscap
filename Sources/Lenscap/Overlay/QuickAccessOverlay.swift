import AppKit
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
    private var remaining: TimeInterval = 0
    private var timerStartedAt: Date?

    private override init() { super.init() }

    // MARK: - Presentation

    func show(_ item: CaptureItem) {
        teardown()
        self.item = item

        let content = buildContent(for: item)
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
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            newPanel.animator().alphaValue = 1
            newPanel.animator().setFrame(NSRect(origin: finalOrigin, size: size), display: true)
        }

        panel = newPanel
        startDismissTimer(after: max(2, SettingsStore.shared.quickAccessDuration))
    }

    // MARK: - Content

    private func buildContent(for item: CaptureItem) -> NSView {
        let padding: CGFloat = 8
        let barHeight: CGFloat = 24
        let spacing: CGFloat = 6

        let thumbSize = Self.fittedThumbnailSize(for: item.image)
        let width = max(thumbSize.width, 176) + padding * 2
        let height = thumbSize.height + spacing + barHeight + padding * 2

        let container = QuickAccessHoverView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.onHoverChange = { [weak self] inside in
            if inside { self?.pauseDismissTimer() } else { self?.resumeDismissTimer() }
        }

        let effect = NSVisualEffectView(frame: container.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        effect.autoresizingMask = [.width, .height]
        container.addSubview(effect)

        // Thumbnail (drag source, double-click to open/annotate).
        let thumb = QuickAccessThumbnailView(frame: NSRect(x: (width - thumbSize.width) / 2,
                                                           y: padding + barHeight + spacing,
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
        thumb.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        thumb.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        thumb.toolTip = "Drag to another app — double-click to open"
        thumb.fileURLProvider = { [weak self] in self?.dragFileURL() }
        thumb.onDoubleClick = { [weak self] in self?.handleDoubleClick() }
        effect.addSubview(thumb)

        // Action bar.
        let bar = NSStackView(frame: NSRect(x: padding, y: padding, width: width - padding * 2, height: barHeight))
        bar.orientation = .horizontal
        bar.spacing = 4
        bar.autoresizingMask = [.width]

        if item.kind == .screenshot {
            bar.addView(makeButton(symbol: "pencil.tip.crop.circle", tooltip: "Annotate",
                                   action: #selector(annotateAction)), in: .leading)
        }
        bar.addView(makeButton(symbol: "doc.on.doc", tooltip: "Copy",
                               action: #selector(copyAction)), in: .leading)
        let saveReveal = makeButton(symbol: item.fileURL != nil ? "folder" : "square.and.arrow.down",
                                    tooltip: item.fileURL != nil ? "Reveal in Finder" : "Save",
                                    action: #selector(saveRevealAction))
        saveRevealButton = saveReveal
        bar.addView(saveReveal, in: .leading)
        if item.kind == .screenshot {
            bar.addView(makeButton(symbol: "pin", tooltip: "Pin to screen",
                                   action: #selector(pinAction)), in: .leading)
        }
        bar.addView(makeButton(symbol: "trash", tooltip: "Move to Trash",
                               action: #selector(trashAction)), in: .leading)
        bar.addView(makeButton(symbol: "xmark", tooltip: "Close",
                               action: #selector(closeAction)), in: .trailing)
        effect.addSubview(bar)

        return container
    }

    private func makeButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)) ?? NSImage()
        let button = QuickAccessBarButton(image: image, target: self, action: action)
        button.isBordered = false
        button.toolTip = tooltip
        button.contentTintColor = .white
        return button
    }

    private static func fittedThumbnailSize(for image: NSImage) -> NSSize {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return NSSize(width: 240, height: 135) }
        let scale = min(280 / size.width, 180 / size.height, 1)
        return NSSize(width: max(size.width * scale, 60), height: max(size.height * scale, 40))
    }

    // MARK: - Actions

    @objc private func annotateAction() {
        guard let item, item.kind == .screenshot else { return }
        AppCoordinator.shared.openEditor(image: item.image, sourceURL: item.fileURL)
        dismiss()
    }

    @objc private func copyAction() {
        guard let item else { return }
        switch item.kind {
        case .screenshot:
            guard let cgImage = item.image.lenscapCGImage else { return }
            ImageWriter.copyToClipboard(cgImage: cgImage, fileURL: item.fileURL)
            HUD.show("Copied to clipboard", symbol: "doc.on.clipboard")
        case .video, .gif:
            guard let url = item.fileURL else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            (url as NSURL).write(to: pasteboard)
            HUD.show("File copied to clipboard", symbol: "doc.on.clipboard")
        }
    }

    @objc private func saveRevealAction() {
        guard var item else { return }
        if let url = item.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let cgImage = item.image.lenscapCGImage, let url = ImageWriter.save(cgImage: cgImage) {
            item.fileURL = url
            self.item = item
            HistoryStore.shared.add(url: url, kind: item.kind)
            HUD.show("Saved", symbol: "checkmark.circle")
            updateSaveRevealButton()
        } else {
            HUD.show("Save failed")
        }
    }

    @objc private func pinAction() {
        guard let item, item.kind == .screenshot else { return }
        PinController.pin(image: item.image, at: nil)
        dismiss()
    }

    @objc private func trashAction() {
        if let url = item?.fileURL {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            HUD.show("Moved to Trash", symbol: "trash")
        }
        dismiss()
    }

    @objc private func closeAction() {
        dismiss()
    }

    private func handleDoubleClick() {
        guard let item else { return }
        switch item.kind {
        case .screenshot:
            annotateAction()
        case .video, .gif:
            if let url = item.fileURL {
                NSWorkspace.shared.open(url)
            }
            dismiss()
        }
    }

    private func updateSaveRevealButton() {
        saveRevealButton?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Reveal in Finder")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        saveRevealButton?.toolTip = "Reveal in Finder"
    }

    // MARK: - Drag support

    /// URL handed to the drag session; writes a temporary PNG when the capture is unsaved.
    private func dragFileURL() -> URL? {
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

    // MARK: - Dismiss timer

    private func startDismissTimer(after interval: TimeInterval) {
        dismissTask?.cancel()
        remaining = interval
        timerStartedAt = Date()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func pauseDismissTimer() {
        guard let startedAt = timerStartedAt else { return }
        dismissTask?.cancel()
        dismissTask = nil
        remaining = max(1, remaining - Date().timeIntervalSince(startedAt))
        timerStartedAt = nil
    }

    private func resumeDismissTimer() {
        guard panel != nil, dismissTask == nil else { return }
        startDismissTimer(after: remaining)
    }

    private func dismiss() {
        guard let dismissing = panel else { return }
        dismissTask?.cancel()
        dismissTask = nil
        timerStartedAt = nil
        panel = nil
        item = nil
        tempDragURL = nil
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
        timerStartedAt = nil
        panel?.orderOut(nil)
        panel = nil
        item = nil
        tempDragURL = nil
        saveRevealButton = nil
    }
}

// MARK: - Supporting views

/// Thumbnail that acts as a file drag source and reports double-clicks.
final class QuickAccessThumbnailView: NSImageView, NSDraggingSource {
    var fileURLProvider: (() -> URL?)?
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

/// Button that responds to the first click even when the app is inactive.
final class QuickAccessBarButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSImage {
    /// Best-effort CGImage conversion at the image's nominal size.
    var lenscapCGImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
