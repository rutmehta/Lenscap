import AppKit

/// The primary left-click surface for Lenscap. It is intentionally a small control
/// panel rather than a long list of hotkeys: the common capture choices are visible,
/// grouped, and individually labelled for keyboard navigation and VoiceOver.
@MainActor
final class MenuBarPanelViewController: NSViewController {
    enum Action: String {
        case captureArea
        case captureWindow
        case captureFullscreen
        case scrollingCapture
        case captureText
        case recordVideo
        case recordGIF
        case history
        case settings
    }

    var onAction: ((Action) -> Void)?
    var isRecording = false {
        didSet { updateRecordingState() }
    }

    private let root = NSVisualEffectView()
    private let statusLabel = NSTextField(labelWithString: "Ready to capture")
    private let recordingBadge = NSTextField(labelWithString: "")
    private var videoButton: NSButton?
    private var gifButton: NSButton?

    override func loadView() {
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root
        buildView()
    }

    private func buildView() {
        let outer = NSStackView()
        outer.orientation = .vertical
        outer.spacing = 12
        outer.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18)
        outer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outer.topAnchor.constraint(equalTo: root.topAnchor),
            outer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 348),
            root.heightAnchor.constraint(equalToConstant: 484),
        ])

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        let icon = NSImageView(image: NSImage(systemSymbolName: "camera.viewfinder",
                                               accessibilityDescription: "Lenscap") ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .controlAccentColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.spacing = 2
        let title = NSTextField(labelWithString: "Lenscap")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Capture what matters")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        titleStack.addArrangedSubview(title)
        titleStack.addArrangedSubview(subtitle)

        recordingBadge.font = .systemFont(ofSize: 11, weight: .semibold)
        recordingBadge.textColor = .systemRed
        recordingBadge.alignment = .right
        recordingBadge.setContentHuggingPriority(.required, for: .horizontal)
        header.addArrangedSubview(icon)
        header.addArrangedSubview(titleStack)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(recordingBadge)
        outer.addArrangedSubview(header)

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.spacing = 7
        let statusDot = NSView(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        statusDot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        statusRow.addArrangedSubview(statusDot)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusRow.addArrangedSubview(statusLabel)
        statusRow.addArrangedSubview(NSView())
        outer.addArrangedSubview(statusRow)

        outer.addArrangedSubview(sectionLabel("CAPTURE"))
        let captureGrid = grid([
            actionButton("Capture Area", symbol: "rectangle.dashed", action: .captureArea),
            actionButton("Window", symbol: "macwindow", action: .captureWindow),
            actionButton("Fullscreen", symbol: "display", action: .captureFullscreen),
            actionButton("Scrolling", symbol: "arrow.up.and.down.square", action: .scrollingCapture),
        ])
        outer.addArrangedSubview(captureGrid)

        outer.addArrangedSubview(sectionLabel("TOOLS"))
        outer.addArrangedSubview(actionButton("OCR", symbol: "text.viewfinder", action: .captureText))

        outer.addArrangedSubview(sectionLabel("CREATE"))
        videoButton = actionButton("Record Video", symbol: "record.circle", action: .recordVideo)
        gifButton = actionButton("Record GIF", symbol: "photo.stack", action: .recordGIF)
        outer.addArrangedSubview(grid([videoButton!, gifButton!]))

        let divider = NSBox()
        divider.boxType = .separator
        outer.addArrangedSubview(divider)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.addArrangedSubview(footerButton("History", symbol: "clock.arrow.circlepath", action: .history))
        footer.addArrangedSubview(footerButton("Settings", symbol: "gearshape", action: .settings))
        outer.addArrangedSubview(footer)

        updateRecordingState()
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func grid(_ buttons: [NSButton]) -> NSStackView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.spacing = 7
        for offset in stride(from: 0, to: buttons.count, by: 2) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 7
            row.distribution = .fillEqually
            row.addArrangedSubview(buttons[offset])
            if offset + 1 < buttons.count {
                row.addArrangedSubview(buttons[offset + 1])
            } else {
                row.addArrangedSubview(NSView())
            }
            rows.addArrangedSubview(row)
        }
        return rows
    }

    private func actionButton(_ title: String, symbol: String, action: Action) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(actionPressed(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        button.setAccessibilityLabel(title)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.contentTintColor = .labelColor
        button.alignment = .left
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 38).isActive = true
        return button
    }

    private func footerButton(_ title: String, symbol: String, action: Action) -> NSButton {
        let button = actionButton(title, symbol: symbol, action: action)
        button.bezelStyle = .texturedRounded
        button.controlSize = .regular
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func updateRecordingState() {
        guard isViewLoaded else { return }
        if isRecording {
            statusLabel.stringValue = "Recording in progress"
            recordingBadge.stringValue = "● LIVE"
            videoButton?.title = "Stop Recording"
            videoButton?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Recording")
            gifButton?.isEnabled = false
        } else {
            statusLabel.stringValue = "Ready to capture"
            recordingBadge.stringValue = ""
            videoButton?.title = "Record Video"
            videoButton?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record Video")
            gifButton?.isEnabled = true
        }
    }

    @objc private func actionPressed(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let action = Action(rawValue: raw) else { return }
        onAction?(action)
    }
}
