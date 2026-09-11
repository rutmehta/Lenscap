import AppKit
import ImageIO
import XCTest
@testable import Lenscap

final class CloudCaptureEncodingTests: XCTestCase {
    func testCloudPNGPreservesRetinaPixelsByDefault() throws {
        let data = try XCTUnwrap(CloudCaptureEncoding.screenshot(
            try fixture(), format: "png", jpegQuality: 0.9, scale: 2, downscale: false))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 20)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
    }

    func testCloudUsesTheSameJPEGAndRetinaSettingsAsSavedFiles() throws {
        let data = try XCTUnwrap(CloudCaptureEncoding.screenshot(
            try fixture(), format: "jpg", jpegQuality: 0.8, scale: 2, downscale: true))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 20)
        XCTAssertEqual(image.height, 10)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
    }

    func testFinalizedFileKindsHaveCorrectUploadContentTypes() {
        XCTAssertEqual(CloudCaptureEncoding.contentType(kind: .video, filename: "capture.mp4"), "video/mp4")
        XCTAssertEqual(CloudCaptureEncoding.contentType(kind: .gif, filename: "capture.gif"), "image/gif")
        XCTAssertEqual(CloudCaptureEncoding.contentType(kind: .screenshot, filename: "capture.JPEG"), "image/jpeg")
        XCTAssertEqual(CloudCaptureEncoding.contentType(kind: .screenshot, filename: "capture.png"), "image/png")
    }

    private func fixture() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        return try XCTUnwrap(context.makeImage())
    }
}
