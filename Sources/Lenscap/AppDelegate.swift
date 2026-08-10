import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start Sparkle before anything else so update checks can run in the
        // background while the user is capturing screenshots / recording.
        UpdaterController.shared.start()

        SettingsStore.shared.registerDefaults()
        AppCoordinator.shared.start()
        DebugSnapshotController.captureIfRequested()

        // Screen Recording permission is intentionally NOT requested or nagged
        // at launch. The old design called CGRequestScreenCaptureAccess once and
        // cached a `didRequestScreenCaptureAccess` default; combined with a
        // missing TCC grant this trapped the user with a stale flag and a
        // transient HUD. The durable permission panel is now surfaced by the
        // gate inside AppCoordinator on every user-initiated capture, where the
        // system dialog can actually be acted on.
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
