import AppKit
import LenscapPermission

/// Durable, actionable UI shown when a user-initiated capture hits a missing
/// Screen Recording permission. Unlike the old one-shot HUD (which vanished
/// after a couple of seconds and gave no way forward), this panel stays up and
/// offers three real actions:
///
///   • Request Access        — fires the system authorization dialog once.
///   • Open System Settings… — deep-links to Privacy & Security.
///   • Retry                 — re-checks CGPreflight and proceeds when granted.
///
/// It also auto-recovers: if the user grants access in System Settings and the
/// app returns to the foreground, any pending (gated) capture runs immediately.
/// The panel is only ever surfaced from a user-initiated capture — never on app
/// launch — so it does not nag automatically.
@MainActor
final class ScreenCapturePermissionPresenter {
    static let shared = ScreenCapturePermissionPresenter()

    private var panel: NSPanel?
    private var pendingAction: (() -> Void)?
    private var activationObserver: NSObjectProtocol?

    private let statusDot = StatusDotView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var statusRow: NSStackView?
    private var requestButton: NSButton?
    private var settingsButton: NSButton?
    private var retryButton: NSButton?

    private init() {}

    var controller: ScreenCapturePermissionController {
        ScreenCapturePermissionController(provider: LiveScreenCapturePermissionProvider())
    }

    // MARK: - Presentation

    /// Show the permission panel. `pending` is invoked exactly once when access
    /// is obtained (Retry, grant-then-foreground, or Request Access success).
    func present(pending: @escaping () -> Void) {
        pendingAction = pending
        if panel == nil {
            buildPanel()
        }
        panel?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        installActivationObserver()
    }

    func dismiss() {
        pendingAction = nil
        panel?.orderOut(nil)
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    var isPresenting: Bool { panel != nil && panel?.isVisible == true }

    // MARK: - Actions

    @objc private func requestAccessTapped() {
        _ = controller.requestAccess()
        if controller.canCapture {
            runPendingIfAny()
        } else {
            setStatus("Waiting for permission…", tone: .waiting)
        }
    }

    @objc private func openSettingsTapped() {
        // Privacy & Security → Screen Recording. The legacy URL still resolves
        // on modern macOS and is the exact pane the user needs.
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func retryTapped() {
        if controller.canCapture {
            runPendingIfAny()
        } else {
            setStatus("Access is still off — turn on Lenscap in the list, then click Retry.",
                      tone: .attention)
        }
    }

    private func recheckAfterForeground() {
        // User granted access in System Settings and switched back to Lenscap.
        controller.gateForCapture()
        if controller.canCapture {
            runPendingIfAny()
        }
    }

    private func runPendingIfAny() {
        let action = pendingAction
        dismiss()
        action?()
    }

    private enum StatusTone {
        case waiting
        case attention
    }

    private func setStatus(_ text: String, tone: StatusTone) {
        statusLabel.stringValue = text
        switch tone {
        case .waiting:
            statusDot.dotColor = .tertiaryLabelColor
        case .attention:
            statusDot.dotColor = .systemOrange
        }
        statusRow?.isHidden = false
        resizePanelToFit()
    }

    /// Re-fit the panel to its content (the status line appears and changes
    /// length after actions), keeping the top-left corner anchored.
    private func resizePanelToFit() {
        guard let panel, let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        var frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize))
        frame.origin.x = panel.frame.origin.x
        frame.origin.y = panel.frame.maxY - frame.height
        panel.setFrame(frame, display: true)
    }

    // MARK: - Panel construction

    private func buildPanel() {
        let appIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
        appIcon.size = NSSize(width: 64, height: 64)
        let iconView = NSImageView(image: appIcon)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.widthAnchor.constraint(equalToConstant: 64).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let titleLabel = NSTextField(wrappingLabelWithString: "Lenscap needs Screen Recording access")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor

        let subtitleLabel = NSTextField(wrappingLabelWithString:
            "macOS grants this permission in System Settings → Privacy & Security → Screen Recording. Lenscap uses it to capture screenshots, text, and recordings.")
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor

        let headerText = NSStackView(views: [titleLabel, subtitleLabel])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 4

        let header = NSStackView(views: [iconView, headerText])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 14

        // Status line — hidden until Request Access or Retry reports back.
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        let status = NSStackView(views: [statusDot, statusLabel])
        status.orientation = .horizontal
        status.alignment = .firstBaseline
        status.spacing = 7
        status.isHidden = true
        statusRow = status

        // Footer: secondary actions on the left of the default, one blue default.
        let settings = NSButton(title: "Open System Settings…",
                                target: self, action: #selector(openSettingsTapped))
        settings.bezelStyle = .rounded

        let retry = NSButton(title: "Retry", target: self, action: #selector(retryTapped))
        retry.bezelStyle = .rounded

        let request = NSButton(title: "Request Access", target: self, action: #selector(requestAccessTapped))
        request.bezelStyle = .rounded
        request.keyEquivalent = "\r"

        settingsButton = settings
        retryButton = retry
        requestButton = request

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        footer.addView(settings, in: .trailing)
        footer.addView(retry, in: .trailing)
        footer.addView(request, in: .trailing)

        var rows: [NSView] = [header]

        // Drag-to-grant: System Settings' permission lists accept a dropped .app
        // bundle, so offer the app icon as a drag source (bundled builds only).
        var well: NSView?
        if Bundle.main.bundleURL.pathExtension == "app" {
            well = makeDragWell()
            rows.append(well!)
        }

        rows.append(status)
        rows.append(footer)

        let content = NSStackView(views: rows)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        content.setCustomSpacing(20, after: header)
        if let well {
            content.setCustomSpacing(16, after: well)
        }
        if let last = rows.dropLast().last {
            content.setCustomSpacing(20, after: last)
        }

        content.widthAnchor.constraint(equalToConstant: 460).isActive = true
        for view in [headerText, well, status, footer].compactMap({ $0 }) {
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24).isActive = true
        }

        let newPanel = NSPanel(contentRect: .zero,
                               styleMask: [.titled, .closable, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        newPanel.title = "Screen Recording"
        newPanel.isReleasedWhenClosed = false
        newPanel.hidesOnDeactivate = false
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.contentView = content
        content.layoutSubtreeIfNeeded()
        newPanel.setContentSize(content.fittingSize)
        newPanel.center()
        panel = newPanel
    }

    /// Full-width quiet well framing the draggable app icon — the primary,
    /// fastest path to granting the permission.
    private func makeDragWell() -> NSView {
        let well = WellView()
        well.wantsLayer = true
        well.layer?.cornerRadius = 12
        well.layer?.cornerCurve = .continuous
        well.layer?.borderWidth = 1

        let icon = DraggableAppIconView(appURL: Bundle.main.bundleURL)

        let caption = NSTextField(wrappingLabelWithString:
            "Drag this icon into the Screen Recording list")
        caption.font = .systemFont(ofSize: 13, weight: .medium)
        caption.textColor = .labelColor

        let subCaption = NSTextField(wrappingLabelWithString: "or use the buttons below")
        subCaption.font = .systemFont(ofSize: 11)
        subCaption.textColor = .tertiaryLabelColor

        let captions = NSStackView(views: [caption, subCaption])
        captions.orientation = .vertical
        captions.alignment = .leading
        captions.spacing = 3

        let row = NSStackView(views: [icon, captions])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        well.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            row.topAnchor.constraint(equalTo: well.topAnchor),
            row.bottomAnchor.constraint(equalTo: well.bottomAnchor),
        ])
        return well
    }

    private func installActivationObserver() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recheckAfterForeground()
            }
        }
    }
}

/// Quiet rounded well: quaternary fill with a separator-color hairline, both
/// re-resolved on appearance changes.
private final class WellView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

/// Small filled circle used by the status line; color tracks the current tone
/// and re-resolves on appearance changes.
private final class StatusDotView: NSView {
    var dotColor: NSColor = .tertiaryLabelColor {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 8).isActive = true
        heightAnchor.constraint(equalToConstant: 8).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var firstBaselineOffsetFromTop: CGFloat { 8 }

    override func draw(_ dirtyRect: NSRect) {
        dotColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// App icon that can be dragged straight into System Settings' permission list —
/// the list accepts a dropped .app bundle, which adds (or highlights) the app row.
final class DraggableAppIconView: NSImageView, NSDraggingSource {
    private let appURL: URL

    init(appURL: URL) {
        self.appURL = appURL
        super.init(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 56, height: 56)
        image = icon
        toolTip = "Drag into the Screen Recording list"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 56, height: 56) }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}
