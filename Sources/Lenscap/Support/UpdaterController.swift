import AppKit
import Sparkle

/// Owns the single SPUStandardUpdaterController used by Lenscap.
///
/// Both the app delegate (at launch) and the status-bar "Check for Updates…"
/// menu item drive this shared instance, so the standard Sparkle updater and
/// its user driver stay consistent across auto-checks and manual checks.
@MainActor
final class UpdaterController {
    static let shared = UpdaterController()

    private(set) var controller: SPUStandardUpdaterController?

    private init() {}

    /// Starts Sparkle with the normal consent/initialization flow:
    /// `startingUpdater: true` enables background checks once the user has
    /// consented (Sparkle shows the "check automatically?" prompt on first
    /// launch), and the standard user driver presents update UI.
    func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }
}
