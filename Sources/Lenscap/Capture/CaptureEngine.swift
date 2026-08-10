import AppKit
import CoreGraphics
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayNotFound
    case windowGone
    case screenCapturePermissionDenied

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "Could not find the display to capture."
        case .windowGone: return "The selected window is no longer available."
        case .screenCapturePermissionDenied:
            return "Screen Recording permission is required to capture."
        }
    }
}

/// Still-image capture built on ScreenCaptureKit.
enum CaptureEngine {
    /// ScreenCaptureKit never returns a real frame (it yields a black/empty
    /// image) without Screen Recording permission. Guard the TCC-touching calls
    /// so we fail fast with a clear error instead of silently capturing nothing.
    static func requireScreenCapturePermission() throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.screenCapturePermissionDenied
        }
    }

    static func shareableContent() async throws -> SCShareableContent {
        try requireScreenCapturePermission()
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    static func display(for screen: NSScreen, in content: SCShareableContent) throws -> SCDisplay {
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.displayNotFound
        }
        return display
    }

    /// Excludes every window of this app (countdown HUD, quick access overlay,
    /// scrolling-capture panel) from still captures, mirroring the recording path.
    static func filterExcludingOwnWindows(display: SCDisplay,
                                          content: SCShareableContent) -> SCContentFilter {
        let pid = getpid()
        // Excluding the application covers windows created after the filter too.
        if let ownApp = content.applications.first(where: { $0.processID == pid }) {
            return SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: [])
        }
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
        return SCContentFilter(display: display, excludingWindows: ownWindows)
    }

    /// Captures a rect given in global AppKit coordinates (origin bottom-left).
    static func captureRect(_ selection: SelectionResult) async throws -> CGImage {
        let screen = selection.screen
        let content = try await shareableContent()
        let display = try display(for: screen, in: content)

        let scale = screen.backingScaleFactor
        let screenFrame = screen.frame
        // Convert to the display-local, top-left-origin space ScreenCaptureKit expects.
        let local = CGRect(x: selection.rect.minX - screenFrame.minX,
                           y: screenFrame.maxY - selection.rect.maxY,
                           width: selection.rect.width,
                           height: selection.rect.height)

        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = Int(local.width * scale)
        config.height = Int(local.height * scale)
        config.showsCursor = SettingsStore.shared.showCursorInScreenshots
        config.captureResolution = .best

        let filter = filterExcludingOwnWindows(display: display, content: content)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func captureFullDisplay(containing screen: NSScreen) async throws -> CGImage {
        let content = try await shareableContent()
        let display = try display(for: screen, in: content)

        let filter = filterExcludingOwnWindows(display: display, content: content)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = SettingsStore.shared.showCursorInScreenshots
        config.captureResolution = .best

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func captureWindow(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
