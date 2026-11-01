import AppKit
import ImageIO
import UniformTypeIdentifiers
import VisionKit
import XCTest
@testable import PersonalAlbum

@MainActor
final class ImageTextPreviewTests: XCTestCase {
    private func fixture(text: String = "", orientation: Int = 1) throws -> URL {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 300,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 300).fill()
        (text as NSString).draw(at: NSPoint(x: 50, y: 120), withAttributes: [
            .font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black
        ])
        NSGraphicsContext.restoreGraphicsState()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCR-Test-\(UUID().uuidString).tiff")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.tiff.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.cgImage), [
            kCGImagePropertyOrientation: orientation
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testDecoderAppliesEXIFOrientation() throws {
        let url = try fixture(orientation: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try PreviewImageDecoder.decode(url: url)
        XCTAssertEqual(image.width, 300)
        XCTAssertEqual(image.height, 1200)
    }

    func testNativeOCRRecognizesTextAndClearsPreviousResult() async throws {
        guard ImageAnalyzer.isSupported else { throw XCTSkip("Live Text unavailable") }
        let textURL = try fixture(text: "HELLO OCR 12345")
        let blankURL = try fixture()
        defer {
            try? FileManager.default.removeItem(at: textURL)
            try? FileManager.default.removeItem(at: blankURL)
        }
        let model = ImageTextPreviewModel()
        await model.load(url: textURL)
        XCTAssertTrue(model.transcript.contains("HELLO OCR 12345"), model.message)
        XCTAssertFalse(model.isLoading)
        await model.load(url: blankURL)
        XCTAssertTrue(model.transcript.isEmpty)
        XCTAssertEqual(model.message, "未识别到文字。")
        XCTAssertFalse(model.canRetry)
    }

    func testMissingImageOffersRetry() async {
        let model = ImageTextPreviewModel()
        await model.load(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("Missing-OCR-\(UUID().uuidString).png"))
        XCTAssertNil(model.image)
        XCTAssertNil(model.analysis)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.canRetry)
        XCTAssertTrue(model.message.hasPrefix("无法读取图片："))
    }

    func testCancelledLoadDoesNotPublishImageOrAnalysis() async throws {
        let url = try fixture(text: "CANCELLED")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = ImageTextPreviewModel()
        let task = Task { await model.load(url: url) }
        task.cancel()
        await task.value
        XCTAssertNil(model.image)
        XCTAssertNil(model.analysis)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.canRetry)
    }
}
