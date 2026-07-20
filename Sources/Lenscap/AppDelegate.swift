import AppKit
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsStore.shared.registerDefaults()
        AppCoordinator.shared.start()

        if !CGPreflightScreenCaptureAccess() {
            // Only trigger the system permission dialog once per install; afterwards the
            // dialog can't grant anyway (granting happens in System Settings), so nagging
            // on every launch just queues stale dialogs.
            let requestedKey = "didRequestScreenCaptureAccess"
            if !UserDefaults.standard.bool(forKey: requestedKey) {
                UserDefaults.standard.set(true, forKey: requestedKey)
                CGRequestScreenCaptureAccess()
            } else {
                HUD.show("Grant Screen Recording in System Settings, then relaunch Lenscap",
                         symbol: "exclamationmark.shield", duration: 4)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ScreenRecorder.shared.isRecording else { return .terminateNow }
        // Finish the in-flight recording (stop the stream, finalize the file,
        // move it to the save folder) before letting the process exit.
        Task { @MainActor in
            await ScreenRecorder.shared.stopAndSave()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
