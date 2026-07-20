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

    func applicationWillTerminate(_ notification: Notification) {
        if ScreenRecorder.shared.isRecording {
            Task { await ScreenRecorder.shared.stopAndSave() }
        }
    }
}
