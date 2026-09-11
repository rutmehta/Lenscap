import SwiftUI

/// Still-capture output, saved-image format, and selection preferences.
struct ScreenshotsSettingsView: View {
    @ObservedObject private var cloud = CloudController.shared
    @AppStorage(SettingsStore.Keys.saveToDisk) private var saveToDisk = true
    @AppStorage(SettingsStore.Keys.copyToClipboard) private var copyToClipboard = true
    @AppStorage(SettingsStore.Keys.showQuickAccess) private var showQuickAccess = true
    @AppStorage(SettingsStore.Keys.fileFormat) private var fileFormat = "png"
    @AppStorage(SettingsStore.Keys.jpegQuality) private var jpegQuality = 0.9
    @AppStorage(SettingsStore.Keys.downscaleRetina) private var downscaleRetina = false
    @AppStorage(SettingsStore.Keys.captureDelay) private var captureDelay = 0
    @AppStorage(SettingsStore.Keys.showCursorInScreenshots) private var showCursorInScreenshots = false
    @AppStorage(SettingsStore.Keys.showMagnifier) private var showMagnifier = true

    var body: some View {
        Form {
            Section("After capture") {
                Toggle("Save screenshots automatically", isOn: $saveToDisk)
                Toggle("Copy screenshots to clipboard", isOn: $copyToClipboard)
                if !saveToDisk && !copyToClipboard && !showQuickAccess && !cloud.isConfigured {
                    CaptureOutputWarning()
                }
            }

            Section {
                LabeledContent("File format") {
                    Picker("File format", selection: $fileFormat) {
                        Text("PNG").tag("png")
                        Text("JPEG").tag("jpg")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                if fileFormat == "jpg" {
                    LabeledContent("JPEG quality") {
                        HStack(spacing: 12) {
                            Slider(value: $jpegQuality, in: 0.1...1.0) {
                                Text("JPEG quality")
                            }
                            .labelsHidden()
                            .frame(width: 150)
                            Text("\(Int(jpegQuality * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                Toggle("Save Retina images at 1×", isOn: $downscaleRetina)
            } header: {
                Text("Saved images")
            } footer: {
                Text("These options apply to saved files. Clipboard images remain full-resolution PNGs.")
            }

            Section("Capture") {
                Picker("Delay before capture", selection: $captureDelay) {
                    Text("None").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                Toggle("Include pointer in area and fullscreen captures", isOn: $showCursorInScreenshots)
                Toggle("Show magnifier during area selection", isOn: $showMagnifier)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
