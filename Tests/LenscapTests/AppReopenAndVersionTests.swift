import AppKit
import XCTest
@testable import Lenscap

@MainActor
final class AppReopenAndVersionTests: XCTestCase {
    func testReopeningWithoutVisibleWindowsShowsCaptureControlsInsteadOfSettings() throws {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.windows.filter { $0.identifier?.rawValue == "LenscapSettings" }.forEach { $0.orderOut(nil) }
        defer {
            app.windows.filter {
                ["LenscapSettings", "LenscapCapturePanel"].contains($0.identifier?.rawValue ?? "")
            }.forEach { $0.close() }
        }

        XCTAssertFalse(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
        XCTAssertFalse(app.windows.contains { $0.identifier?.rawValue == "LenscapSettings" && $0.isVisible })
        let window = try XCTUnwrap(app.windows.first { $0.identifier?.rawValue == "LenscapCapturePanel" })
        XCTAssertTrue(window.isVisible)

        window.orderOut(nil)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(app.windows.filter { $0.identifier?.rawValue == "LenscapCapturePanel" }.count, 1)
        XCTAssertFalse(app.windows.contains { $0.identifier?.rawValue == "LenscapSettings" && $0.isVisible })
    }

    func testReopeningWithAVisibleWindowDoesNotReopenHiddenSettings() throws {
        let app = NSApplication.shared
        SettingsWindowController.open()
        let settings = try XCTUnwrap(app.windows.first { $0.identifier?.rawValue == "LenscapSettings" })
        settings.orderOut(nil)
        let existing = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                styleMask: [.titled], backing: .buffered, defer: false)
        existing.isReleasedWhenClosed = false
        existing.orderFront(nil)
        defer { settings.close(); existing.close() }

        XCTAssertFalse(AppDelegate().applicationShouldHandleReopen(app, hasVisibleWindows: true))

        XCTAssertFalse(settings.isVisible)
        XCTAssertTrue(existing.isVisible)
    }

    func testDisplayVersionPrefersShortVersionFromBundleFixture() throws {
        try withBundleFixture([
            "CFBundleShortVersionString": "9.8.7",
            "CFBundleVersion": "123"
        ]) { bundle in
            XCTAssertEqual(AppVersion.displayString(in: bundle), "9.8.7")
        }
    }

    func testDisplayVersionFallsBackToBuildVersionFromBundleFixture() throws {
        try withBundleFixture(["CFBundleVersion": "456"]) { bundle in
            XCTAssertEqual(AppVersion.displayString(in: bundle), "456")
        }
    }

    func testDisplayVersionUsesNonduplicatedFallbackForBundleFixtureWithoutMetadata() throws {
        try withBundleFixture([:]) { bundle in
            XCTAssertEqual(AppVersion.displayString(in: bundle), "unavailable")
        }
    }

    private func withBundleFixture(_ info: [String: String],
                                   body: (Bundle) throws -> Void) throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LenscapVersionFixture-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: infoURL)
        try body(XCTUnwrap(Bundle(url: bundleURL)))
    }
}
