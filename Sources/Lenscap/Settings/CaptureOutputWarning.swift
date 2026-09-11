import SwiftUI

/// Visible beside either control that can disable the last screenshot output.
struct CaptureOutputWarning: View {
    var body: some View {
        Label {
            Text("Screenshots will be discarded. Turn on saving, clipboard copying, or the capture preview.")
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        .font(.callout)
    }
}
