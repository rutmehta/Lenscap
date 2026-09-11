import AppKit
import SwiftUI

/// A single, resizable Settings window. Reopening preserves the selected category.
@MainActor
final class SettingsWindowController {
    private static var window: NSWindow?

    static func open() {
        if window == nil {
            window = makeWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// A capture may activate Lenscap, but must not raise its last Settings
    /// window over the screen being captured. Reopening remains explicit.
    static func hideForCapture() {
        window?.orderOut(nil)
    }

    // MARK: - Window construction

    private static func makeWindow() -> NSWindow {
        let size = NSSize(width: 820, height: 640)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: SettingsRootView())
        window.setContentSize(size)
        window.contentMinSize = NSSize(width: 760, height: 580)
        window.title = "Lenscap Settings"
        window.identifier = NSUserInterfaceItemIdentifier("LenscapSettings")
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case screenshots = "Screenshots"
    case recording = "Recording"
    case cloud = "Cloud"
    case shortcuts = "Shortcuts"
    case about = "About"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .screenshots: return "camera"
        case .recording: return "record.circle"
        case .cloud: return "icloud"
        case .shortcuts: return "keyboard"
        case .about: return "info.circle"
        }
    }

    @ViewBuilder var content: some View {
        switch self {
        case .general: GeneralSettingsView()
        case .screenshots: ScreenshotsSettingsView()
        case .recording: RecordingSettingsView()
        case .cloud: CloudSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        case .about: AboutSettingsView()
        }
    }
}

private struct SettingsRootView: View {
    @State private var selection: SettingsPage? = .general

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Lenscap")
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.top, 22)
                    .padding(.bottom, 12)
                List(SettingsPage.allCases, selection: $selection) { page in
                    Label(page.rawValue, systemImage: page.symbol)
                        .padding(.vertical, 5)
                        .tag(page)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                Text("Version \(AppVersion.displayString())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(18)
            }
            .frame(width: 180)
            .background(SettingsSidebarBackground())

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text((selection ?? .general).rawValue)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                (selection ?? .general).content
                    .id(selection)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 760, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SettingsSidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
