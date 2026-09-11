import AppKit
import LenscapCloudCore
import SwiftUI

@MainActor
final class CloudLibraryWindowController {
    private static var window: NSWindow?

    static func open() {
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
            created.contentViewController = NSHostingController(rootView: CloudLibraryView())
            created.title = "Lenscap Cloud"
            created.identifier = NSUserInterfaceItemIdentifier("LenscapCloud")
            created.contentMinSize = NSSize(width: 700, height: 480)
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum CloudPresentation {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func symbol(_ kind: CloudCaptureKind) -> String {
        switch kind {
        case .screenshot: return "photo"
        case .video: return "video"
        case .gif: return "photo.stack"
        }
    }
}

private struct CloudLibraryView: View {
    @ObservedObject private var cloud = CloudController.shared
    @State private var selection: UUID?
    @State private var query = ""
    @State private var confirmDelete = false

    private var selected: CloudCapture? { cloud.captures.first { $0.id == selection } }
    private var filtered: [CloudCapture] {
        query.isEmpty ? cloud.captures : cloud.captures.filter { $0.filename.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cloud Library").font(.title2.weight(.semibold))
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if cloud.isRefreshing || cloud.isUploading {
                    ProgressView().controlSize(.small)
                }
                Menu("New Capture") {
                    Button("Screenshot…") { AppCoordinator.shared.captureArea() }
                    Button("Window…") { AppCoordinator.shared.captureWindow() }
                    Button("Fullscreen") { AppCoordinator.shared.captureFullscreen() }
                    Divider()
                    Button("Record Video…") { AppCoordinator.shared.toggleRecording(mode: .video) }
                    Button("Record GIF…") { AppCoordinator.shared.toggleRecording(mode: .gif) }
                }
                .fixedSize()
                .accessibilityIdentifier("LenscapCloudNewCapture")
                Button("Refresh") { Task { await cloud.refresh() } }
                    .disabled(!cloud.isConfigured || cloud.isRefreshing)
            }
            .padding(22)

            if let error = cloud.connectionError ?? cloud.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22).padding(.bottom, 14)
            }

            if !cloud.isConfigured {
                ContentUnavailableView("Cloud is not connected", systemImage: "icloud",
                                       description: Text("Import your personal connection in Settings → Cloud."))
            } else if cloud.captures.isEmpty && !cloud.isRefreshing {
                ContentUnavailableView("No uploads yet", systemImage: "icloud.and.arrow.up",
                                       description: Text("New screenshots, videos, and GIFs will appear here automatically."))
            } else {
                TextField("Search loaded captures", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 22).padding(.bottom, 14)
                Divider()
                List(selection: $selection) {
                    ForEach(filtered, id: \.id) { capture in
                        HStack(spacing: 12) {
                            Image(systemName: CloudPresentation.symbol(capture.kind))
                                .font(.title3).foregroundStyle(.secondary).frame(width: 28)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(capture.filename).lineLimit(1).truncationMode(.middle)
                                Text(capture.createdAt, format: .dateTime.year().month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            Text(CloudPresentation.bytes(capture.byteCount))
                                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .tag(capture.id)
                    }
                }
                .listStyle(.inset)
                if cloud.nextCursor != nil {
                    Button("Load more") { Task { await cloud.loadMore() } }
                        .disabled(cloud.isRefreshing).padding(10)
                }
            }

            if cloud.pendingCount > 0 {
                HStack {
                    Text("\(cloud.pendingCount) waiting to upload · \(CloudPresentation.bytes(cloud.queuedBytes)) kept on this Mac")
                        .font(.callout)
                    Spacer()
                    Button("Retry") { Task { await cloud.retryUploads() } }
                        .disabled(cloud.isUploading)
                }
                .padding(.horizontal, 22).padding(.vertical, 12)
            }

            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button("Open") { if let selected { Task { await cloud.open(selected) } } }
                    Button("Copy Share Link") { if let selected { Task { await cloud.copyShareLink(selected) } } }
                    Spacer()
                    Button("Delete from Cloud…", role: .destructive) { confirmDelete = true }
                }
                .disabled(selected == nil)
                Text("Files are private. A share link lets anyone with the link view that file for 7 days. Local files are never deleted here.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .frame(minWidth: 700, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { if cloud.isConfigured { await cloud.refresh() } }
        .alert("Delete this cloud copy?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let selected { Task { await cloud.delete(selected) } }
            }
        } message: {
            Text("The local file stays on your Mac. Existing downloaded copies cannot be recalled.")
        }
    }

    private var summary: String {
        guard cloud.isConfigured else { return "Your personal capture library" }
        if let usage = cloud.usage {
            return "\(usage.captureCount) captures · \(CloudPresentation.bytes(usage.storageBytes)) in Lenscap"
        }
        return cloud.isUploading ? "Uploading new captures…" : "New captures upload automatically"
    }
}
