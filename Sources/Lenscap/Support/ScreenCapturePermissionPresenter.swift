import AppKit
import LenscapPermission

/// Durable, actionable UI shown when a user-initiated capture hits a missing
/// Screen Recording permission. Unlike the old one-shot HUD (which vanished
/// after a couple of seconds and gave no way forward), this panel stays up and
/// offers three real actions:
///
///   • Request Access        — fires the system authorization dialog once.
///   • Open Screen Recording Settings… — deep-links to Privacy & Security.
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

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
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
            setDetail("Still waiting on macOS. If no prompt appeared, grant access in System Settings, then tap Retry.")
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
            setDetail("Screen Recording access is still off. Turn it on for Lenscap in System Settings, then tap Retry.")
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

    private func setDetail(_ text: String) {
        detailLabel.stringValue = text
    }

    // MARK: - Panel construction

    private func buildPanel() {
        titleLabel.stringValue = "Lenscap needs Screen Recording access"
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 0

        detailLabel.stringValue = "Allow Lenscap in System Settings → Privacy & Security → Screen Recording to capture screenshots, text, and recordings."
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 0

        let request = NSButton(title: "Request Access", target: self, action: #selector(requestAccessTapped))
        request.keyEquivalent = "\r"
        request.bezelStyle = .rounded

        let settings = NSButton(title: "Open Screen Recording Settings…",
                                target: self, action: #selector(openSettingsTapped))
        settings.bezelStyle = .rounded

        let retry = NSButton(title: "Retry", target: self, action: #selector(retryTapped))
        retry.bezelStyle = .rounded
        requestButton = request
        settingsButton = settings
        retryButton = retry

        let buttonStack = NSStackView(views: [request, settings, retry])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 10
        buttonStack.alignment = .centerY

        var rows: [NSView] = [titleLabel, detailLabel]

        // Drag-to-grant: System Settings' permission lists accept a dropped .app
        // bundle, so offer the app icon as a drag source (bundled builds only).
        if Bundle.main.bundleURL.pathExtension == "app" {
            let icon = DraggableAppIconView(appURL: Bundle.main.bundleURL)
            let hint = NSTextField(wrappingLabelWithString:
                "Or drag this icon straight into the Screen Recording list in System Settings.")
            hint.font = .systemFont(ofSize: 12)
            hint.textColor = .secondaryLabelColor
            hint.maximumNumberOfLines = 0
            let dragRow = NSStackView(views: [icon, hint])
            dragRow.orientation = .horizontal
            dragRow.spacing = 12
            dragRow.alignment = .centerY
            rows.append(dragRow)
        }
        rows.append(buttonStack)

        let content = NSStackView(views: rows)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)

        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        container.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.leadingAnchor.constraint(equalTo: container.leadingAnchor).isActive = true
        content.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true
        content.topAnchor.constraint(equalTo: container.topAnchor).isActive = true
        content.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true

        let widthConstraint = container.widthAnchor.constraint(greaterThanOrEqualToConstant: 380)
        widthConstraint.isActive = true

        let newPanel = NSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: 420, height: 160)),
                               styleMask: [.titled, .closable, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        newPanel.title = "Screen Recording Access"
        newPanel.isReleasedWhenClosed = false
        newPanel.hidesOnDeactivate = false
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.contentView = container
        newPanel.center()
        panel = newPanel
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
