import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CloudSettingsView: View {
    @ObservedObject private var cloud = CloudController.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Personal cloud", value: cloud.isConfigured ? "Connected to Neon" : "Not connected")
                if cloud.isConfigured {
                    LabeledContent("Automatic uploads", value: "All new captures")
                    Button("Open Cloud Library…") { CloudLibraryWindowController.open() }
                } else {
                    Button("Import Connection…") { importConnection() }
                }
                if let error = cloud.connectionError {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text(cloud.isConfigured
                     ? "New screenshots, videos, and GIFs upload automatically. Local save and clipboard settings are unchanged. Existing captures are not uploaded; saved edits create separate cloud versions."
                     : "Connect this Mac to your private Lenscap backend. The device credential is stored in your Mac’s login Keychain.")
            }

            if cloud.isConfigured {
                Section {
                    LabeledContent("Status", value: cloud.isUploading ? "Uploading…" : cloud.pendingCount > 0 ? "Waiting to upload" : "Up to date")
                    LabeledContent("Waiting on this Mac", value: "\(cloud.pendingCount) files · \(CloudPresentation.bytes(cloud.queuedBytes))")
                    if let error = cloud.lastError {
                        Label {
                            Text(error).font(.callout).textSelection(.enabled)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                    HStack {
                        Button("Retry Uploads") { Task { await cloud.retryUploads() } }
                            .disabled(cloud.pendingCount == 0 || cloud.isUploading)
                        Spacer()
                        Button("Refresh Usage") { Task { await cloud.refresh() } }
                            .disabled(cloud.isRefreshing)
                    }
                } header: {
                    Text("Upload activity")
                } footer: {
                    Text("Uploads resume after a connection failure or restart. Queued files stay on this Mac until the server confirms receipt. Files over 5 GiB stay local.")
                }

                Section {
                    if let usage = cloud.usage {
                        LabeledContent("Lenscap files", value: "\(usage.captureCount) · \(CloudPresentation.bytes(usage.storageBytes))")
                        LabeledContent("Database", value: "\(CloudPresentation.bytes(usage.databaseBytes)) of \(CloudPresentation.bytes(usage.limits.databaseBytes))")
                    } else {
                        Text(cloud.isRefreshing ? "Reading usage…" : "Refresh to read current usage.")
                            .foregroundStyle(.secondary)
                    }
                    Link("Open Neon Dashboard", destination: URL(string: "https://console.neon.tech")!)
                } header: {
                    Text("Free plan usage")
                } footer: {
                    Text("Neon includes 5 GB of file storage shared across your account. The total above only measures Lenscap, not your other projects. Storage and Functions are in beta. Lenscap will not upgrade your plan automatically.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task { if cloud.isConfigured { await cloud.refresh() } }
    }

    private func importConnection() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the private cloud connection file created during backend setup. It is removed after a verified Keychain import."
        if panel.runModal() == .OK, let url = panel.url {
            _ = cloud.importConnection(at: url)
        }
    }
}
