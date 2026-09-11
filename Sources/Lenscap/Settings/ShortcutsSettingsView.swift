import SwiftUI

/// Shortcuts tab: one recorder row per hotkey action.
struct ShortcutsSettingsView: View {
    @State private var refreshToken = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                Section {
                    ForEach(HotkeyAction.allCases, id: \.rawValue) { action in
                        LabeledContent(action.title) {
                            HotkeyRecorderView(action: action, refreshToken: refreshToken)
                                .frame(width: 150, height: 26)
                        }
                        .accessibilityElement(children: .contain)
                    }
                } footer: {
                    Text("Click a shortcut and press a combination with ⌘, ⌃, or ⌥. Delete clears it; Esc cancels.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack(alignment: .bottom, spacing: 24) {
                Text("macOS also uses ⇧⌘3, ⇧⌘4, and ⇧⌘5. If both apps respond, change the macOS shortcuts in System Settings → Keyboard → Keyboard Shortcuts → Screenshots.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Restore Defaults") {
                    for action in HotkeyAction.allCases {
                        HotkeyManager.shared.setCombo(action.defaultCombo, for: action)
                    }
                    refreshToken = UUID()
                }
                .fixedSize()
            }
        }
    }
}
