import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click-to-arm hotkey recorder. While armed it swallows the next keyDown via a local
/// event monitor: ⎋ cancels, Delete clears the shortcut, and any key pressed with at
/// least one of ⌘/⌃/⌥ is stored through HotkeyManager.
struct HotkeyRecorderView: NSViewRepresentable {
    let action: HotkeyAction
    /// Bump to force the control to re-read its combo (e.g. after Restore Defaults).
    let refreshToken: UUID

    func makeNSView(context: Context) -> HotkeyRecorderButton {
        HotkeyRecorderButton(hotkeyAction: action)
    }

    func updateNSView(_ button: HotkeyRecorderButton, context: Context) {
        button.hotkeyAction = action
        button.refreshTitle()
    }
}

@MainActor
final class HotkeyRecorderButton: NSButton {
    var hotkeyAction: HotkeyAction
    private var monitor: Any?
    private var isArmed = false

    init(hotkeyAction: HotkeyAction) {
        self.hotkeyAction = hotkeyAction
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        target = self
        action = #selector(toggleArmed)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { disarm() }
    }

    func refreshTitle() {
        if isArmed {
            title = "Press Shortcut…"
        } else {
            title = HotkeyManager.shared.combo(for: hotkeyAction)?.displayString ?? "Record Shortcut"
        }
    }

    // MARK: - Arming

    @objc private func toggleArmed() {
        isArmed ? disarm() : arm()
    }

    private func arm() {
        isArmed = true
        refreshTitle()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isArmed else { return event }
                return self.handle(event)
            }
        }
    }

    private func disarm() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isArmed = false
        refreshTitle()
    }

    /// Returns nil to swallow the event while armed.
    private func handle(_ event: NSEvent) -> NSEvent? {
        switch Int(event.keyCode) {
        case kVK_Escape:
            disarm()
        case kVK_Delete, kVK_ForwardDelete:
            HotkeyManager.shared.setCombo(nil, for: hotkeyAction)
            disarm()
        default:
            let modifiers = KeyCombo.carbonModifiers(from: event.modifierFlags)
            let required = UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey)
            guard modifiers & required != 0 else {
                NSSound.beep()
                return nil
            }
            HotkeyManager.shared.setCombo(
                KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers),
                for: hotkeyAction
            )
            disarm()
        }
        return nil
    }
}
