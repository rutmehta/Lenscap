import SwiftUI

/// About tab: version, project link, and license notes.
struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .padding(.bottom, 12)
            Text("Lenscap")
                .font(.system(.title, design: .rounded).bold())
            Text("Version 1.0.0")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text("A local-first screenshot and screen recording tool for macOS. Everything stays on your Mac.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
                .padding(.top, 12)
            Link("github.com/rutmehta/Lenscap",
                 destination: URL(string: "https://github.com/rutmehta/Lenscap")!)
                .font(.callout)
                .padding(.top, 8)
            VStack(spacing: 2) {
                Text("Released under the MIT License.")
                Text("Not affiliated with MakeTheWeb / CleanShot.")
            }
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
