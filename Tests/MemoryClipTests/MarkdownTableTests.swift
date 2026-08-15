import XCTest

@testable import MemoryClip

final class MarkdownTableTests: XCTestCase {
    // MARK: - Rendering

    func testRendersHeaderAlignmentRowAndBody() {
        let table = MarkdownTable(header: ["A", "B"], rows: [["1", "2"], ["3", "4"]])
        XCTAssertEqual(
            table.markdown,
            """
            | A | B |
            | --- | --- |
            | 1 | 2 |
            | 3 | 4 |
            """
        )
    }

    /// A pipe inside a cell would end the cell early and shift every value
    /// after it one column left — a table that is wrong rather than one that
    /// looks broken.
    func testEscapesPipesAndCollapsesNewlines() {
        let table = MarkdownTable(header: ["cmd", "note"], rows: [["ls | wc", "two\nlines"]])
        XCTAssertEqual(
            table.markdown,
            """
            | cmd | note |
            | --- | --- |
            | ls \\| wc | two lines |
            """
        )
        let parsed = MarkdownTable.tables(in: table.markdown)
        XCTAssertEqual(parsed.first?.rows.first, ["ls | wc", "two lines"])
    }

    func testShortRowsArePaddedAndLongRowsFoldIntoTheLastColumn() {
        XCTAssertEqual(MarkdownTable.fitted(["a"], to: 3), ["a", "", ""])
        XCTAssertEqual(MarkdownTable.fitted(["a", "b", "c", "d"], to: 2), ["a", "b c d"])
    }

    // MARK: - Parsing

    func testSplitsTextAroundATable() {
        let blocks = MarkdownTable.blocks(
            in: """
            Before

            | A | B |
            | --- | --- |
            | 1 | 2 |

            After
            """
        )

        XCTAssertEqual(blocks.count, 3)
        guard case .text(let before) = blocks.first else { return XCTFail("Expected leading text") }
        XCTAssertEqual(before, "Before\n")
        guard case .table(let table) = blocks[1] else { return XCTFail("Expected a table") }
        XCTAssertEqual(table.header, ["A", "B"])
        XCTAssertEqual(table.rows, [["1", "2"]])
        guard case .text(let after) = blocks[2] else { return XCTFail("Expected trailing text") }
        XCTAssertEqual(after, "\nAfter")
    }

    func testTextWithoutATableIsOneBlock() {
        let blocks = MarkdownTable.blocks(in: "just\ntext")
        XCTAssertEqual(blocks, [.text("just\ntext")])
    }

    /// A line with a pipe in it is not a table unless the alignment row under
    /// it agrees on how many columns there are.
    func testPipesInProseAreNotATable() {
        XCTAssertTrue(MarkdownTable.tables(in: "ls | wc -l\nrunning it\nagain").isEmpty)
        XCTAssertTrue(MarkdownTable.tables(in: "| A | B |\n| --- |\n| 1 | 2 |").isEmpty)
    }

    func testHeaderWithoutDataRowsIsNotATable() {
        XCTAssertTrue(MarkdownTable.tables(in: "| A | B |\n| --- | --- |").isEmpty)
    }

    func testRowsAreFittedToTheHeaderWidth() {
        let table = MarkdownTable.tables(in: "| A | B | C |\n| --- | --- | --- |\n| 1 |\n").first
        XCTAssertEqual(table?.rows, [["1", "", ""]])
    }

    /// Backslashes that are not escaping a pipe keep their meaning: OCR of a
    /// Windows path or a regex is full of them.
    func testUnrelatedBackslashesSurvive() {
        let cells = MarkdownTable.cells(in: #"| C:\Users | \d+ |"#)
        XCTAssertEqual(cells, [#"C:\Users"#, #"\d+"#])
    }
}
