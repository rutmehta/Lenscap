import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Capture history browser: a thumbnail grid over HistoryStore. One reusable window.
@MainActor
final class HistoryWindowController {
    private static var window: NSWindow?

    static func open() {
        if window == nil {
            let host = NSHostingController(rootView: HistoryView())
            let newWindow = NSWindow(contentViewController: host)
            newWindow.title = "History"
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.setContentSize(NSSize(width: 740, height: 520))
            newWindow.minSize = NSSize(width: 480, height: 320)
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Thumbnail cache

/// Async thumbnail loader backed by a small NSCache. QuickLook handles images and videos alike.
@MainActor
final class HistoryThumbnailCache {
    static let shared = HistoryThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 300
    }

    func thumbnail(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: CGSize(width: 220, height: 160),
                                                   scale: 2,
                                                   representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = representation.nsImage
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

// MARK: - Views

private enum HistoryFilter: String, CaseIterable {
    case all = "All"
    case screenshots = "Screenshots"
    case recordings = "Recordings"

    func matches(_ entry: HistoryEntry) -> Bool {
        switch self {
        case .all: return true
        case .screenshots: return entry.kind == .screenshot
        case .recordings: return entry.kind == .video || entry.kind == .gif
        }
    }
}

private struct HistoryView: View {
    @ObservedObject private var store = HistoryStore.shared
    @State private var filter: HistoryFilter = .all

    private var filteredEntries: [HistoryEntry] {
        store.entries.filter { filter.matches($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Filter", selection: $filter) {
                    ForEach(HistoryFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Spacer()
                Button("Open Save Folder") {
                    NSWorkspace.shared.open(SettingsStore.shared.saveDirectory)
                }
                Button("Clear History") {
                    store.clearAll()
                }
                .disabled(store.entries.isEmpty)
            }
            .padding(12)

            Divider()

            if filteredEntries.isEmpty {
                ContentUnavailableView("No Captures",
                                       systemImage: "photo.on.rectangle.angled",
                                       description: Text("Screenshots and recordings you take will show up here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
                        ForEach(filteredEntries) { entry in
                            HistoryCellView(entry: entry)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }
}

private struct HistoryCellView: View {
    let entry: HistoryEntry
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.5))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(4)
                } else {
                    Image(systemName: entry.kind == .screenshot ? "photo" : "film")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                }
                if entry.kind != .screenshot {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "film.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            Spacer()
                        }
                    }
                    .padding(6)
                }
                if !entry.fileExists {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.yellow)
                                .padding(4)
                                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                                .help("File is missing")
                        }
                        Spacer()
                    }
                    .padding(6)
                }
            }
            .frame(height: 110)
            .opacity(entry.fileExists ? 1 : 0.5)

            Text(entry.url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(entry.date, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open() }
        .contextMenu { contextMenuItems }
        .task(id: entry.id) {
            guard entry.fileExists else { return }
            thumbnail = await HistoryThumbnailCache.shared.thumbnail(for: entry.url)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Open") { open() }
        if entry.kind == .screenshot, entry.fileExists {
            Button("Annotate") { annotate() }
        }
        Button("Copy") { copy() }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
        Divider()
        Button("Delete", role: .destructive) {
            HistoryStore.shared.remove(entry, deleteFile: true)
        }
    }

    private func open() {
        guard entry.fileExists else { return }
        NSWorkspace.shared.open(entry.url)
    }

    private func annotate() {
        guard let image = NSImage(contentsOf: entry.url) else { return }
        AppCoordinator.shared.openEditor(image: image, sourceURL: entry.url)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if entry.kind == .screenshot, let image = NSImage(contentsOf: entry.url) {
            pasteboard.writeObjects([image, entry.url as NSURL])
        } else {
            pasteboard.writeObjects([entry.url as NSURL])
        }
    }
}
