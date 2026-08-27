import AppKit
import XCTest
@testable import Lenscap

final class ImageWriterTests: XCTestCase {
    func testSavedCaptureCopiesImageAndFileURLAsOneItem() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = try makeImage()
        let fileURL = URL(fileURLWithPath: "/tmp/Lenscap capture #1.png")

        XCTAssertTrue(ImageWriter.copyToClipboard(cgImage: image, fileURL: fileURL,
                                                  pasteboard: pasteboard))

        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 1, "One capture must not paste as two attachments")
        let item = try XCTUnwrap(items.first)
        try assertImage(in: item)
        XCTAssertEqual(item.string(forType: .fileURL), fileURL.absoluteString)
        XCTAssertNotNil(NSImage(pasteboard: pasteboard))
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                         options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(urls, [fileURL])
    }

    func testClipboardOnlyCaptureCopiesOneImageWithoutFileURL() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = try makeImage()

        XCTAssertTrue(ImageWriter.copyToClipboard(cgImage: image, fileURL: nil,
                                                  pasteboard: pasteboard))

        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        try assertImage(in: item)
        XCTAssertFalse(item.types.contains(.fileURL))
        XCTAssertNotNil(NSImage(pasteboard: pasteboard))
    }

    func testNewCopyReplacesPreviousContentsAndDoesNotKeepOldFileURL() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects(["Previous clipboard text" as NSString]))
        let image = try makeImage()
        let fileURL = URL(fileURLWithPath: "/tmp/Previous capture.png")

        XCTAssertTrue(ImageWriter.copyToClipboard(cgImage: image, fileURL: fileURL,
                                                  pasteboard: pasteboard))
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertTrue(ImageWriter.copyToClipboard(cgImage: image, fileURL: nil,
                                                  pasteboard: pasteboard))

        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 1)
        try assertImage(in: XCTUnwrap(items.first))
        XCTAssertNil(pasteboard.string(forType: .fileURL))
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    private func makeImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 3,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
        return try XCTUnwrap(context.makeImage())
    }

    private func assertImage(in item: NSPasteboardItem,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try XCTUnwrap(item.data(forType: .png), file: file, line: line)
        let image = try XCTUnwrap(NSBitmapImageRep(data: data), file: file, line: line)
        XCTAssertEqual(image.pixelsWide, 2, file: file, line: line)
        XCTAssertEqual(image.pixelsHigh, 3, file: file, line: line)
    }
}
