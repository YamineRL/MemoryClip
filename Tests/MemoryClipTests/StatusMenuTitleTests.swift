import Foundation
import XCTest

@testable import MemoryClip

/// `StatusController.menuTitle(for:redacted:)` is pure, so it is tested
/// directly — no status item, no menu, no window server.
@MainActor
final class StatusMenuTitleTests: XCTestCase {
    private func makeItem(
        kind: ClipKind,
        text: String? = nil,
        fileURLStrings: [String] = [],
        colorHex: String? = nil
    ) -> ClipItem {
        ClipItem(
            kind: kind,
            text: text,
            fileURLStrings: fileURLStrings,
            colorHex: colorHex,
            contentHash: UUID().uuidString
        )
    }

    func testShortTextIsShownVerbatim() {
        XCTAssertEqual(StatusController.menuTitle(for: makeItem(kind: .text, text: "hello")), "hello")
    }

    func testLongTextIsTruncatedTo48Characters() {
        let long = String(repeating: "x", count: 200)
        let title = StatusController.menuTitle(for: makeItem(kind: .text, text: long))
        XCTAssertEqual(title.count, StatusController.menuTitleLimit)
        XCTAssertEqual(title, String(repeating: "x", count: 48))
    }

    func testNewlinesAreFlattenedToSpaces() {
        let title = StatusController.menuTitle(for: makeItem(kind: .text, text: "line 1\nline 2\r\nline 3\rline 4"))
        XCTAssertEqual(title, "line 1 line 2 line 3 line 4")
        XCTAssertFalse(title.contains("\n"))
        XCTAssertFalse(title.contains("\r"))
    }

    func testEmptyAndMissingTextFallBackToAPlaceholder() {
        XCTAssertEqual(StatusController.menuTitle(for: makeItem(kind: .text, text: "")), "Clip")
        XCTAssertEqual(StatusController.menuTitle(for: makeItem(kind: .text, text: nil)), "Clip")
        XCTAssertEqual(StatusController.menuTitle(for: makeItem(kind: .link, text: nil)), "Clip")
    }

    func testFileTitleUsesLastPathComponents() {
        let item = makeItem(kind: .file, fileURLStrings: ["file:///tmp/a.txt", "file:///Users/me/b.png"])
        XCTAssertEqual(StatusController.menuTitle(for: item), "a.txt, b.png")
        XCTAssertEqual(StatusController.menuTitle(for: makeItem(kind: .file)), "File")
    }

    func testImageAndColorTitles() {
        XCTAssertEqual(StatusController.menuTitle(for: makeItem(kind: .image)), "Image")
        XCTAssertEqual(
            StatusController.menuTitle(for: makeItem(kind: .color, colorHex: "#FF8800")),
            "Color #FF8800"
        )
    }

    // MARK: Redaction (app lock)

    /// A locked MemoryClip must never render clip contents in the dropdown.
    func testRedactedTitlesLeakNoContent() {
        let secret = "hunter2-super-secret-token"
        let cases: [(ClipItem, String)] = [
            (makeItem(kind: .text, text: secret), "Text clip"),
            (makeItem(kind: .richText, text: secret), "Rich text clip"),
            (makeItem(kind: .link, text: "https://example.com/\(secret)"), "Link"),
            (makeItem(kind: .image), "Image"),
            (makeItem(kind: .file, fileURLStrings: ["file:///tmp/\(secret).txt"]), "File"),
            (makeItem(kind: .color, colorHex: "#FF8800"), "Color"),
        ]

        for (item, expected) in cases {
            let title = StatusController.menuTitle(for: item, redacted: true)
            XCTAssertEqual(title, expected)
            XCTAssertFalse(title.contains(secret))
            XCTAssertFalse(title.contains("FF8800"))
        }
    }

    // MARK: Streaming export
    //
    // The writer these exercise moved to `HistoryExportController` when the
    // export left the dropdown for Settings → History. The tests stayed here,
    // beside the store fixtures they share with the titles above; only the
    // type they call changed.

    private func makeExportStore(textClips: Int, imageClips: Int) throws -> ClipStore {
        let store = try ClipStore(inMemory: true)
        for i in 0..<textClips {
            store.context.insert(ClipItem(
                kind: .text, text: "clip \(i)", contentHash: "t:\(i)",
                sourceAppName: "Safari",
                createdAt: .now.addingTimeInterval(-Double(i))
            ))
        }
        for i in 0..<imageClips {
            store.context.insert(ClipItem(
                kind: .image, imageData: Data([0x89, 0x50, 0x4E, 0x47, UInt8(i)]),
                contentHash: "i:\(i)",
                createdAt: .now.addingTimeInterval(-1000 - Double(i))
            ))
        }
        store.save()
        return store
    }

    private func tempURL(_ ext: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoryclip-export-test-\(UUID().uuidString).\(ext)")
    }

    /// The export streams page by page (see `HistoryExportController.exportPageSize`);
    /// the file must still be exactly what encoding the whole history yields.
    func testStreamedJSONExportMatchesTheWholeDocument() throws {
        // More clips than one page, so the paging loop really runs.
        let store = try makeExportStore(textClips: HistoryExportController.exportPageSize * 2 + 7, imageClips: 3)
        let url = tempURL("json")
        defer { try? FileManager.default.removeItem(at: url) }

        let count = try HistoryExportController.writeExport(to: url, asCSV: false, store: store)

        let all = store.recent(limit: 10_000)
        XCTAssertEqual(count, all.count)
        let expected = try ExportService.json(from: ExportService.exports(from: all))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expected)
    }

    func testStreamedCSVExportMatchesTheWholeDocument() throws {
        let store = try makeExportStore(textClips: HistoryExportController.exportPageSize + 3, imageClips: 1)
        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }

        let count = try HistoryExportController.writeExport(to: url, asCSV: true, store: store)

        let all = store.recent(limit: 10_000)
        XCTAssertEqual(count, all.count)
        let expected = ExportService.csv(from: ExportService.exports(from: all))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expected)
    }

    /// The file is the plaintext of the whole history: owner-only, from the
    /// moment it is created.
    func testExportFileIsOwnerReadableOnly() throws {
        let store = try makeExportStore(textClips: 3, imageClips: 0)
        let url = tempURL("json")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try HistoryExportController.writeExport(to: url, asCSV: false, store: store)

        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(mode.int16Value, 0o600)
    }

    /// An empty history still produces a well-formed document, not an empty
    /// file.
    func testEmptyHistoryExportsCanonicalDocuments() throws {
        let store = try ClipStore(inMemory: true)
        let json = tempURL("json")
        let csv = tempURL("csv")
        defer {
            try? FileManager.default.removeItem(at: json)
            try? FileManager.default.removeItem(at: csv)
        }

        XCTAssertEqual(try HistoryExportController.writeExport(to: json, asCSV: false, store: store), 0)
        XCTAssertEqual(try HistoryExportController.writeExport(to: csv, asCSV: true, store: store), 0)
        XCTAssertEqual(try String(contentsOf: json, encoding: .utf8), "[]")
        XCTAssertEqual(try String(contentsOf: csv, encoding: .utf8), ExportService.csvHeader)
    }

    /// Overwriting an existing (world-readable) file must not inherit its mode.
    func testExportOverwritesAnExistingFileAndTightensItsMode() throws {
        let store = try makeExportStore(textClips: 2, imageClips: 0)
        let url = tempURL("json")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data("stale".utf8),
            attributes: [.posixPermissions: NSNumber(value: 0o644)]
        )

        _ = try HistoryExportController.writeExport(to: url, asCSV: false, store: store)

        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(mode.int16Value, 0o600)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("stale"))
    }
}
