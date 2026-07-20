import Foundation

/// UserDefaults-backed settings. SwiftUI views may bind to the same keys via @AppStorage;
/// the accessors here read the defaults directly so both stay in sync.
final class SettingsStore {
    static let shared = SettingsStore()
    private let defaults = UserDefaults.standard

    enum Keys {
        static let saveDirectory = "saveDirectory"
        static let fileFormat = "fileFormat" // "png" | "jpg"
        static let jpegQuality = "jpegQuality"
        static let filenamePrefix = "filenamePrefix"
        static let saveToDisk = "saveToDisk"
        static let copyToClipboard = "copyToClipboard"
        static let showQuickAccess = "showQuickAccess"
        static let quickAccessDuration = "quickAccessDuration"
        static let playSound = "playSound"
        static let captureDelay = "captureDelay" // seconds, 0 = off
        static let showCursorInScreenshots = "showCursorInScreenshots"
        static let showCursorInRecordings = "showCursorInRecordings"
        static let downscaleRetina = "downscaleRetina"
        static let videoFPS = "videoFPS"
        static let gifFPS = "gifFPS"
        static let recordSystemAudio = "recordSystemAudio"
    }

    private init() {}

    func registerDefaults() {
        defaults.register(defaults: [
            Keys.saveDirectory: SettingsStore.defaultSaveDirectory.path,
            Keys.fileFormat: "png",
            Keys.jpegQuality: 0.9,
            Keys.filenamePrefix: "Lenscap",
            Keys.saveToDisk: true,
            Keys.copyToClipboard: false,
            Keys.showQuickAccess: true,
            Keys.quickAccessDuration: 8.0,
            Keys.playSound: true,
            Keys.captureDelay: 0,
            Keys.showCursorInScreenshots: false,
            Keys.showCursorInRecordings: true,
            Keys.downscaleRetina: false,
            Keys.videoFPS: 60,
            Keys.gifFPS: 12,
            Keys.recordSystemAudio: true,
        ])
    }

    static var defaultSaveDirectory: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lenscap", isDirectory: true)
    }

    var saveDirectory: URL {
        get {
            let path = defaults.string(forKey: Keys.saveDirectory) ?? Self.defaultSaveDirectory.path
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: Keys.saveDirectory) }
    }

    var fileFormat: String {
        get { defaults.string(forKey: Keys.fileFormat) ?? "png" }
        set { defaults.set(newValue, forKey: Keys.fileFormat) }
    }

    var jpegQuality: Double {
        get { defaults.double(forKey: Keys.jpegQuality) }
        set { defaults.set(newValue, forKey: Keys.jpegQuality) }
    }

    var filenamePrefix: String {
        get { defaults.string(forKey: Keys.filenamePrefix) ?? "Lenscap" }
        set { defaults.set(newValue, forKey: Keys.filenamePrefix) }
    }

    var saveToDisk: Bool {
        get { defaults.bool(forKey: Keys.saveToDisk) }
        set { defaults.set(newValue, forKey: Keys.saveToDisk) }
    }

    var copyToClipboard: Bool {
        get { defaults.bool(forKey: Keys.copyToClipboard) }
        set { defaults.set(newValue, forKey: Keys.copyToClipboard) }
    }

    var showQuickAccess: Bool {
        get { defaults.bool(forKey: Keys.showQuickAccess) }
        set { defaults.set(newValue, forKey: Keys.showQuickAccess) }
    }

    var quickAccessDuration: Double {
        get { defaults.double(forKey: Keys.quickAccessDuration) }
        set { defaults.set(newValue, forKey: Keys.quickAccessDuration) }
    }

    var playSound: Bool {
        get { defaults.bool(forKey: Keys.playSound) }
        set { defaults.set(newValue, forKey: Keys.playSound) }
    }

    var captureDelay: Int {
        get { defaults.integer(forKey: Keys.captureDelay) }
        set { defaults.set(newValue, forKey: Keys.captureDelay) }
    }

    var showCursorInScreenshots: Bool {
        get { defaults.bool(forKey: Keys.showCursorInScreenshots) }
        set { defaults.set(newValue, forKey: Keys.showCursorInScreenshots) }
    }

    var showCursorInRecordings: Bool {
        get { defaults.bool(forKey: Keys.showCursorInRecordings) }
        set { defaults.set(newValue, forKey: Keys.showCursorInRecordings) }
    }

    var downscaleRetina: Bool {
        get { defaults.bool(forKey: Keys.downscaleRetina) }
        set { defaults.set(newValue, forKey: Keys.downscaleRetina) }
    }

    var videoFPS: Int {
        get { defaults.integer(forKey: Keys.videoFPS) }
        set { defaults.set(newValue, forKey: Keys.videoFPS) }
    }

    var gifFPS: Int {
        get { defaults.integer(forKey: Keys.gifFPS) }
        set { defaults.set(newValue, forKey: Keys.gifFPS) }
    }

    var recordSystemAudio: Bool {
        get { defaults.bool(forKey: Keys.recordSystemAudio) }
        set { defaults.set(newValue, forKey: Keys.recordSystemAudio) }
    }
}
