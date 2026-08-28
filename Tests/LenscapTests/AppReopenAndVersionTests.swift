import AppKit
import XCTest
@testable import Lenscap

@MainActor
final class AppReopenAndVersionTests: XCTestCase {
    func testReopeningAccessoryAppShowsAndReusesSettingsWindow() throws {
        let app = NSApplication.shared
        let delegate = AppDelegate()

        XCTAssertTrue(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
        let window = try XCTUnwrap(app.windows.first { $0.title == "General" })
        defer { window.close() }
        XCTAssertTrue(window.isVisible)

        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)

        XCTAssertTrue(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(app.windows.filter { $0.title == "General" }.count, 1)
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
