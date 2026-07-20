import AppKit

struct CaptureItem: Identifiable {
    enum Kind: String, Codable {
        case screenshot
        case video
        case gif
    }

    let id = UUID()
    let kind: Kind
    let image: NSImage
    var fileURL: URL?
    let date = Date()
}
