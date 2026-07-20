import AppKit
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsStore.shared.registerDefaults()
        AppCoordinator.shared.start()

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
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
