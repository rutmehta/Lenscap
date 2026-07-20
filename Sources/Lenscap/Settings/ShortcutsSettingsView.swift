import SwiftUI

/// Shortcuts tab: one recorder row per hotkey action.
struct ShortcutsSettingsView: View {
    @State private var refreshToken = UUID()

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases, id: \.rawValue) { action in
                    LabeledContent(action.title) {
                        HotkeyRecorderView(action: action, refreshToken: refreshToken)
                            .frame(width: 170, height: 24)
                    }
                }
            } footer: {
                Text("Click a shortcut, then press a key combination with ⌘, ⌃, or ⌥. Press Delete to clear, ⎋ to cancel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Restore Defaults") {
                    for action in HotkeyAction.allCases {
                        HotkeyManager.shared.setCombo(action.defaultCombo, for: action)
                    }
                    refreshToken = UUID()
                }
            }
        }
        .formStyle(.grouped)
    }
}
