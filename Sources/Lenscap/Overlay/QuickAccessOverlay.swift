import AppKit
import LenscapUXCore
import UniformTypeIdentifiers

/// Floating post-capture thumbnail in the bottom-left corner of the main screen
/// with quick actions (annotate, copy, save/reveal, pin, trash), drag-out support,
/// and a hover-aware auto-dismiss timer.
///
/// Visual design: the screenshot itself is the card — a continuously-rounded
/// thumbnail with a real drop shadow and a hairline edge. Actions live in a
/// compact HUD pill overlaid on the card's bottom edge; a small circular close
/// button appears at the top-left on hover.
@MainActor
final class QuickAccessOverlayController: NSObject {
    static let shared = QuickAccessOverlayController()

    private var panel: NSPanel?
    private var item: CaptureItem?
    private var tempDragURL: URL?
    private weak var saveRevealButton: NSButton?
    private weak var actionPill: NSView?
    private weak var closeControl: NSView?

    private var dismissTask: Task<Void, Never>?
    private let lifecycle = QuickAccessLifecycle(now: { Date.timeIntervalSinceReferenceDate })
    private var generation = 0

    // Layout constants.
    private static let cornerRadius: CGFloat = 10
    /// Transparent margin around the card so the drop shadow is not clipped.
    private static let shadowInset: CGFloat = 32
    private static let pillRestingAlpha: CGFloat = 0.8

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
        newPanel.hasShadow = false // The card draws its own shadow.
        newPanel.hidesOnDeactivate = false
        newPanel.becomesKeyOnlyIfNeeded = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.contentView = content

        let margin: CGFloat = 16
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Offset by the shadow inset so the visible card edge sits `margin` from the corner.
        let finalOrigin = NSPoint(x: visible.minX + margin - Self.shadowInset,
                                  y: visible.minY + margin - Self.shadowInset)
        let startOrigin = NSPoint(x: finalOrigin.x, y: finalOrigin.y - 12)

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
        let inset = Self.shadowInset
        let pillHeight: CGFloat = 28
        let pillMargin: CGFloat = 6
        let buttonSize: CGFloat = 24
        let buttonSpacing: CGFloat = 2

        let isPlaceholder = !(item.image.size.width > 1 && item.image.size.height > 1)
        let thumbSize = Self.fittedThumbnailSize(for: item.image)

        // Pill actions (Close lives separately at the card's top-left).
        var actions: [(symbol: String, tooltip: String, action: Selector)] = []
        if item.kind == .screenshot {
            actions.append(("pencil.tip.crop.circle", "Annotate", #selector(annotateAction(_:))))
        }
        actions.append(("doc.on.doc", "Copy", #selector(copyAction(_:))))
        actions.append((item.fileURL != nil ? "folder" : "square.and.arrow.down",
                        item.fileURL != nil ? "Reveal in Finder" : "Save",
                        #selector(saveRevealAction(_:))))
        if item.kind == .screenshot {
            actions.append(("pin", "Pin to screen", #selector(pinAction(_:))))
        }
        actions.append(("trash", "Move to Trash", #selector(trashAction(_:))))

        let pillWidth = CGFloat(actions.count) * buttonSize
            + CGFloat(actions.count - 1) * buttonSpacing + 12

        let cardWidth = max(thumbSize.width, pillWidth + pillMargin * 2)
        let cardHeight = max(thumbSize.height, pillHeight + pillMargin * 2 + 24)
        let cardRect = NSRect(x: inset, y: inset, width: cardWidth, height: cardHeight)

        let container = QuickAccessPassThroughView(
            frame: NSRect(x: 0, y: 0, width: cardWidth + inset * 2, height: cardHeight + inset * 2))
        container.interactiveRect = cardRect

        // Card: hover tracking + drop shadow. Content is clipped by the surface below.
        let card = QuickAccessHoverView(frame: cardRect)
        card.onHoverChange = { [weak self] inside in
            self?.handleHover(inside, generation: generation)
        }
        card.wantsLayer = true
        card.layer?.masksToBounds = false
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.35
        card.layer?.shadowRadius = 18
        card.layer?.shadowOffset = CGSize(width: 0, height: -4)
        card.layer?.shadowPath = CGPath(roundedRect: card.bounds,
                                        cornerWidth: Self.cornerRadius,
                                        cornerHeight: Self.cornerRadius,
                                        transform: nil)
        container.addSubview(card)

        // Surface: rounded clipping bounds, semantic background, hairline edge.
        let surface = QuickAccessCardSurface(frame: card.bounds)
        surface.wantsLayer = true
        surface.layer?.cornerRadius = Self.cornerRadius
        surface.layer?.cornerCurve = .continuous
        surface.layer?.masksToBounds = true
        surface.layer?.borderWidth = 0.5
        card.addSubview(surface)

        // Thumbnail (drag source, double-click to open/annotate) fills the surface.
        let thumb = QuickAccessThumbnailView(frame: surface.bounds)
        thumb.autoresizingMask = [.width, .height]
        if isPlaceholder {
            thumb.image = NSImage(systemSymbolName: "film", accessibilityDescription: "Recording")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 32, weight: .regular))
            thumb.imageScaling = .scaleNone
            thumb.contentTintColor = .secondaryLabelColor
        } else {
            thumb.image = item.image
            thumb.imageScaling = .scaleProportionallyUpOrDown
        }
        thumb.toolTip = "Drag to another app — double-click to open"
        thumb.fileURLProvider = { [weak self] in self?.dragFileURL(for: generation) }
        thumb.onDragBegan = { [weak self] in self?.handleDragBegan(generation: generation) }
        thumb.onDragEnded = { [weak self] succeeded in
            self?.handleDragEnded(succeeded: succeeded, generation: generation)
        }
        thumb.onDoubleClick = { [weak self] in self?.handleDoubleClick(generation: generation) }
        surface.addSubview(thumb)

        // Action pill overlaid on the card's bottom edge.
        let pill = NSVisualEffectView(frame: NSRect(x: (cardWidth - pillWidth) / 2,
                                                    y: pillMargin,
                                                    width: pillWidth,
                                                    height: pillHeight))
        pill.material = .hudWindow
        pill.blendingMode = .withinWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = pillHeight / 2
        pill.layer?.cornerCurve = .continuous
        pill.layer?.masksToBounds = true
        pill.alphaValue = Self.pillRestingAlpha

        var x: CGFloat = 6
        for entry in actions {
            let button = makeButton(symbol: entry.symbol, tooltip: entry.tooltip,
                                    action: entry.action, generation: generation,
                                    pointSize: 13)
            button.frame = NSRect(x: x, y: (pillHeight - buttonSize) / 2,
                                  width: buttonSize, height: buttonSize)
            if entry.action == #selector(saveRevealAction(_:)) {
                saveRevealButton = button
            }
            pill.addSubview(button)
            x += buttonSize + buttonSpacing
        }
        surface.addSubview(pill)
        actionPill = pill

        // Circular close at the top-left, revealed on hover.
        let closeSize: CGFloat = 20
        let close = NSVisualEffectView(frame: NSRect(x: 6,
                                                     y: cardHeight - closeSize - 6,
                                                     width: closeSize, height: closeSize))
        close.material = .hudWindow
        close.blendingMode = .withinWindow
        close.state = .active
        close.wantsLayer = true
        close.layer?.cornerRadius = closeSize / 2
        close.layer?.masksToBounds = true
        close.alphaValue = 0
        let closeButton = makeButton(symbol: "xmark", tooltip: "Close",
                                     action: #selector(closeAction(_:)), generation: generation,
                                     pointSize: 9)
        closeButton.frame = close.bounds
        close.addSubview(closeButton)
        surface.addSubview(close)
        closeControl = close

        return container
    }

    private func makeButton(symbol: String, tooltip: String, action: Selector,
                            generation: Int, pointSize: CGFloat) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)) ?? NSImage()
        let button = QuickAccessBarButton(image: image, target: self, action: action)
        button.tag = generation
        button.isBordered = false
        button.toolTip = tooltip
        button.contentTintColor = .labelColor
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
        setHoverAppearance(inside)
        if inside {
            dismissTask?.cancel()
            dismissTask = nil
        }
        guard let remaining = lifecycle.hoverChanged(for: generation, inside: inside) else { return }
        if !inside {
            startDismissTimer(after: remaining, generation: generation)
        }
    }

    /// Sharpens the action pill and reveals the close control while hovered.
    private func setHoverAppearance(_ inside: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            actionPill?.animator().alphaValue = inside ? 1 : Self.pillRestingAlpha
            closeControl?.animator().alphaValue = inside ? 1 : 0
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
        let target = dismissing.frame.offsetBy(dx: 0, dy: -10)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            dismissing.animator().alphaValue = 0
            dismissing.animator().setFrame(target, display: true)
        }, completionHandler: {
            dismissing.orderOut(nil)
        })
    }

    /// Removes the current panel with a quick fade (used when a new capture
    /// replaces it, so the change reads as a swap rather than a flash).
    private func teardown() {
        dismissTask?.cancel()
        dismissTask = nil
        if lifecycle.currentCaptureID == generation {
            _ = lifecycle.dismiss(for: generation)
        }
        if let outgoing = panel {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                outgoing.animator().alphaValue = 0
            }, completionHandler: {
                outgoing.orderOut(nil)
            })
        }
        panel = nil
        item = nil
        removeTempDragFile()
        saveRevealButton = nil
    }
}

// MARK: - Supporting views

/// Transparent container that only accepts clicks within the card rect,
/// so the shadow margin does not swallow desktop clicks.
final class QuickAccessPassThroughView: NSView {
    var interactiveRect: NSRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard interactiveRect.contains(local) else { return nil }
        return super.hitTest(point)
    }
}

/// Rounded card surface with a semantic background and hairline edge that
/// track appearance changes.
final class QuickAccessCardSurface: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

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
        layer?.cornerRadius = min(bounds.height / 2, 12)
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
        var resolved = NSColor.clear.cgColor
        if inside {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                resolved = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            layer?.backgroundColor = resolved
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
