import AppKit
import CoreImage
import XCTest

@testable import MemoryClip

final class QRServiceTests: XCTestCase {
    /// Decodes a generated QR image back to its payload, so the tests assert
    /// what was actually encoded rather than merely that *some* image came out.
    private func decodedPayload(
        of image: NSImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        var rect = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(
            image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
            "the QR NSImage has no bitmap representation",
            file: file,
            line: line
        )
        let detector = try XCTUnwrap(
            CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: nil,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
            ),
            "CIDetector(ofType: CIDetectorTypeQRCode) is unavailable",
            file: file,
            line: line
        )
        let features = detector
            .features(in: CIImage(cgImage: cgImage))
            .compactMap { $0 as? CIQRCodeFeature }
        let feature = try XCTUnwrap(
            features.first,
            "no QR symbol could be read back out of the generated image",
            file: file,
            line: line
        )
        return try XCTUnwrap(
            feature.messageString,
            "the decoded QR symbol carried no message string",
            file: file,
            line: line
        )
    }

    // MARK: - Payload round-trips

    func testImageForLinkStringEncodesThatLink() throws {
        let link = "https://example.com"
        let image = try XCTUnwrap(QRService.image(for: link), "no image for a plain link")

        XCTAssertEqual(try decodedPayload(of: image), link, "QR payload is not the input string")
        XCTAssertEqual(image.size.width, 240, accuracy: 1, "default width should be 240pt")
        XCTAssertEqual(image.size.height, 240, accuracy: 1, "default height should be 240pt")
    }

    /// A long URL with query parameters needs more QR modules than a short one,
    /// so this catches an implementation that encodes something fixed-length
    /// (a UUID, a hash) instead of the text itself.
    func testLongURLRoundTrips() throws {
        let link = "https://example.com/some/deep/path/page.html"
            + "?utm_source=memoryclip&utm_medium=clipboard&utm_campaign=qr-code-generation"
            + "&q=a%20fairly%20long%20query%20string&ref=regression-test"
        let image = try XCTUnwrap(QRService.image(for: link), "no image for a long URL")

        XCTAssertEqual(try decodedPayload(of: image), link, "long URL did not round-trip")
    }

    func testNonASCIITextRoundTrips() throws {
        let text = "café — naïve ✅ 日本語"
        let image = try XCTUnwrap(QRService.image(for: text), "no image for non-ASCII text")

        XCTAssertEqual(
            try decodedPayload(of: image),
            text,
            "UTF-8 payload did not round-trip (byte-mode encoding regression?)"
        )
    }

    func testCustomSizeStillEncodesThePayload() throws {
        let image = try XCTUnwrap(QRService.image(for: "hi", size: 120), "no image at size 120")

        XCTAssertEqual(try decodedPayload(of: image), "hi", "custom-size QR lost its payload")
        XCTAssertEqual(image.size.width, 120, accuracy: 1, "requested width was not honoured")
        XCTAssertEqual(image.size.height, 120, accuracy: 1, "requested height was not honoured")
    }

    // MARK: - Boundaries

    func testEmptyStringReturnsNil() {
        XCTAssertNil(QRService.image(for: ""), "an empty clip must not produce a QR image")
    }

    /// Documents what happens past QR capacity: byte mode at correction level M
    /// tops out around 2,300 bytes, and `CIQRCodeGenerator` returns no output
    /// image beyond that — so `QRService` yields nil rather than a truncated or
    /// corrupt symbol. A huge clip is a realistic input for a clipboard manager.
    func testPayloadBeyondQRCapacityReturnsNilRatherThanTruncating() {
        let oversized = String(repeating: "A", count: 8_000)

        XCTAssertNil(
            QRService.image(for: oversized),
            "an over-capacity payload must fail cleanly, never encode a truncated string"
        )
    }

    /// The largest payload that still fits must survive intact — the boundary
    /// on the other side of the capacity limit.
    func testLargePayloadWithinCapacityRoundTrips() throws {
        let text = String(repeating: "clip", count: 200) // 600 bytes, comfortably in range
        let image = try XCTUnwrap(QRService.image(for: text), "no image for a 600-byte payload")

        XCTAssertEqual(try decodedPayload(of: image), text, "600-byte payload did not round-trip")
    }
}
