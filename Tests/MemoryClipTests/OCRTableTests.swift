import AppKit
import XCTest

@testable import MemoryClip

/// End-to-end table recovery: a rendered table, through Vision, out as
/// Markdown. `TableLayoutTests` covers the geometry in isolation; this covers
/// the half that only real recognition can — whether Vision's word boxes are
/// where `OCRService` believes they are.
final class OCRTableTests: XCTestCase {
    func testRecognizesARenderedTableAsMarkdown() async throws {
        let png = try renderTable([
            ["Region", "Q3", "Q4"],
            ["North", "1,204", "1,881"],
            ["South", "990", "1,140"],
            ["East", "1,530", "1,402"],
        ])

        let result = await OCRService.recognizeText(in: png)
        let recognized = try XCTUnwrap(result, "Vision found no text in the rendered table")
        let tables = MarkdownTable.tables(in: recognized)
        XCTAssertEqual(tables.count, 1, "Expected one table, got: \(recognized)")
        let table = try XCTUnwrap(tables.first)
        XCTAssertEqual(table.header.count, 3, "Expected three columns, got: \(recognized)")
        XCTAssertEqual(table.rows.count, 3, "Expected three data rows, got: \(recognized)")
        XCTAssertEqual(table.header.first, "Region", recognized)
        XCTAssertEqual(table.rows.first?.first, "North", recognized)
    }

    /// The other half of the contract: ordinary text must come back exactly as
    /// it did before tables existed.
    func testProseIsUnchangedByTheTablePass() async throws {
        let png = try renderTable([
            ["The quick brown fox jumps"],
            ["over the lazy dog and then"],
            ["it turns to look at the fox"],
        ])

        let result = await OCRService.recognizeText(in: png)
        let recognized = try XCTUnwrap(result)
        XCTAssertTrue(MarkdownTable.tables(in: recognized).isEmpty, recognized)
    }

    /// Rows drawn in a monospaced font at fixed column stops — the layout a
    /// terminal, a spreadsheet screenshot or a Markdown preview produces.
    private func renderTable(_ rows: [[String]]) throws -> Data {
        let font = NSFont.monospacedSystemFont(ofSize: 34, weight: .regular)
        let columnWidth: CGFloat = 260
        let rowHeight: CGFloat = 64
        let columns = rows.map(\.count).max() ?? 1
        let size = NSSize(
            width: CGFloat(columns) * columnWidth + 80,
            height: CGFloat(rows.count) * rowHeight + 80
        )

        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        for (rowIndex, row) in rows.enumerated() {
            let y = size.height - 60 - CGFloat(rowIndex) * rowHeight
            for (columnIndex, cell) in row.enumerated() {
                (cell as NSString).draw(
                    at: NSPoint(x: 40 + CGFloat(columnIndex) * columnWidth, y: y),
                    withAttributes: attributes
                )
            }
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw XCTSkip("Could not render a test image on this machine")
        }
        return png
    }
}
