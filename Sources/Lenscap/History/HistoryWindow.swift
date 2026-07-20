import AppKit

/// Capture history browser. Skeleton — reveals the save folder in Finder;
/// the thumbnail grid window lives in a follow-up pass.
@MainActor
final class HistoryWindowController {
    static func open() {
        NSWorkspace.shared.activateFileViewerSelecting([SettingsStore.shared.saveDirectory])
    }
}
