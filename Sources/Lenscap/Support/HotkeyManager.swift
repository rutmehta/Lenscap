import AppKit
import Carbon.HIToolbox

enum HotkeyAction: String, CaseIterable {
    case captureArea
    case captureWindow
    case captureFullscreen
    case captureText
    case scrollingCapture
    case recordVideo
    case recordGIF
    case openHistory

    var title: String {
        switch self {
        case .captureArea: return "Capture Area"
        case .captureWindow: return "Capture Window"
        case .captureFullscreen: return "Capture Fullscreen"
        case .captureText: return "Capture Text (OCR)"
        case .scrollingCapture: return "Scrolling Capture"
        case .recordVideo: return "Record Video"
        case .recordGIF: return "Record GIF"
        case .openHistory: return "Open History"
        }
    }

    /// Defaults mirror the classic macOS / CleanShot X layout: ⌘⇧3 fullscreen,
    /// ⌘⇧4 area, ⌘⇧5 record. macOS's own screenshot shortcuts must be disabled in
    /// System Settings → Keyboard → Keyboard Shortcuts → Screenshots or both fire.
    var defaultCombo: KeyCombo? {
        let cmdShift = UInt32(cmdKey | shiftKey)
        switch self {
        case .captureArea: return KeyCombo(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: cmdShift)
        case .captureWindow: return KeyCombo(keyCode: UInt32(kVK_ANSI_6), carbonModifiers: cmdShift)
        case .captureFullscreen: return KeyCombo(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: cmdShift)
        case .captureText: return KeyCombo(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: cmdShift)
        case .scrollingCapture: return KeyCombo(keyCode: UInt32(kVK_ANSI_7), carbonModifiers: cmdShift)
        case .recordVideo: return KeyCombo(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: cmdShift)
        case .recordGIF: return nil
        case .openHistory: return nil
        }
    }

    @MainActor
    func perform() {
        let coordinator = AppCoordinator.shared
        switch self {
        case .captureArea: coordinator.captureArea()
        case .captureWindow: coordinator.captureWindow()
        case .captureFullscreen: coordinator.captureFullscreen()
        case .captureText: coordinator.captureText()
        case .scrollingCapture: coordinator.startScrollingCapture()
        case .recordVideo: coordinator.toggleRecording(mode: .video)
        case .recordGIF: coordinator.toggleRecording(mode: .gif)
        case .openHistory: coordinator.openHistory()
        }
    }
}

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }

    /// Lowercase character for cosmetic NSMenuItem key equivalents.
    var keyEquivalentCharacter: String {
        KeyCombo.keyNames[keyCode]?.lowercased() ?? ""
    }

    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += KeyCombo.keyNames[keyCode] ?? "?"
        return result
    }

    static let keyNames: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "⏎", UInt32(kVK_Escape): "⎋",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]
}

/// Registers system-wide hotkeys via Carbon. Combos are persisted per action in UserDefaults.
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var handlers: [UInt32: HotkeyAction] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    private let defaults = UserDefaults.standard

    private init() {}

    private func storageKey(for action: HotkeyAction) -> String {
        "hotkey.\(action.rawValue)"
    }

    /// nil = no hotkey assigned (either by default or explicitly cleared).
    func combo(for action: HotkeyAction) -> KeyCombo? {
        guard let raw = defaults.string(forKey: storageKey(for: action)) else {
            return action.defaultCombo
        }
        if raw == "off" { return nil }
        let parts = raw.split(separator: ",").compactMap { UInt32($0) }
        guard parts.count == 2 else { return action.defaultCombo }
        return KeyCombo(keyCode: parts[0], carbonModifiers: parts[1])
    }

    /// The action (other than `action`) currently assigned `combo`, if any.
    func conflictingAction(for combo: KeyCombo, excluding action: HotkeyAction) -> HotkeyAction? {
        HotkeyAction.allCases.first { $0 != action && self.combo(for: $0) == combo }
    }

    func setCombo(_ combo: KeyCombo?, for action: HotkeyAction) {
        if let combo {
            defaults.set("\(combo.keyCode),\(combo.carbonModifiers)", forKey: storageKey(for: action))
        } else {
            defaults.set("off", forKey: storageKey(for: action))
        }
        registerAll()
        if combo != nil, !handlers.values.contains(action) {
            // RegisterEventHotKey failed — the combo is owned by another app or the OS.
            Task { @MainActor in
                HUD.show("Couldn't register \(combo?.displayString ?? "shortcut") — already in use",
                         symbol: "keyboard")
            }
        }
    }

    /// Temporarily drops all global registrations (used while a shortcut is
    /// being recorded, so registered combos reach the recorder as key events).
    func pauseRegistrations() {
        unregisterAll()
    }

    func resumeRegistrations() {
        registerAll()
    }

    func registerAll() {
        unregisterAll()
        installHandlerIfNeeded()
        for action in HotkeyAction.allCases {
            guard let combo = combo(for: action) else { continue }
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x4C4E4350), id: nextID) // 'LNCP'
            let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                handlers[nextID] = action
                refs.append(ref)
            }
            nextID += 1
        }
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func handle(id: UInt32) {
        guard let action = handlers[id] else { return }
        Task { @MainActor in
            action.perform()
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            HotkeyManager.shared.handle(id: hotKeyID.id)
            return noErr
        }, 1, &eventType, nil, nil)
        handlerInstalled = true
    }
}
