import ServiceManagement

/// Thin wrapper around the supported macOS 13+ login-item API. Because Lenscap is
/// distributed as an app bundle, `mainApp` can register the app itself; no helper
/// executable or manual Login Items instruction is needed.
@MainActor
final class LaunchAtLoginController {
    static let shared = LaunchAtLoginController()

    private init() {}

    var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        @unknown default:
            return false
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
