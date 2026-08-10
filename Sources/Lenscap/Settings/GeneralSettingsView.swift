import AppKit
import SwiftUI

/// General tab: startup behavior, save location, and after-capture behavior.
struct GeneralSettingsView: View {
    @AppStorage(SettingsStore.Keys.saveDirectory) private var saveDirectoryPath = SettingsStore.defaultSaveDirectory.path
    @AppStorage(SettingsStore.Keys.saveToDisk) private var saveToDisk = true
    @AppStorage(SettingsStore.Keys.copyToClipboard) private var copyToClipboard = false
    @AppStorage(SettingsStore.Keys.showQuickAccess) private var showQuickAccess = true
    @AppStorage(SettingsStore.Keys.quickAccessDuration) private var quickAccessDuration = 8.0
    @AppStorage(SettingsStore.Keys.playSound) private var playSound = true
    @AppStorage(SettingsStore.Keys.captureDelay) private var captureDelay = 0
    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Lenscap at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in setLaunchAtLogin(newValue) }
                ))
                Text("Lenscap uses macOS Login Items. You can review or change its approval in System Settings → General → Login Items.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let launchAtLoginError {
                    Label(launchAtLoginError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section("Save Location") {
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text((saveDirectoryPath as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseSaveDirectory() }
                    }
                }
            }

            Section("After Capture") {
                Toggle("Save to disk", isOn: $saveToDisk)
                Toggle("Copy to clipboard", isOn: $copyToClipboard)
                Toggle("Show quick access overlay", isOn: $showQuickAccess)
                HStack {
                    Slider(value: $quickAccessDuration, in: 3...15, step: 1) {
                        Text("Overlay duration")
                    }
                    Text("\(Int(quickAccessDuration))s")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                .disabled(!showQuickAccess)
                Toggle("Play sound", isOn: $playSound)
                Picker("Capture delay", selection: $captureDelay) {
                    Text("Off").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LaunchAtLoginController.shared.isEnabled }
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = SettingsStore.shared.saveDirectory
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            SettingsStore.shared.saveDirectory = url
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginController.shared.setEnabled(enabled)
            launchAtLogin = LaunchAtLoginController.shared.isEnabled
            launchAtLoginError = nil
        } catch {
            launchAtLogin = LaunchAtLoginController.shared.isEnabled
            launchAtLoginError = "Could not update Login Items: \(error.localizedDescription)"
        }
    }
}
