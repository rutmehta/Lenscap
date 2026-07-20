import SwiftUI

/// About tab: version, project link, and license notes.
struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
            Text("Lenscap")
                .font(.title.bold())
            Text("Version 1.0.0")
                .foregroundStyle(.secondary)
            Text("A local-first screenshot and screen recording tool for macOS. Everything stays on your Mac.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 4)
            Link("github.com/rutmehta/Lenscap",
                 destination: URL(string: "https://github.com/rutmehta/Lenscap")!)
                .padding(.top, 4)
            VStack(spacing: 4) {
                Text("Released under the MIT License.")
                Text("Not affiliated with MakeTheWeb / CleanShot.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
