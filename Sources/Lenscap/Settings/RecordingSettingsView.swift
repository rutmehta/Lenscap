import SwiftUI

/// Recording tab: frame rates, cursor, and audio options.
struct RecordingSettingsView: View {
    @AppStorage(SettingsStore.Keys.videoFPS) private var videoFPS = 60
    @AppStorage(SettingsStore.Keys.gifFPS) private var gifFPS = 12
    @AppStorage(SettingsStore.Keys.showCursorInRecordings) private var showCursorInRecordings = true
    @AppStorage(SettingsStore.Keys.recordSystemAudio) private var recordSystemAudio = true

    var body: some View {
        Form {
            Section("Video") {
                Picker("Frame rate", selection: $videoFPS) {
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("Record system audio", isOn: $recordSystemAudio)
            }

            Section("GIF") {
                Picker("Frame rate", selection: $gifFPS) {
                    Text("8 fps").tag(8)
                    Text("12 fps").tag(12)
                    Text("15 fps").tag(15)
                }
            }

            Section("Options") {
                Toggle("Show cursor", isOn: $showCursorInRecordings)
            }
        }
        .formStyle(.grouped)
    }
}
