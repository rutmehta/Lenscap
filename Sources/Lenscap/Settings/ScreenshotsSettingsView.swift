import SwiftUI

/// Screenshots tab: file format, naming, and capture options.
struct ScreenshotsSettingsView: View {
    @AppStorage(SettingsStore.Keys.fileFormat) private var fileFormat = "png"
    @AppStorage(SettingsStore.Keys.jpegQuality) private var jpegQuality = 0.9
    @AppStorage(SettingsStore.Keys.filenamePrefix) private var filenamePrefix = "Lenscap"
    @AppStorage(SettingsStore.Keys.downscaleRetina) private var downscaleRetina = false
    @AppStorage(SettingsStore.Keys.showCursorInScreenshots) private var showCursorInScreenshots = false

    var body: some View {
        Form {
            Section("File Format") {
                Picker("Format", selection: $fileFormat) {
                    Text("PNG").tag("png")
                    Text("JPG").tag("jpg")
                }
                .pickerStyle(.segmented)
                HStack {
                    Slider(value: $jpegQuality, in: 0.1...1.0) {
                        Text("JPEG quality")
                    }
                    Text("\(Int(jpegQuality * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .disabled(fileFormat != "jpg")
                TextField("Filename prefix", text: $filenamePrefix)
            }

            Section("Options") {
                Toggle("Downscale Retina screenshots to 1x", isOn: $downscaleRetina)
                Toggle("Show cursor in screenshots", isOn: $showCursorInScreenshots)
            }
        }
        .formStyle(.grouped)
    }
}
