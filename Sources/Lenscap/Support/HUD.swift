import AppKit

/// Small transient toast shown near the top of the main screen ("Text copied", errors, etc.).
@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var dismissTask: Task<Void, Never>?

    static func show(_ message: String, symbol: String? = nil, duration: TimeInterval = 1.6) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: message)
        label.textColor = .labelColor
        label.font = .systemFont(ofSize: 13, weight: .medium)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)) {
            let imageView = NSImageView(image: image)
            imageView.contentTintColor = .labelColor
            stack.addArrangedSubview(imageView)
        }
        stack.addArrangedSubview(label)

        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
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
        newPanel.ignoresMouseEvents = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.contentView = container

        var finalFrame = NSRect(origin: .zero, size: size)
        if let screen = NSScreen.main {
            finalFrame.origin = NSPoint(x: screen.frame.midX - size.width / 2,
                                        y: screen.visibleFrame.maxY - size.height - 60)
        }

        // Gentle scale + fade in.
        newPanel.setFrame(finalFrame.insetBy(dx: size.width * 0.04, dy: size.height * 0.04), display: false)
        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            newPanel.animator().alphaValue = 1
            newPanel.animator().setFrame(finalFrame, display: true)
        }
        panel = newPanel

        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                newPanel.animator().alphaValue = 0
            }, completionHandler: {
                newPanel.orderOut(nil)
            })
        }
    }
}
