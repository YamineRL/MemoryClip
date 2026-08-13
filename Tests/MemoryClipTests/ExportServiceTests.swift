import Foundation
import XCTest

@testable import MemoryClip

final class ExportServiceTests: XCTestCase {

    // Whole-second timestamps so the ISO 8601 encode/decode round-trip is
    // exact (the export formats intentionally drop sub-second precision).
    private let createdAt = Date(timeIntervalSince1970: 1_720_000_000)
    private let lastUsedAt = Date(timeIntervalSince1970: 1_720_003_600)

    private func makeClip(
        kind: ClipKind = .text,
        text: String? = "hello world",
        colorHex: String? = nil,
        fileURLs: [String] = [],
        sourceAppBundleID: String? = "com.apple.Safari",
        sourceAppName: String? = "Safari",
        lastUsedAt: Date? = nil,
        isPinned: Bool = false,
        richTextBase64: String? = nil,
        imageBase64: String? = nil
    ) -> ClipExport {
        ClipExport(
            kind: kind.rawValue,
            text: text,
            colorHex: colorHex,
            fileURLs: fileURLs,
            sourceAppBundleID: sourceAppBundleID,
            sourceAppName: sourceAppName,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            isPinned: isPinned,
            richTextBase64: richTextBase64,
            imageBase64: imageBase64
        )
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func assertEqual(
        _ lhs: ClipExport,
        _ rhs: ClipExport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.kind, rhs.kind, file: file, line: line)
        XCTAssertEqual(lhs.text, rhs.text, file: file, line: line)
        XCTAssertEqual(lhs.colorHex, rhs.colorHex, file: file, line: line)
        XCTAssertEqual(lhs.fileURLs, rhs.fileURLs, file: file, line: line)
        XCTAssertEqual(lhs.sourceAppBundleID, rhs.sourceAppBundleID, file: file, line: line)
        XCTAssertEqual(lhs.sourceAppName, rhs.sourceAppName, file: file, line: line)
        XCTAssertEqual(lhs.createdAt, rhs.createdAt, file: file, line: line)
        XCTAssertEqual(lhs.lastUsedAt, rhs.lastUsedAt, file: file, line: line)
        XCTAssertEqual(lhs.isPinned, rhs.isPinned, file: file, line: line)
        XCTAssertEqual(lhs.richTextBase64, rhs.richTextBase64, file: file, line: line)
        XCTAssertEqual(lhs.imageBase64, rhs.imageBase64, file: file, line: line)
    }

    // MARK: JSON

    func testJSONRoundTripIsLossless() throws {
        let clips = [
            makeClip(lastUsedAt: lastUsedAt, isPinned: true),
            makeClip(
                kind: .richText,
                text: "line 1, \"quoted\"\nline 2",
                richTextBase64: Data("rich text payload".utf8).base64EncodedString()
            ),
            makeClip(
                kind: .image,
                text: nil,
                sourceAppBundleID: nil,
                sourceAppName: nil,
                imageBase64: Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
            ),
        ]

        let json = try ExportService.json(from: clips)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([ClipExport].self, from: Data(json.utf8))

        XCTAssertEqual(decoded.count, clips.count)
        for (original, restored) in zip(clips, decoded) {
            assertEqual(restored, original)
        }
    }

    func testJSONContainsBase64Fields() throws {
        let richBase64 = Data("rtf payload".utf8).base64EncodedString()
        let imageBase64 = Data([0x01, 0x02, 0x03]).base64EncodedString()
        let clip = makeClip(kind: .richText, richTextBase64: richBase64, imageBase64: imageBase64)

        let json = try ExportService.json(from: [clip])

        XCTAssertTrue(json.contains("\"richTextBase64\""))
        XCTAssertTrue(json.contains(richBase64))
        XCTAssertTrue(json.contains("\"imageBase64\""))
        XCTAssertTrue(json.contains(imageBase64))
    }

    func testJSONKeysAreSorted() throws {
        let clip = makeClip(
            kind: .color,
            text: "#FF8800",
            colorHex: "#FF8800",
            lastUsedAt: lastUsedAt,
            isPinned: true
        )

        let json = try ExportService.json(from: [clip])

        // Alphabetical key order for every field present on this clip.
        let keys = [
            "colorHex", "createdAt", "fileURLs", "isPinned", "kind",
            "lastUsedAt", "sourceAppBundleID", "sourceAppName", "text",
        ]
        var previous: Range<String.Index>?
        for key in keys {
            guard let range = json.range(of: "\"\(key)\" :") else {
                XCTFail("JSON is missing key \"\(key)\"")
                return
            }
            if let previous {
                XCTAssertTrue(range.lowerBound > previous.lowerBound, "key \"\(key)\" is out of sorted order")
            }
            previous = range
        }
    }

    func testJSONEmptyArray() throws {
        XCTAssertEqual(try ExportService.json(from: []), "[]")
    }

    // MARK: Streaming

    /// The streaming writer exists so a big history is never encoded into one
    /// in-memory document; it must still produce exactly the same bytes.
    func testStreamedJSONMatchesWholeDocument() throws {
        let clips = [
            makeClip(lastUsedAt: lastUsedAt, isPinned: true),
            makeClip(kind: .richText, text: "line 1, \"quoted\"\nline 2",
                     richTextBase64: Data("rich text payload".utf8).base64EncodedString()),
            makeClip(kind: .image, text: nil, sourceAppBundleID: nil, sourceAppName: nil,
                     imageBase64: Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()),
        ]

        var stream = ExportService.Stream(format: .json)
        var streamed = stream.header
        for clip in clips {
            streamed += try stream.chunk(for: clip)
        }
        streamed += stream.footer

        XCTAssertEqual(streamed, try ExportService.json(from: clips))
    }

    func testStreamedCSVMatchesWholeDocument() throws {
        let clips = [
            makeClip(text: "=SUM(A1,A2)", lastUsedAt: lastUsedAt, isPinned: true),
            makeClip(kind: .file, text: nil,
                     fileURLs: ["file:///Users/me/a.txt", "file:///tmp/b.png"],
                     sourceAppName: "Finder"),
            makeClip(text: "He said \"hi\", politely\nand left"),
        ]

        var stream = ExportService.Stream(format: .csv)
        var streamed = stream.header
        for clip in clips {
            streamed += try stream.chunk(for: clip)
        }
        streamed += stream.footer

        XCTAssertEqual(streamed, ExportService.csv(from: clips))
    }

    /// Writing nothing must still yield a well-formed document.
    func testStreamedEmptyDocuments() {
        var json = ExportService.Stream(format: .json)
        XCTAssertEqual(json.header + json.footer, "[]")
        var csv = ExportService.Stream(format: .csv)
        XCTAssertEqual(csv.header + csv.footer, ExportService.csvHeader)
    }

    /// Streamed output is valid JSON when decoded as one document, page by
    /// page — the property a truncated or mis-separated stream would break.
    func testStreamedJSONDecodesAsOneArray() throws {
        let clips = (0..<7).map { i in makeClip(text: "clip \(i)") }

        var stream = ExportService.Stream(format: .json)
        var streamed = stream.header
        // Two pages of 3 and a partial page, the way the exporter drives it.
        for page in stride(from: 0, to: clips.count, by: 3) {
            for clip in clips[page..<min(page + 3, clips.count)] {
                streamed += try stream.chunk(for: clip)
            }
        }
        streamed += stream.footer

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([ClipExport].self, from: Data(streamed.utf8))
        XCTAssertEqual(decoded.map(\.text), clips.map(\.text))
    }

    // MARK: Streaming benchmark (MEMORYCLIP_BENCH=1)

    /// Resident/footprint memory of this process, in bytes.
    private func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
    }

    /// Peak memory of "encode everything, then write" versus "stream a page at
    /// a time" for an image-heavy history.
    @MainActor
    func testExportMemoryBenchmark() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MEMORYCLIP_BENCH"] == "1",
            "set MEMORYCLIP_BENCH=1 to run benchmarks"
        )
        let imageCount = 200
        let imageBytes = 1_284_000  // the measured average screenshot blob
        let pageSize = HistoryExportController.exportPageSize

        func page(_ index: Int, count: Int) -> [ClipExport] {
            (0..<count).map { i in
                var data = Data(repeating: UInt8((index + i) & 0xFF), count: imageBytes)
                data[0] = UInt8(i & 0xFF)
                return makeClip(kind: .image, text: nil, imageBase64: data.base64EncodedString())
            }
        }

        let mb = { (bytes: Int64) in String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        print("BENCH | export/blob bytes in this history | \(mb(Int64(imageCount * imageBytes)))")

        // New shape first, on a clean baseline: one page live at a time,
        // flushed to the file as it goes.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoryclip-export-bench-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)

        var peakStreamed: Int64 = 0
        let streamBase = footprint()
        var start = DispatchTime.now().uptimeNanoseconds
        var stream = ExportService.Stream(format: .json)
        try handle.write(contentsOf: Data(stream.header.utf8))
        for pageIndex in 0..<(imageCount / pageSize) {
            try autoreleasepool {
                for clip in page(pageIndex * pageSize, count: pageSize) {
                    try handle.write(contentsOf: Data(stream.chunk(for: clip).utf8))
                }
                peakStreamed = max(peakStreamed, footprint())
            }
        }
        try handle.write(contentsOf: Data(stream.footer.utf8))
        try handle.close()
        let streamMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("BENCH | export/streamed | peak +\(mb(peakStreamed - streamBase)) over baseline, "
              + "\(streamMs) ms, file \(mb(Int64(size ?? 0)))")

        // Old shape: every clip Base64'd into one array, then one document.
        let wholeBase = footprint()
        var peakWhole: Int64 = 0
        start = DispatchTime.now().uptimeNanoseconds
        try autoreleasepool {
            let all = (0..<(imageCount / pageSize)).flatMap { page($0 * pageSize, count: pageSize) }
            let document = try ExportService.json(from: all)
            peakWhole = footprint()
            XCTAssertGreaterThan(document.count, 0)
        }
        let wholeMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("BENCH | export/whole-document | peak +\(mb(peakWhole - wholeBase)) over baseline, \(wholeMs) ms")
    }

    // MARK: CSV

    func testCSVHeader() {
        let csv = ExportService.csv(from: [makeClip()])

        let firstLine = csv.components(separatedBy: "\n").first
        XCTAssertEqual(
            firstLine,
            "kind,text,colorHex,fileURLs,sourceAppName,createdAt,lastUsedAt,isPinned"
        )
    }

    func testCSVEscapesCommasQuotesAndNewlines() {
        let tricky = "He said \"hi\", politely\nand left"
        let clip = makeClip(text: tricky, sourceAppName: "Notes")

        let csv = ExportService.csv(from: [clip])
        let lines = csv.components(separatedBy: "\n")

        // Header + two physical lines (the embedded newline stays inside the
        // quoted field per RFC 4180).
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(
            lines[1] + "\n" + lines[2],
            "text,\"He said \"\"hi\"\", politely\nand left\",,,Notes,\(iso8601(createdAt)),,false"
        )
        // Plain fields stay unquoted.
        XCTAssertFalse(csv.contains("\"Notes\""))
    }

    func testCSVNilLastUsedAtIsEmptyColumn() {
        let clip = makeClip(text: "abc", lastUsedAt: nil)

        let row = ExportService.csv(from: [clip]).components(separatedBy: "\n")[1]
        // No special characters anywhere, so a plain split is safe.
        let fields = row.components(separatedBy: ",")

        XCTAssertEqual(fields.count, 8)
        XCTAssertEqual(fields[6], "")
        XCTAssertEqual(fields[5], iso8601(createdAt))
    }

    func testCSVLastUsedAtAndPinnedRendered() {
        let clip = makeClip(lastUsedAt: lastUsedAt, isPinned: true)

        let row = ExportService.csv(from: [clip]).components(separatedBy: "\n")[1]

        XCTAssertTrue(row.contains(",\(iso8601(lastUsedAt)),"))
        XCTAssertTrue(row.hasSuffix(",true"))
    }

    func testCSVFileURLsJoinedWithSemicolonSpace() {
        let clip = makeClip(
            kind: .file,
            text: nil,
            fileURLs: ["file:///Users/me/a.txt", "file:///tmp/b.png"],
            sourceAppName: "Finder"
        )

        let row = ExportService.csv(from: [clip]).components(separatedBy: "\n")[1]

        XCTAssertTrue(row.contains("file:///Users/me/a.txt; file:///tmp/b.png"))
    }

    func testCSVEmptyArrayIsHeaderOnly() {
        XCTAssertEqual(
            ExportService.csv(from: []),
            "kind,text,colorHex,fileURLs,sourceAppName,createdAt,lastUsedAt,isPinned"
        )
    }

    // MARK: CSV formula injection

    func testCSVDefusesFormulaLeadingCharacters() {
        for trigger in ["=", "+", "-", "@", "\t"] {
            let payload = "\(trigger)HYPERLINK(\"http://evil\")"
            let row = ExportService.csv(from: [makeClip(text: payload)])
                .components(separatedBy: "\n")[1]
            XCTAssertTrue(
                row.contains("'\(trigger)HYPERLINK"),
                "field starting with \(trigger) was not defused: \(row)"
            )
        }
    }

    func testCSVDefusingIsAppliedBeforeQuoting() {
        // A formula that also needs RFC-4180 quoting: the apostrophe must end
        // up INSIDE the quotes, not outside them.
        let row = ExportService.csv(from: [makeClip(text: "=SUM(A1,A2)")])
            .components(separatedBy: "\n")[1]
        XCTAssertTrue(row.contains("\"'=SUM(A1,A2)\""), row)
    }

    func testCSVLeavesOrdinaryFieldsAlone() {
        XCTAssertEqual(ExportService.csvDefused("hello"), "hello")
        XCTAssertEqual(ExportService.csvDefused(""), "")
        XCTAssertEqual(ExportService.csvDefused("2026-08-07T12:00:00Z"), "2026-08-07T12:00:00Z")
    }

    // MARK: ClipItem → ClipExport mapping

    @MainActor
    func testExportMapsEveryFieldFromTheModel() {
        let rich = Data("rtf payload".utf8)
        let image = Data([0x89, 0x50, 0x4E, 0x47])
        let item = ClipItem(
            kind: .richText,
            text: "body text",
            richTextData: rich,
            imageData: image,
            fileURLStrings: ["file:///tmp/a.txt"],
            colorHex: "#FF8800",
            contentHash: "hash",
            sourceBundleID: "com.apple.Safari",
            sourceAppName: "Safari",
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            isPinned: true
        )

        let export = ExportService.export(from: item)

        XCTAssertEqual(export.kind, ClipKind.richText.rawValue)
        XCTAssertEqual(export.text, "body text")
        XCTAssertEqual(export.colorHex, "#FF8800")
        XCTAssertEqual(export.fileURLs, ["file:///tmp/a.txt"])
        // The two source fields are easy to swap — pin them down explicitly.
        XCTAssertEqual(export.sourceAppBundleID, "com.apple.Safari")
        XCTAssertEqual(export.sourceAppName, "Safari")
        XCTAssertEqual(export.createdAt, createdAt)
        XCTAssertEqual(export.lastUsedAt, lastUsedAt)
        XCTAssertTrue(export.isPinned)
        XCTAssertEqual(export.richTextBase64, rich.base64EncodedString())
        XCTAssertEqual(export.imageBase64, image.base64EncodedString())
    }

    @MainActor
    func testExportKeepsOptionalsNilAndPreservesOrder() {
        let first = ClipItem(kind: .text, text: "one", contentHash: "h1", createdAt: createdAt)
        let second = ClipItem(kind: .image, contentHash: "h2", createdAt: lastUsedAt)

        let exports = ExportService.exports(from: [first, second])

        XCTAssertEqual(exports.map(\.text), ["one", nil])
        XCTAssertEqual(exports.map(\.kind), [ClipKind.text.rawValue, ClipKind.image.rawValue])
        XCTAssertNil(exports[0].richTextBase64)
        XCTAssertNil(exports[0].imageBase64)
        XCTAssertNil(exports[1].lastUsedAt)
        XCTAssertNil(exports[1].sourceAppBundleID)
        XCTAssertNil(exports[1].sourceAppName)
        XCTAssertFalse(exports[1].isPinned)
        XCTAssertEqual(exports[1].fileURLs, [])
    }

    /// The mapping must survive a full export round trip, not just field
    /// equality — dropping `imageBase64` used to keep every test green.
    @MainActor
    func testExportedModelSurvivesTheJSONRoundTrip() throws {
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let item = ClipItem(
            kind: .image,
            imageData: image,
            contentHash: "hash",
            sourceBundleID: "com.apple.Preview",
            sourceAppName: "Preview",
            createdAt: createdAt
        )

        let json = try ExportService.json(from: ExportService.exports(from: [item]))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([ClipExport].self, from: Data(json.utf8))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].imageBase64, image.base64EncodedString())
        XCTAssertEqual(decoded[0].sourceAppBundleID, "com.apple.Preview")
        XCTAssertEqual(decoded[0].sourceAppName, "Preview")
    }

    /// Empty binary payloads must export as `null`, not `""`.
    ///
    /// `imageData` is `@Attribute(.externalStorage)`. Rows written before that
    /// attribute existed, whose column was NULL, come back through the
    /// external-storage accessor as an EMPTY `Data` — so a text clip stored by
    /// an older build would otherwise emit `"imageBase64": ""`.
    @MainActor
    func testEmptyBinaryPayloadsExportAsNull() throws {
        let item = ClipItem(kind: .text, text: "plain", contentHash: "hash", createdAt: createdAt)
        item.imageData = Data()
        item.richTextData = Data()

        let export = ExportService.export(from: item)
        XCTAssertNil(export.imageBase64)
        XCTAssertNil(export.richTextBase64)

        let json = try ExportService.json(from: [export])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([ClipExport].self, from: Data(json.utf8))
        XCTAssertNil(decoded[0].imageBase64)
        XCTAssertNil(decoded[0].richTextBase64)
        XCTAssertFalse(json.contains("\"\""))
    }
}
