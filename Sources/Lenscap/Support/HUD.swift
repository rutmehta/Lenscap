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
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let imageView = NSImageView(image: image)
            imageView.contentTintColor = .white
            stack.addArrangedSubview(imageView)
        }
        stack.addArrangedSubview(label)

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        container.layer?.cornerRadius = 10
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

        if let screen = NSScreen.main {
            let x = screen.frame.midX - size.width / 2
            let y = screen.visibleFrame.maxY - size.height - 60
            newPanel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        newPanel.orderFrontRegardless()
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
