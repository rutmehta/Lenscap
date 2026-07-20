import AppKit

/// Small floating chip shown while recording: red dot + elapsed time + Stop button.
/// Non-activating; excluded from the capture itself via the stream's content filter.
@MainActor
final class RecordingHUDController: NSObject {
    private var panel: NSPanel?
    private var timer: Timer?
    private let startDate = Date()
    private let timeLabel = NSTextField(labelWithString: "00:00")

    // MARK: - Presentation

    /// Shows the chip near the top of `screen`, outside `recordedRect` when there is room.
    func show(on screen: NSScreen, avoiding recordedRect: CGRect?) {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9),
        ])

        // Slow opacity breathe so the dot reads as "live" without being distracting.
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.layer?.add(pulse, forKey: "pulse")

        timeLabel.textColor = .labelColor
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.stringValue = "00:00"

        let stopIcon = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        let stopButton = NSButton(image: stopIcon ?? NSImage(), target: self, action: #selector(stopPressed))
        stopButton.isBordered = false
        stopButton.bezelStyle = .regularSquare
        stopButton.contentTintColor = .white
        stopButton.wantsLayer = true
        stopButton.layer?.backgroundColor = NSColor.systemRed.cgColor
        stopButton.layer?.cornerRadius = 6
        stopButton.layer?.cornerCurve = .continuous
        stopButton.toolTip = "Stop Recording"
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stopButton.widthAnchor.constraint(equalToConstant: 30),
            stopButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        let stack = NSStackView(views: [dot, timeLabel, stopButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.setCustomSpacing(10, after: timeLabel)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 8)

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
        let newPanel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.level = .statusBar
        newPanel.hasShadow = true
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.contentView = container
        newPanel.setFrameOrigin(Self.origin(for: size, on: screen, avoiding: recordedRect))
        newPanel.orderFrontRegardless()
        panel = newPanel

        let newTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Private

    private func tick() {
        let elapsed = max(0, Int(Date().timeIntervalSince(startDate)))
        timeLabel.stringValue = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    @objc private func stopPressed() {
        Task { await ScreenRecorder.shared.stopAndSave() }
    }

    /// Top-center of the screen by default; slots into the gap above or below the
    /// recorded rect when one is big enough, so the chip stays out of the frame.
    private static func origin(for size: NSSize, on screen: NSScreen,
                               avoiding recordedRect: CGRect?) -> NSPoint {
        let margin: CGFloat = 12
        var x = screen.frame.midX - size.width / 2
        var y = screen.visibleFrame.maxY - size.height - margin

        if let rect = recordedRect {
            let gapAbove = screen.frame.maxY - rect.maxY
            let gapBelow = rect.minY - screen.frame.minY
            if gapAbove >= size.height + margin * 2 {
                x = rect.midX - size.width / 2
                y = rect.maxY + (gapAbove - size.height) / 2
            } else if gapBelow >= size.height + margin * 2 {
                x = rect.midX - size.width / 2
                y = rect.minY - (gapBelow + size.height) / 2
            }
        }

        x = min(max(x, screen.frame.minX + margin), screen.frame.maxX - size.width - margin)
        y = min(max(y, screen.frame.minY + margin), screen.frame.maxY - size.height - margin)
        return NSPoint(x: x, y: y)
    }
}
