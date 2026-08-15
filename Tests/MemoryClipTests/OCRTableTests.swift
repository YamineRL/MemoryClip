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

    /// The case this was built for: a documentation table in dark mode whose
    /// middle column wraps over five lines, so every row of it reaches Vision
    /// as several bands of words with nothing in the first column but the
    /// first band.
    func testRecognizesATableWithWrappedCells() async throws {
        let png = try renderWrappedTable(
            [
                ["Layer", "Role", "Stack"],
                [
                    "StreamSyncAgent",
                    """
                    Backend AI agent that automates stream operations - chat management, overlay \
                    triggers, milestone tracking, sponsor enforcement, reminders, cron jobs, \
                    content repurposing, and audience engagement.
                    """,
                    "Python, SQLite, Redis, Celery",
                ],
                [
                    "Streamz",
                    """
                    Public-facing metaprofile where creators curate social links, collections, \
                    activity feeds, Web3 badges, and monetize through affiliate links and \
                    referrals. Hosts the agent control dashboard.
                    """,
                    "Next.js 15, React 19, TypeScript, Supabase",
                ],
            ],
            widths: [230, 520, 300]
        )

        let result = await OCRService.recognizeText(in: png)
        let recognized = try XCTUnwrap(result, "Vision found no text in the rendered table")
        let tables = MarkdownTable.tables(in: recognized)
        XCTAssertEqual(tables.count, 1, "Expected one table, got: \(recognized)")
        let table = try XCTUnwrap(tables.first)
        XCTAssertEqual(table.header, ["Layer", "Role", "Stack"], recognized)
        XCTAssertEqual(table.rows.count, 2, "Expected two data rows, got: \(recognized)")

        // The wrapped cell has to come back whole: first line, last line, and
        // the column beside it that ran out of text three lines early.
        //
        // Every string asserted on here avoids bare acronyms. Vision reads a
        // standalone capital I as a lowercase l when no surrounding word tells
        // it otherwise — "APIs" came back "APls" on the CI runner and passed
        // on the maintainer's Mac. What this test is for is the geometry, so
        // the fixture spends real words rather than staking the suite on which
        // Vision version the image happens to ship.
        let agent = try XCTUnwrap(table.rows.first)
        XCTAssertEqual(agent.first, "StreamSyncAgent", recognized)
        XCTAssertTrue(agent[1].hasPrefix("Backend"), recognized)
        XCTAssertTrue(agent[1].hasSuffix("and audience engagement."), recognized)
        XCTAssertTrue(agent[2].hasPrefix("Python, SQLite, Redis"), recognized)
        XCTAssertTrue(agent[2].hasSuffix("Celery"), recognized)

        let streamz = try XCTUnwrap(table.rows.last)
        XCTAssertEqual(streamz.first, "Streamz", recognized)
        XCTAssertTrue(streamz[1].hasSuffix("Hosts the agent control dashboard."), recognized)
        XCTAssertTrue(streamz[2].hasSuffix("TypeScript, Supabase"), recognized)
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

    /// Cells wrapped inside fixed-width columns, light on dark — the shape a
    /// documentation page screenshotted in dark mode arrives in. Each row is
    /// as tall as its tallest cell, so the short columns leave the gaps that
    /// made the detector give up.
    private func renderWrappedTable(_ rows: [[String]], widths: [CGFloat]) throws -> Data {
        let margin: CGFloat = 60
        let gutter: CGFloat = 70
        let rowPadding: CGFloat = 34

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 8
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 26),
            .foregroundColor: NSColor(white: 0.93, alpha: 1),
            .paragraphStyle: paragraph,
        ]
        func height(_ text: String, width: CGFloat) -> CGFloat {
            ceil(
                (text as NSString).boundingRect(
                    with: NSSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes
                ).height
            )
        }

        let rowHeights = rows.map { row in
            row.enumerated().map { height($0.element, width: widths[$0.offset]) }.max() ?? 0
        }
        let size = NSSize(
            width: margin * 2 + widths.reduce(0, +) + gutter * CGFloat(widths.count - 1),
            height: margin * 2 + rowHeights.reduce(0, +) + rowPadding * CGFloat(rows.count - 1)
        )

        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(white: 0.11, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        var top = size.height - margin
        for (rowIndex, row) in rows.enumerated() {
            var x = margin
            for (columnIndex, cell) in row.enumerated() {
                (cell as NSString).draw(
                    in: NSRect(
                        x: x,
                        y: top - rowHeights[rowIndex],
                        width: widths[columnIndex],
                        height: rowHeights[rowIndex]
                    ),
                    withAttributes: attributes
                )
                x += widths[columnIndex] + gutter
            }
            top -= rowHeights[rowIndex] + rowPadding
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
