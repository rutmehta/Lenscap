import AppKit
import SwiftUI

/// About tab: version, project link, and license notes.
struct AboutSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 18) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Lenscap")
                        .font(.title.weight(.semibold))
                    Text("Version \(AppVersion.displayString())")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Text("Capture, annotate, and record your screen. Save locally, or connect your personal cloud to upload new captures automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Software updates")
                        .font(.headline)
                    Text("Check for the latest version of Lenscap.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Check for Updates…") {
                    UpdaterController.shared.checkForUpdates(nil)
                }
                .fixedSize()
            }

            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 8) {
                Link("Lenscap on GitHub",
                     destination: URL(string: "https://github.com/rutmehta/Lenscap")!)
                Text("Released under the MIT License.")
                Text("Not affiliated with MakeTheWeb / CleanShot.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
