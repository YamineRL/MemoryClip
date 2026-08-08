import AppKit
import XCTest

@testable import MemoryClip

final class OCRServiceTests: XCTestCase {
    /// End-to-end: a captured image clip gets its text filled in by the
    /// coordinator, and is not queued for OCR a second time.
    @MainActor
    func testCoordinatorFillsInOCRTextForCapturedImage() async throws {
        UserDefaults.standard.set(1000, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(0, forKey: SettingsKeys.retentionDays)
        UserDefaults.standard.set(true, forKey: OCRCoordinator.enabledKey)

        let png = try makePNG(text: "RECEIPT 4242")
        let store = try ClipStore(inMemory: true)
        store.insert(
            CapturedClip(
                kind: .image,
                text: nil,
                richTextData: nil,
                imageData: png,
                fileURLStrings: [],
                colorHex: nil,
                hash: ContentParser.hashText("image:receipt")
            ),
            sourceBundleID: nil,
            sourceAppName: nil
        )

        let coordinator = OCRCoordinator(store: store)
        coordinator.processPending()

        // The coordinator runs detached; poll until the clip is marked done.
        var attempts = 0
        while !store.pendingOCR().isEmpty, attempts < 100 {
            try await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }
        coordinator.stop()

        let item = try XCTUnwrap(store.recent(limit: 1).first)
        XCTAssertTrue(item.ocrAttempted)
        let text = try XCTUnwrap(item.ocrText, "Expected extracted text on the image clip")
        XCTAssertTrue(
            text.uppercased().contains("RECEIPT"),
            "Expected RECEIPT in extracted text, got: \(text)"
        )
    }

    @MainActor
    func testCoordinatorSkipsWorkWhenOCRDisabled() async throws {
        UserDefaults.standard.set(false, forKey: OCRCoordinator.enabledKey)
        defer { UserDefaults.standard.set(true, forKey: OCRCoordinator.enabledKey) }

        let store = try ClipStore(inMemory: true)
        store.insert(
            CapturedClip(
                kind: .image,
                text: nil,
                richTextData: nil,
                imageData: Data("nope".utf8),
                fileURLStrings: [],
                colorHex: nil,
                hash: ContentParser.hashText("image:disabled")
            ),
            sourceBundleID: nil,
            sourceAppName: nil
        )

        OCRCoordinator(store: store).processPending()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(store.pendingOCR().count, 1, "Disabled OCR must leave clips untouched")
    }

    /// Turning OCR ON must drain the backlog that piled up while it was off,
    /// rather than waiting for the next capture or an app restart.
    @MainActor
    func testTogglingOCROnDrainsTheExistingBacklog() async throws {
        UserDefaults.standard.set(1000, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(0, forKey: SettingsKeys.retentionDays)
        UserDefaults.standard.set(false, forKey: OCRCoordinator.enabledKey)
        defer { UserDefaults.standard.set(true, forKey: OCRCoordinator.enabledKey) }

        let store = try ClipStore(inMemory: true)
        let coordinator = OCRCoordinator(store: store)

        let png = try makePNG(text: "BACKLOG")
        store.insert(
            CapturedClip(
                kind: .image,
                text: nil,
                richTextData: nil,
                imageData: png,
                fileURLStrings: [],
                colorHex: nil,
                hash: ContentParser.hashText("image:backlog")
            ),
            sourceBundleID: nil,
            sourceAppName: nil
        )
        coordinator.processPending()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.pendingOCR().count, 1, "Disabled OCR must leave the backlog alone")

        // Flip the setting: the coordinator watches UserDefaults and starts.
        UserDefaults.standard.set(true, forKey: OCRCoordinator.enabledKey)

        var attempts = 0
        while !store.pendingOCR().isEmpty, attempts < 100 {
            try await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }
        coordinator.stop()

        XCTAssertTrue(store.pendingOCR().isEmpty, "Enabling OCR should drain the backlog")
        let item = try XCTUnwrap(store.recent(limit: 1).first)
        XCTAssertTrue(item.ocrAttempted)
    }

    /// After `stop()`, a fresh `processPending()` must still be able to run —
    /// the stopped run's completion handler must not clear the new run's
    /// handle (which used to let two drains OCR the same batch twice).
    @MainActor
    func testProcessPendingWorksAgainAfterStop() async throws {
        UserDefaults.standard.set(1000, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(true, forKey: OCRCoordinator.enabledKey)

        let store = try ClipStore(inMemory: true)
        let coordinator = OCRCoordinator(store: store)
        coordinator.processPending()
        coordinator.stop()

        store.insert(
            CapturedClip(
                kind: .image,
                text: nil,
                richTextData: nil,
                imageData: try makePNG(text: "AFTER STOP"),
                fileURLStrings: [],
                colorHex: nil,
                hash: ContentParser.hashText("image:after-stop")
            ),
            sourceBundleID: nil,
            sourceAppName: nil
        )

        coordinator.processPending()
        var attempts = 0
        while !store.pendingOCR().isEmpty, attempts < 100 {
            try await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }
        coordinator.stop()

        XCTAssertTrue(store.pendingOCR().isEmpty)
    }

    // MARK: Concurrent batch recognition

    /// The drain hands a batch to a bounded TaskGroup. Every image must come
    /// back exactly once, matched to its own uuid, however the tasks
    /// interleave.
    func testRecognizeAllReturnsOneResultPerImageKeyedByUUID() async throws {
        let words = ["ALPHA", "BRAVO", "CHARLIE", "DELTA", "ECHO"]
        var pending: [(uuid: UUID, data: Data)] = []
        var expected: [UUID: String] = [:]
        for word in words {
            let uuid = UUID()
            pending.append((uuid, try makePNG(text: word)))
            expected[uuid] = word
        }

        let results = await OCRCoordinator.recognizeAll(pending, concurrency: 3)

        XCTAssertEqual(results.count, pending.count)
        XCTAssertEqual(Set(results.map(\.uuid)), Set(pending.map(\.uuid)))
        for result in results {
            let word = try XCTUnwrap(expected[result.uuid])
            let text = try XCTUnwrap(result.text, "no text for \(word)")
            XCTAssertTrue(
                text.uppercased().contains(word),
                "result for \(word) carried the wrong image's text: \(text)"
            )
        }
    }

    /// Switching OCR off must stop work mid-batch, and the skipped images must
    /// be OMITTED rather than reported as "no text" — reporting them would
    /// mark them attempted and they would never be OCR'd again.
    func testRecognizeAllSkipsEverythingWhileDisabled() async throws {
        await MainActor.run { UserDefaults.standard.set(false, forKey: OCRCoordinator.enabledKey) }
        defer { UserDefaults.standard.set(true, forKey: OCRCoordinator.enabledKey) }

        let pending: [(uuid: UUID, data: Data)] = [
            (UUID(), try makePNG(text: "ONE")),
            (UUID(), try makePNG(text: "TWO")),
        ]

        let results = await OCRCoordinator.recognizeAll(pending, concurrency: 3)

        XCTAssertTrue(results.isEmpty, "disabled OCR must attempt nothing")
    }

    func testRecognizeAllHandlesAnEmptyBatch() async {
        let results = await OCRCoordinator.recognizeAll([], concurrency: 3)
        XCTAssertTrue(results.isEmpty)
    }

    /// Concurrency wider than the batch must not deadlock or drop work.
    func testRecognizeAllWithConcurrencyWiderThanTheBatch() async throws {
        UserDefaults.standard.set(true, forKey: OCRCoordinator.enabledKey)
        let pending: [(uuid: UUID, data: Data)] = [(UUID(), try makePNG(text: "SOLO"))]

        let results = await OCRCoordinator.recognizeAll(pending, concurrency: 8)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.uuid, pending[0].uuid)
    }

    /// Render text into a PNG the way a screenshot would look to Vision.
    private func makePNG(text: String, size: NSSize = NSSize(width: 600, height: 200)) throws -> Data {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        (text as NSString).draw(at: NSPoint(x: 30, y: 60), withAttributes: attributes)
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw XCTSkip("Could not render a test image on this machine")
        }
        return png
    }

    func testEmptyDataYieldsNoText() async {
        let result = await OCRService.recognizeText(in: Data())
        XCTAssertNil(result)
    }

    func testNonImageDataYieldsNoText() async {
        let result = await OCRService.recognizeText(in: Data("not an image".utf8))
        XCTAssertNil(result)
    }

    func testBlankImageYieldsNoText() async throws {
        let png = try makePNG(text: "")
        let result = await OCRService.recognizeText(in: png)
        XCTAssertNil(result)
    }

    func testRecognizesRenderedText() async throws {
        let png = try makePNG(text: "HELLO MemoryClip")
        let result = await OCRService.recognizeText(in: png)
        let recognized = try XCTUnwrap(result, "Vision found no text in the rendered image")
        XCTAssertTrue(
            recognized.uppercased().contains("HELLO"),
            "Expected recognized text to contain HELLO, got: \(recognized)"
        )
    }

    func testMultipleLinesAreJoinedInReadingOrder() async throws {
        let size = NSSize(width: 700, height: 320)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 56, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        ("FIRST LINE" as NSString).draw(at: NSPoint(x: 30, y: 200), withAttributes: attributes)
        ("SECOND LINE" as NSString).draw(at: NSPoint(x: 30, y: 60), withAttributes: attributes)
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw XCTSkip("Could not render a test image on this machine")
        }

        let result = await OCRService.recognizeText(in: png)
        let recognized = try XCTUnwrap(result)
        let upper = recognized.uppercased()
        let firstIndex = try XCTUnwrap(upper.range(of: "FIRST")?.lowerBound)
        let secondIndex = try XCTUnwrap(upper.range(of: "SECOND")?.lowerBound)
        XCTAssertLessThan(firstIndex, secondIndex, "Lines should keep top-to-bottom order")
        XCTAssertTrue(recognized.contains("\n"), "Separate lines should be newline-joined")
    }
}
