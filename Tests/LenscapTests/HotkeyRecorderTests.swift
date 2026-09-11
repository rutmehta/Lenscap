import AppKit
import XCTest
@testable import Lenscap

@MainActor
final class HotkeyRecorderTests: XCTestCase {
    func testAccessibilityLabelNamesTheActionAndRefreshesAfterRebinding() {
        _ = NSApplication.shared
        let button = HotkeyRecorderButton(hotkeyAction: .captureArea)

        XCTAssertEqual(button.accessibilityLabel(), "Capture Area shortcut")

        button.hotkeyAction = .recordVideo
        button.refreshTitle()

        XCTAssertEqual(button.accessibilityLabel(), "Record Video shortcut")
    }

    func testAccessibilityValueReflectsTheDisplayedShortcut() {
        _ = NSApplication.shared
        let button = HotkeyRecorderButton(hotkeyAction: .captureArea)

        XCTAssertEqual(button.accessibilityValue() as? String, button.title)
    }

    func testRecorderFillRemainsVisibleWhenAmbientAppearanceDiffers() throws {
        _ = NSApplication.shared
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let button = HotkeyRecorderButton(hotkeyAction: .captureArea)

        button.appearance = light
        dark.performAsCurrentDrawingAppearance { button.refreshTitle() }
        XCTAssertLessThan(try compositedFillBrightness(of: button, over: 1), 0.97,
                          "The light recorder needs a visible fill against a white settings row.")

        button.appearance = dark
        light.performAsCurrentDrawingAppearance { button.refreshTitle() }
        XCTAssertGreaterThan(try compositedFillBrightness(of: button, over: 0.1), 0.13,
                             "The dark recorder needs a visible fill against a charcoal settings row.")
    }

    func testClosingRecorderWindowCancelsRecordingAndResumesShortcuts() {
        _ = NSApplication.shared
        var registrationEvents: [String] = []
        let button = HotkeyRecorderButton(
            hotkeyAction: .captureArea,
            pauseRegistrations: { registrationEvents.append("pause") },
            resumeRegistrations: { registrationEvents.append("resume") }
        )
        let window = makeWindow(containing: button)
        defer {
            window.contentView = nil
            window.close()
        }
        let originalTitle = button.title
        let originalCombo = HotkeyManager.shared.combo(for: .captureArea)

        button.performClick(nil)
        XCTAssertEqual(registrationEvents, ["pause"])
        XCTAssertEqual(button.title, "Press Shortcut…")

        window.close()

        XCTAssertEqual(button.title, originalTitle)
        XCTAssertEqual(registrationEvents, ["pause", "resume"])
        XCTAssertEqual(HotkeyManager.shared.combo(for: .captureArea), originalCombo)
    }

    func testLosingKeyStatusCancelsOnlyItsOwnRecorderAndResumesOnce() {
        _ = NSApplication.shared
        var registrationEvents: [String] = []
        let button = HotkeyRecorderButton(
            hotkeyAction: .captureArea,
            pauseRegistrations: { registrationEvents.append("pause") },
            resumeRegistrations: { registrationEvents.append("resume") }
        )
        let window = makeWindow(containing: button)
        let otherWindow = makeWindow(containing: NSView())
        defer {
            window.contentView = nil
            window.close()
            otherWindow.close()
        }
        let originalTitle = button.title
        button.performClick(nil)

        // Deliver AppKit's event without activating a test window or stealing focus.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: otherWindow)
        XCTAssertEqual(button.title, "Press Shortcut…")
        XCTAssertEqual(registrationEvents, ["pause"])

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        window.close()

        XCTAssertEqual(button.title, originalTitle)
        XCTAssertEqual(registrationEvents, ["pause", "resume"])
    }

    func testAccessibilityValueAnnouncesRecordingAndRestoresTheShortcut() {
        _ = NSApplication.shared
        let button = HotkeyRecorderButton(
            hotkeyAction: .captureArea,
            pauseRegistrations: {},
            resumeRegistrations: {}
        )
        let window = makeWindow(containing: button)
        defer {
            window.contentView = nil
            window.close()
        }
        let originalTitle = button.title

        button.performClick(nil)
        XCTAssertEqual(button.accessibilityLabel(), "Capture Area shortcut")
        XCTAssertEqual(button.accessibilityValue() as? String, "Recording shortcut")

        window.close()
        XCTAssertEqual(button.accessibilityValue() as? String, originalTitle)
    }

    private func makeWindow(containing content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }

    private func compositedFillBrightness(of button: NSButton, over background: CGFloat) throws -> CGFloat {
        let cgColor = try XCTUnwrap(button.layer?.backgroundColor)
        let color = try XCTUnwrap(NSColor(cgColor: cgColor)?.usingColorSpace(.deviceRGB))
        let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
        return brightness * color.alphaComponent + background * (1 - color.alphaComponent)
    }
}
