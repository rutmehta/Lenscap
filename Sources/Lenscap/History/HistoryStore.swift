import AppKit

struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let path: String
    let kind: CaptureItem.Kind
    let date: Date

    var url: URL { URL(fileURLWithPath: path) }
    var fileExists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Persistent index of past captures (the files themselves live in the save directory).
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    private static let maxEntries = 300

    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lenscap", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        fileURL = appSupport.appendingPathComponent("history.json")
        load()
    }

    func add(url: URL, kind: CaptureItem.Kind) {
        let entry = HistoryEntry(id: UUID(), path: url.path, kind: kind, date: Date())
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
    }

    func remove(_ entry: HistoryEntry, deleteFile: Bool) {
        if deleteFile {
            try? FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
        }
        entries.removeAll { $0.id == entry.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL)
    }
}
