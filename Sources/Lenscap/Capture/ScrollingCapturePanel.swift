import AppKit

/// Small non-activating control panel shown next to the selected area during a scrolling capture.
@MainActor
final class ScrollingCapturePanel: NSPanel {
    private let onCaptureStep: () -> Void
    private let onToggleAutoScroll: (Bool) -> Void
    private let onDone: () -> Void
    private let onCancel: () -> Void

    private let statusLabel = NSTextField(labelWithString: "No frames yet")
    private var autoButton: NSButton?

    init(near rect: CGRect, on screen: NSScreen,
         onCaptureStep: @escaping () -> Void,
         onToggleAutoScroll: @escaping (Bool) -> Void,
         onDone: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.onCaptureStep = onCaptureStep
        self.onToggleAutoScroll = onToggleAutoScroll
        self.onDone = onDone
        self.onCancel = onCancel
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        buildContent()
        position(near: rect, on: screen)
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Updates from the controller

    func update(frameCount: Int, estimatedHeight: Int) {
        if frameCount == 0 {
            statusLabel.stringValue = "No frames yet"
        } else {
            let plural = frameCount == 1 ? "frame" : "frames"
            statusLabel.stringValue = "\(frameCount) \(plural) · ~\(estimatedHeight) px"
        }
    }

    func setAutoScroll(on: Bool) {
        autoButton?.state = on ? .on : .off
    }

    // MARK: - Layout

    private func buildContent() {
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        let capture = makeButton(symbol: "camera", tooltip: "Capture Step", action: #selector(captureTapped))
        let auto = makeButton(symbol: "play.circle", tooltip: "Auto-Scroll", action: #selector(autoTapped))
        auto.setButtonType(.toggle)
        auto.alternateImage = symbolImage("pause.circle")
        autoButton = auto
        let done = makeButton(symbol: "checkmark.circle.fill", tooltip: "Done — stitch and save", action: #selector(doneTapped))
        done.contentTintColor = .controlAccentColor
        let cancel = makeButton(symbol: "xmark.circle", tooltip: "Cancel", action: #selector(cancelTapped))
        cancel.contentTintColor = .secondaryLabelColor

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let stack = NSStackView(views: [capture, auto, done, cancel, separator, statusLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)

        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        let size = stack.fittingSize
        setContentSize(size)
        contentView = container
    }

    private func position(near rect: CGRect, on screen: NSScreen) {
        let size = frame.size
        let visible = screen.visibleFrame
        let gap: CGFloat = 10

        var x = rect.midX - size.width / 2
        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))

        // Prefer below the selection so the panel stays out of the scroll area; flip above if cramped.
        var y = rect.minY - size.height - gap
        if y < visible.minY {
            y = rect.maxY + gap
        }
        y = max(visible.minY, min(y, visible.maxY - size.height))
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func makeButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(image: symbolImage(symbol) ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .labelColor
        button.toolTip = tooltip
        return button
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    // MARK: - Actions

    @objc private func captureTapped() { onCaptureStep() }
    @objc private func autoTapped(_ sender: NSButton) { onToggleAutoScroll(sender.state == .on) }
    @objc private func doneTapped() { onDone() }
    @objc private func cancelTapped() { onCancel() }
}
