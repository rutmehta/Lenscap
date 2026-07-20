import AppKit

/// Scrolling capture: select an area, scroll the content (manually or via synthesized
/// scroll events), and stitch the captured frames into one tall image.
@MainActor
final class ScrollingCaptureController {
    static let shared = ScrollingCaptureController()

    private nonisolated static let maxFrames = 40
    private nonisolated static let maxStitchedHeight = 20000

    private var selection: SelectionResult?
    private var frames: [CGImage] = []
    private var panel: ScrollingCapturePanel?
    private var autoScrollTask: Task<Void, Never>?
    private var isCapturingStep = false

    private init() {}

    // MARK: - Session lifecycle

    func begin() {
        guard panel == nil else { return } // A session is already running.
        SelectionOverlayController.selectRect(prompt: "Select the scrollable area") { [weak self] result in
            guard let self, let result, !result.wantsFullScreen || result.rect.height > 0 else { return }
            self.startSession(with: result)
        }
    }

    private func startSession(with result: SelectionResult) {
        selection = result
        frames = []
        let panel = ScrollingCapturePanel(
            near: result.rect, on: result.screen,
            onCaptureStep: { [weak self] in self?.captureStep() },
            onToggleAutoScroll: { [weak self] enabled in
                if enabled { self?.startAutoScroll() } else { self?.stopAutoScroll() }
            },
            onDone: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.cancel() })
        self.panel = panel
        panel.orderFrontRegardless()
        updateStatus()
        HUD.show("Scroll the content and press the camera to capture steps",
                 symbol: "arrow.up.and.down.square", duration: 2.5)
    }

    private func cancel() {
        stopAutoScroll()
        closePanel()
        frames = []
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
        selection = nil
    }

    // MARK: - Manual capture

    private func captureStep() {
        guard let selection, !isCapturingStep else { return }
        isCapturingStep = true
        Task { @MainActor in
            defer { isCapturingStep = false }
            guard let frame = await captureFrame(selection) else { return }
            appendFrame(frame)
        }
    }

    private func captureFrame(_ selection: SelectionResult) async -> CGImage? {
        do {
            return try await CaptureEngine.captureRect(selection)
        } catch {
            HUD.show("Capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Appends a frame and enforces the frame-count and height limits.
    /// Returns false when the session was finished by a limit.
    @discardableResult
    private func appendFrame(_ frame: CGImage) -> Bool {
        frames.append(frame)
        updateStatus()
        if estimatedStitchedHeight >= Self.maxStitchedHeight {
            HUD.show("Height limit reached — stitching", symbol: "ruler")
            finish()
            return false
        }
        if frames.count >= Self.maxFrames {
            finish()
            return false
        }
        return true
    }

    /// Rough estimate assuming ~40% overlap between consecutive frames (pixels).
    private var estimatedStitchedHeight: Int {
        guard let first = frames.first else { return 0 }
        return frames.dropFirst().reduce(first.height) { $0 + Int(Double($1.height) * 0.6) }
    }

    private func updateStatus() {
        panel?.update(frameCount: frames.count, estimatedHeight: estimatedStitchedHeight)
    }

    // MARK: - Auto-scroll

    private func startAutoScroll() {
        guard autoScrollTask == nil, let selection else { return }
        panel?.setAutoScroll(on: true)
        autoScrollTask = Task { @MainActor in
            var scrollsPosted = 0
            while !Task.isCancelled {
                guard let frame = await captureFrame(selection) else {
                    stopAutoScroll()
                    return
                }
                guard !Task.isCancelled, panel != nil else { return }
                if let previous = frames.last, ImageStitcher.pixelIdentical(previous, frame) {
                    if scrollsPosted == 0 {
                        // Nothing scrolled yet; skip the duplicate and start scrolling.
                    } else if scrollsPosted == 1 {
                        // The very first scroll had no effect — likely missing permission.
                        HUD.show("Enable Accessibility for auto-scroll, or scroll manually",
                                 symbol: "hand.raised", duration: 3)
                        stopAutoScroll()
                        return
                    } else {
                        finish() // Reached the bottom.
                        return
                    }
                } else if !appendFrame(frame) {
                    return // A limit ended the session.
                }
                postScrollEvent(for: selection)
                scrollsPosted += 1
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
    }

    private func stopAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        panel?.setAutoScroll(on: false)
    }

    /// Posts a synthetic scroll-down over the center of the selected area.
    private func postScrollEvent(for selection: SelectionResult) {
        let rect = selection.rect
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // CG event space is top-left-origin relative to the primary display.
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let cgPoint = CGPoint(x: center.x, y: primaryMaxY - center.y)

        CGWarpMouseCursorPosition(cgPoint)
        let amount = -Int32(max(40, min(600, rect.height * 0.6)))
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0) else { return }
        event.location = cgPoint
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Finish & stitch

    private func finish() {
        guard panel != nil else { return }
        stopAutoScroll()
        closePanel()
        let captured = frames
        frames = []
        guard !captured.isEmpty else { return }
        if captured.count == 1 {
            AppCoordinator.shared.ingest(cgImage: captured[0], kind: .screenshot)
            return
        }
        if captured.count > 3 {
            HUD.show("Stitching…", symbol: "square.stack.3d.down.right", duration: 4)
        }
        Task.detached(priority: .userInitiated) {
            let result = ImageStitcher.stitch(captured, maxHeight: Self.maxStitchedHeight)
            await MainActor.run {
                guard let image = result.image else {
                    HUD.show("Stitching failed", symbol: "exclamationmark.triangle")
                    return
                }
                AppCoordinator.shared.ingest(cgImage: image, kind: .screenshot)
                if result.cappedAtMax {
                    HUD.show("Stitched image capped at \(Self.maxStitchedHeight) px", symbol: "ruler")
                }
            }
        }
    }
}
