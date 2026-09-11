import AppKit

@MainActor
final class CaptureShutdownCoordinator {
    private let needsWait: () -> Bool
    private let finishRecording: () async -> Void
    private let waitForStaging: () async -> Void
    private var task: Task<Void, Never>?

    init(needsWait: @escaping () -> Bool,
         finishRecording: @escaping () async -> Void,
         waitForStaging: @escaping () async -> Void) {
        self.needsWait = needsWait
        self.finishRecording = finishRecording
        self.waitForStaging = waitForStaging
    }

    func requestTermination(reply: @escaping @MainActor () -> Void) -> Bool {
        if task != nil { return true }
        guard needsWait() else { return false }
        task = Task { @MainActor in
            await finishRecording()
            await waitForStaging()
            task = nil
            reply()
        }
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor private lazy var shutdown = CaptureShutdownCoordinator(
        needsWait: {
            ScreenRecorder.shared.isRecording || ScreenRecorder.shared.isFinalizing
                || CloudCaptureBridge.shared.isStaging
        },
        finishRecording: { await ScreenRecorder.shared.stopAndSave() },
        waitForStaging: { await CloudCaptureBridge.shared.waitForStaging() }
    )

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

    /// Reopening offers capture controls when no window is visible. Settings
    /// only opens from its explicit action, never as a side effect of launching
    /// or activating the accessory app.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            CapturePanelWindowController.open()
        }
        // Do not let AppKit restore another retained, hidden window afterward.
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Await the existing recording finalization and durable local upload
        // staging, including a manual Stop already in progress. Never wait on network.
        let needsWait = shutdown.requestTermination {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return needsWait ? .terminateLater : .terminateNow
    }
}
