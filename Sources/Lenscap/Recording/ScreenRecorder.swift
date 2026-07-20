import AppKit

enum RecordingMode {
    case video
    case gif
}

/// Screen recording to MP4 / GIF. Skeleton — the full SCStream + AVAssetWriter
/// implementation lives in a follow-up pass.
@MainActor
final class ScreenRecorder: NSObject {
    static let shared = ScreenRecorder()

    private(set) var isRecording = false

    func start(selection: SelectionResult?, mode: RecordingMode) async {
        HUD.show("Recording is not implemented yet", symbol: "record.circle")
    }

    func stopAndSave() async {}
}
