import AppKit
import SwiftUI

/// Shared file, preview, and startup preferences for screenshots and recordings.
struct GeneralSettingsView: View {
    @ObservedObject private var cloud = CloudController.shared
    @AppStorage(SettingsStore.Keys.saveDirectory) private var saveDirectoryPath = SettingsStore.defaultSaveDirectory.path
    @AppStorage(SettingsStore.Keys.filenamePrefix) private var filenamePrefix = "Lenscap"
    @AppStorage(SettingsStore.Keys.saveToDisk) private var saveToDisk = true
    @AppStorage(SettingsStore.Keys.copyToClipboard) private var copyToClipboard = true
    @AppStorage(SettingsStore.Keys.showQuickAccess) private var showQuickAccess = true
    @AppStorage(SettingsStore.Keys.quickAccessDuration) private var quickAccessDuration = 8.0
    @AppStorage(SettingsStore.Keys.playSound) private var playSound = true
    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Save captures to") {
                    HStack(spacing: 8) {
                        Text((saveDirectoryPath as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(saveDirectoryPath)
                        Button("Choose…") { chooseSaveDirectory() }
                    }
                }
                TextField("Filename prefix", text: $filenamePrefix)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Files")
            } footer: {
                Text("The folder and filename prefix apply to screenshots, videos, and GIFs.")
            }

            Section("Capture preview") {
                Toggle("Show a preview after capture", isOn: $showQuickAccess)
                LabeledContent("Dismiss after") {
                    HStack(spacing: 12) {
                        Slider(value: $quickAccessDuration, in: 3...15, step: 1) {
                            Text("Preview duration")
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        Text("\(Int(quickAccessDuration)) seconds")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 76, alignment: .trailing)
                    }
                }
                .disabled(!showQuickAccess)
                Toggle("Play capture sound", isOn: $playSound)
                if !saveToDisk && !copyToClipboard && !showQuickAccess && !cloud.isConfigured {
                    CaptureOutputWarning()
                }
            }

            Section {
                Toggle("Open Lenscap at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in setLaunchAtLogin(newValue) }
                ))
                if let launchAtLoginError {
                    Label(launchAtLoginError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("You can manage login items in System Settings → General → Login Items.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
