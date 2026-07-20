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

    /// Only one recorder may be armed at a time across all rows.
    private static weak var armedButton: HotkeyRecorderButton?

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
        Self.armedButton?.disarm()
        Self.armedButton = self
        isArmed = true
        // Drop the app's global registrations while recording, otherwise pressing a
        // registered combo fires its action instead of reaching this monitor.
        HotkeyManager.shared.pauseRegistrations()
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
        if isArmed {
            isArmed = false
            HotkeyManager.shared.resumeRegistrations()
        }
        if Self.armedButton === self { Self.armedButton = nil }
        refreshTitle()
    }

    /// Returns nil to swallow the event while armed.
    private func handle(_ event: NSEvent) -> NSEvent? {
        let modifiers = KeyCombo.carbonModifiers(from: event.modifierFlags)
        let commandLike = UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey)

        // Escape/Delete only cancel/clear when pressed bare — with ⌘/⌃/⌥ they
        // fall through and are recorded like any other key.
        guard modifiers & commandLike != 0 else {
            switch Int(event.keyCode) {
            case kVK_Escape:
                disarm()
            case kVK_Delete, kVK_ForwardDelete:
                HotkeyManager.shared.setCombo(nil, for: hotkeyAction)
                disarm()
            default:
                NSSound.beep()
            }
            return nil
        }

        let combo = KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers)
        if let conflict = HotkeyManager.shared.conflictingAction(for: combo, excluding: hotkeyAction) {
            NSSound.beep()
            HUD.show("\(combo.displayString) is already used by \(conflict.title)", symbol: "keyboard")
            return nil
        }
        HotkeyManager.shared.setCombo(combo, for: hotkeyAction)
        disarm()
        return nil
    }
}
