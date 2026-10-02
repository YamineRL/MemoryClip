import Foundation
import XCTest

@testable import MemoryClip

/// Reading an export back in: the round trip is lossless, a clip the history
/// already holds is recognised rather than duplicated, and a file that is not
/// a MemoryClip export changes nothing at all.
@MainActor
final class HistoryImportTests: XCTestCase {

    // Whole-second timestamps, because both export formats drop sub-second
    // precision — the same fixture `ExportServiceTests` pins.
    private let createdAt = Date(timeIntervalSince1970: 1_720_000_000)
    private let lastUsedAt = Date(timeIntervalSince1970: 1_720_003_600)

    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoryclip-import-test-\(UUID().uuidString).json")
    }

    /// A file holding exactly `text`, the way an import finds one on disk.
    private func write(_ text: String) throws -> URL {
        let url = tempURL()
        try Data(text.utf8).write(to: url)
        return url
    }

    /// One clip of every kind, each hashed the way `ContentParser` hashes it
    /// at capture — which is what an import has to reproduce from the file.
    private func makeHistory() -> [ClipItem] {
        let rtf = Data("rtf payload".utf8)
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        return [
            ClipItem(
                kind: .text,
                text: "hello world",
                contentHash: ContentParser.hashText("text:hello world"),
                sourceBundleID: "com.apple.Safari",
                sourceAppName: "Safari",
                createdAt: createdAt,
                lastUsedAt: lastUsedAt,
                isPinned: true
            ),
            ClipItem(
                kind: .link,
                text: "https://example.com/a",
                contentHash: ContentParser.hashText("link:https://example.com/a"),
                createdAt: createdAt.addingTimeInterval(-10)
            ),
            ClipItem(
                kind: .color,
                text: "#FF8800",
                colorHex: "#FF8800",
                contentHash: ContentParser.hashText("color:#FF8800"),
                createdAt: createdAt.addingTimeInterval(-20)
            ),
            ClipItem(
                kind: .file,
                fileURLStrings: ["file:///Users/me/a.txt", "file:///tmp/b.png"],
                contentHash: ContentParser.hashText(
                    "file:file:///Users/me/a.txt\nfile:///tmp/b.png"
                ),
                sourceAppName: "Finder",
                createdAt: createdAt.addingTimeInterval(-30)
            ),
            ClipItem(
                kind: .richText,
                text: "body text",
                richTextData: rtf,
                contentHash: ContentParser.hashData(rtf),
                createdAt: createdAt.addingTimeInterval(-40)
            ),
            ClipItem(
                kind: .image,
                imageData: image,
                contentHash: ContentParser.hashData(image),
                createdAt: createdAt.addingTimeInterval(-50)
            ),
        ]
    }

    private func makeStore(_ items: [ClipItem]) throws -> ClipStore {
        let store = try ClipStore(inMemory: true)
        for item in items {
            store.context.insert(item)
        }
        store.save()
        return store
    }

    // MARK: Round trip

    /// Export a history, import it into an empty store, and the second store
    /// exports byte-for-byte the same file — every field the format carries.
    func testExportImportRoundTripIsLossless() throws {
        let originals = makeHistory()
        let source = try makeStore(originals)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(
            try HistoryExportController.writeExport(to: url, asCSV: false, store: source),
            originals.count
        )

        let destination = try ClipStore(inMemory: true)
        let outcome = try HistoryExportController.readImport(from: url, store: destination)

        XCTAssertEqual(outcome, .init(inserted: originals.count, skipped: 0))
        let restored = destination.recent(limit: 100)
        XCTAssertEqual(restored.count, originals.count)
        XCTAssertEqual(
            try ExportService.json(from: ExportService.exports(from: restored)),
            try String(contentsOf: url, encoding: .utf8)
        )
    }

    /// The dates and the pin are the point of a migration: an import that
    /// restamped them would hand over a history in the wrong order.
    func testImportKeepsTimestampsAndPins() throws {
        let source = try makeStore(makeHistory())
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try HistoryExportController.writeExport(to: url, asCSV: false, store: source)

        let destination = try ClipStore(inMemory: true)
        _ = try HistoryExportController.readImport(from: url, store: destination)

        let newest = try XCTUnwrap(destination.recent(limit: 1).first)
        XCTAssertEqual(newest.createdAt, createdAt)
        XCTAssertEqual(newest.lastUsedAt, lastUsedAt)
        XCTAssertTrue(newest.isPinned)
        XCTAssertEqual(newest.sourceBundleID, "com.apple.Safari")
    }

    /// The hash is derived, not carried, so every kind has to come back with
    /// the identity it was captured under — the whole basis of the dedupe.
    func testImportedClipsKeepTheHashTheyWereCapturedWith() throws {
        let originals = makeHistory()
        let source = try makeStore(originals)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try HistoryExportController.writeExport(to: url, asCSV: false, store: source)

        let destination = try ClipStore(inMemory: true)
        _ = try HistoryExportController.readImport(from: url, store: destination)

        let restored = destination.recent(limit: 100)
        XCTAssertEqual(
            restored.map(\.contentHash).sorted(),
            originals.map(\.contentHash).sorted()
        )
    }

    // MARK: Deduplication

    func testImportingTheSameFileTwiceAddsItOnce() throws {
        let originals = makeHistory()
        let source = try makeStore(originals)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try HistoryExportController.writeExport(to: url, asCSV: false, store: source)

        let destination = try ClipStore(inMemory: true)
        let first = try HistoryExportController.readImport(from: url, store: destination)
        let second = try HistoryExportController.readImport(from: url, store: destination)

        XCTAssertEqual(first, .init(inserted: originals.count, skipped: 0))
        XCTAssertEqual(second, .init(inserted: 0, skipped: originals.count))
        XCTAssertEqual(destination.recent(limit: 100).count, originals.count)
    }

    /// A file holding the same clip twice is one clip.
    func testDuplicatesWithinOneFileAreCollapsed() throws {
        let clip = ExportService.export(from: makeHistory()[0])
        let url = try write(try ExportService.json(from: [clip, clip, clip]))
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try ClipStore(inMemory: true)
        let outcome = try HistoryExportController.readImport(from: url, store: store)

        XCTAssertEqual(outcome, .init(inserted: 1, skipped: 2))
        XCTAssertEqual(store.recent(limit: 10).count, 1)
    }

    /// A clip the history already holds is left exactly as it is — the pin
    /// especially, which the imported record does not carry.
    func testImportNeverOverwritesAStoredClip() throws {
        let stored = ClipItem(
            kind: .text,
            text: "hello world",
            contentHash: ContentParser.hashText("text:hello world"),
            sourceAppName: "Notes",
            createdAt: createdAt.addingTimeInterval(-9_000),
            isPinned: true
        )
        let store = try makeStore([stored])

        // The same content, exported unpinned, from another app, later.
        let incoming = ClipExport(
            kind: ClipKind.text.rawValue,
            text: "hello world",
            colorHex: nil,
            fileURLs: [],
            sourceAppBundleID: "com.apple.Safari",
            sourceAppName: "Safari",
            createdAt: createdAt,
            lastUsedAt: nil,
            isPinned: false,
            richTextBase64: nil,
            imageBase64: nil
        )
        let url = try write(try ExportService.json(from: [incoming]))
        defer { try? FileManager.default.removeItem(at: url) }

        let outcome = try HistoryExportController.readImport(from: url, store: store)

        XCTAssertEqual(outcome, .init(inserted: 0, skipped: 1))
        let kept = try XCTUnwrap(store.recent(limit: 10).first)
        XCTAssertTrue(kept.isPinned)
        XCTAssertEqual(kept.sourceAppName, "Notes")
        XCTAssertEqual(kept.createdAt, createdAt.addingTimeInterval(-9_000))
    }

    // MARK: Pinboards (PRD 06)

    /// The `{"pinboards":…,"clips":…}` document imports whole: the boards
    /// come back with their names, colours and strip positions, and each
    /// clip lands filed under the board its record named, in its manual
    /// order.
    func testBoardAwareImportRestoresBoardsAndFilings() throws {
        let text = """
        {
          "pinboards" : [
            { "name" : "Commands", "color" : "red", "order" : 1 },
            { "name" : "Addresses", "color" : "teal", "order" : 0 }
          ],
          "clips" : [
            { "kind" : "text", "text" : "work address", "fileURLs" : [],
              "createdAt" : "%@", "isPinned" : true,
              "pinboard" : "Addresses", "pinboardColor" : "teal", "pinboardOrder" : 1 },
            { "kind" : "text", "text" : "home address", "fileURLs" : [],
              "createdAt" : "%@", "isPinned" : true,
              "pinboard" : "Addresses", "pinboardColor" : "teal", "pinboardOrder" : 0 },
            { "kind" : "text", "text" : "loose pin", "fileURLs" : [],
              "createdAt" : "%@", "isPinned" : true }
          ]
        }
        """
        let json = String(format: text,
                          iso8601(createdAt), iso8601(createdAt), iso8601(createdAt))
        let url = try write(json)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try ClipStore(inMemory: true)

        let outcome = try HistoryExportController.readImport(from: url, store: store)

        XCTAssertEqual(outcome, .init(inserted: 3, skipped: 0))
        let boards = store.pinboards()
        XCTAssertEqual(
            boards.map(\.name),
            ["Commands", "Addresses"],
            "boards land on the strip in the order the file listed them"
        )
        let addresses = try XCTUnwrap(Pinboard.named("Addresses", in: store.context))
        XCTAssertEqual(addresses.colorName, "teal")
        XCTAssertEqual(
            addresses.orderedClips.compactMap(\.text),
            ["home address", "work address"],
            "the manual order the file carried is restored"
        )
        for clip in addresses.orderedClips {
            XCTAssertTrue(clip.isPinned, "a filed clip is pinned")
        }
        let loose = try XCTUnwrap(store.recent(limit: 10).first { $0.text == "loose pin" })
        XCTAssertTrue(loose.isPinned)
        XCTAssertNil(loose.pinboard, "a clip with no pinboard field stays board-less")
    }

    /// A clip that names a board the `pinboards` list never described still
    /// gets filed: the board is created on the spot, coloured from the
    /// clip's own `pinboardColor` hint.
    func testImportCreatesABoardAClipNamesButTheListOmits() throws {
        let clip = ExportService.export(from: ClipItem(
            kind: .text, text: "filed clip",
            contentHash: ContentParser.hashText("text:filed clip"),
            createdAt: createdAt, isPinned: true
        ))
        var record = clip
        record.pinboard = "Undeclared"
        record.pinboardColor = "purple"
        let json = "{\"pinboards\": [], \"clips\": ["
            + (try ExportService.json(from: [record])).trimmingCharacters(in: CharacterSet(charactersIn: "[]\n "))
            + "]}"
        let url = try write(json)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try ClipStore(inMemory: true)

        _ = try HistoryExportController.readImport(from: url, store: store)

        let board = try XCTUnwrap(Pinboard.named("Undeclared", in: store.context))
        XCTAssertEqual(board.colorName, "purple")
        XCTAssertEqual(board.orderedClips.map(\.text), ["filed clip"])
    }

    /// Boards merge by name (case-insensitively): importing into a store
    /// that already has "Addresses" files the incoming clips there and
    /// leaves the existing board's colour and position alone.
    func testImportMergesIntoAnExistingBoardByName() throws {
        let store = try ClipStore(inMemory: true)
        let existing = try XCTUnwrap(Pinboard.create(named: "Addresses", color: "blue", in: store.context))
        store.save()
        let existingOrder = existing.order

        let clip = ExportService.export(from: ClipItem(
            kind: .text, text: "new filing",
            contentHash: ContentParser.hashText("text:new filing"),
            createdAt: createdAt, isPinned: true
        ))
        var record = clip
        record.pinboard = "ADDRESSES"
        let json = "{\"pinboards\": [{\"name\": \"addresses\", \"color\": \"red\", \"order\": 0}], \"clips\": ["
            + (try ExportService.json(from: [record])).trimmingCharacters(in: CharacterSet(charactersIn: "[]\n "))
            + "]}"
        let url = try write(json)
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try HistoryExportController.readImport(from: url, store: store)

        XCTAssertEqual(store.pinboards().count, 1, "no second board for the same name")
        XCTAssertEqual(existing.colorName, "blue", "the existing board keeps its colour")
        XCTAssertEqual(existing.order, existingOrder)
        XCTAssertEqual(existing.orderedClips.map(\.text), ["new filing"])
    }

    /// A clip the store already holds is left exactly as it is, board
    /// included: an import must not refile someone's existing pins.
    func testImportNeverRefilesAClipTheStoreAlreadyHolds() throws {
        let store = try ClipStore(inMemory: true)
        let alreadyFiled = ClipItem(
            kind: .text, text: "already here",
            contentHash: ContentParser.hashText("text:already here"),
            createdAt: createdAt, isPinned: true
        )
        store.context.insert(alreadyFiled)
        store.save()

        var record = ExportService.export(from: ClipItem(
            kind: .text, text: "already here",
            contentHash: ContentParser.hashText("text:already here"),
            createdAt: createdAt, isPinned: true
        ))
        record.pinboard = "New Board"
        let url = try write(try ExportService.json(from: [record]))
        defer { try? FileManager.default.removeItem(at: url) }

        let outcome = try HistoryExportController.readImport(from: url, store: store)

        XCTAssertEqual(outcome, .init(inserted: 0, skipped: 1))
        XCTAssertNil(
            store.recent(limit: 1).first?.pinboard,
            "the skipped clip's board membership was not touched"
        )
        // The board the record named is still created: the document says it
        // exists, and an empty board is a real board. That is additive, not
        // a refile.
        XCTAssertNotNil(Pinboard.named("New Board", in: store.context))
    }

    /// Import adds; it never clears what is already stored.
    func testImportLeavesUnrelatedHistoryAlone() throws {
        let store = try makeStore([
            ClipItem(kind: .text, text: "kept", contentHash: "kept", createdAt: createdAt),
        ])
        let incoming = ExportService.export(from: makeHistory()[1])
        let url = try write(try ExportService.json(from: [incoming]))
        defer { try? FileManager.default.removeItem(at: url) }

        let outcome = try HistoryExportController.readImport(from: url, store: store)

        XCTAssertEqual(outcome, .init(inserted: 1, skipped: 0))
        XCTAssertEqual(store.recent(limit: 10).count, 2)
        XCTAssertTrue(store.recent(limit: 10).contains { $0.text == "kept" })
    }

    // MARK: Files that are not exports

    func testMalformedJSONImportsNothing() throws {
        let url = try write("{ this is not json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try ClipStore(inMemory: true)

        XCTAssertThrowsError(try HistoryExportController.readImport(from: url, store: store)) {
            XCTAssertEqual($0 as? ExportService.ImportError, .malformedDocument)
        }
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }

    func testForeignJSONImportsNothing() throws {
        let url = try write("[{\"title\": \"a bookmark from some other app\"}]")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try ClipStore(inMemory: true)

        XCTAssertThrowsError(try HistoryExportController.readImport(from: url, store: store)) {
            XCTAssertEqual($0 as? ExportService.ImportError, .malformedDocument)
        }
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }

    /// An empty file is not an empty history — it is a file that says nothing.
    func testEmptyFileFails() throws {
        let url = try write("")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try ClipStore(inMemory: true)

        XCTAssertThrowsError(try HistoryExportController.readImport(from: url, store: store)) {
            XCTAssertEqual($0 as? ExportService.ImportError, .malformedDocument)
        }
    }

    /// An empty history, on the other hand, exports as `[]` and imports as
    /// nothing at all — without an error.
    func testEmptyExportImportsNothing() throws {
        let url = try write("[]")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try ClipStore(inMemory: true)

        XCTAssertEqual(
            try HistoryExportController.readImport(from: url, store: store),
            .init(inserted: 0, skipped: 0)
        )
    }

    func testUnknownKindFails() throws {
        let url = try write("""
        [
          {
            "createdAt" : "2026-08-07T12:00:00Z",
            "fileURLs" : [],
            "isPinned" : false,
            "kind" : "hologram",
            "text" : "from a later version"
          }
        ]
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try ClipStore(inMemory: true)

        XCTAssertThrowsError(try HistoryExportController.readImport(from: url, store: store)) {
            XCTAssertEqual($0 as? ExportService.ImportError, .unknownKind("hologram"))
        }
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }

    func testDamagedBase64PayloadFails() throws {
        let url = try write("""
        [
          {
            "createdAt" : "2026-08-07T12:00:00Z",
            "fileURLs" : [],
            "imageBase64" : "not base64 at all!!",
            "isPinned" : false,
            "kind" : "image"
          }
        ]
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try ClipStore(inMemory: true)

        XCTAssertThrowsError(try HistoryExportController.readImport(from: url, store: store)) {
            XCTAssertEqual($0 as? ExportService.ImportError, .malformedPayload)
        }
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }

    /// All-or-nothing: the good record before the bad one is not imported.
    func testOneBadRecordFailsTheWholeFile() throws {
        let good = ExportService.export(from: makeHistory()[0])
        var bad = good
        bad.kind = "hologram"
        let url = try write(try ExportService.json(from: [good, bad]))
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try ClipStore(inMemory: true)

        XCTAssertThrowsError(try HistoryExportController.readImport(from: url, store: store))
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }

    /// Every failure the import can reach the user with says something in
    /// their language, rather than falling back to "operation couldn't be
    /// completed".
    func testEveryImportErrorIsLocalized() {
        let errors: [ExportService.ImportError] = [
            .malformedDocument,
            .unknownKind("hologram"),
            .malformedPayload,
        ]
        for error in errors {
            let description = error.errorDescription
            XCTAssertNotNil(description)
            XCTAssertFalse(description?.isEmpty ?? true)
            XCTAssertEqual(description, error.localizedDescription)
        }
    }
}
