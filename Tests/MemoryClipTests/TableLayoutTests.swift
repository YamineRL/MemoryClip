import CoreGraphics
import XCTest

@testable import MemoryClip

/// Table recovery, driven from laid-out text rather than from images.
///
/// `page(_:)` below turns a monospaced block into the same (line, word, box)
/// shape Vision hands `TableLayout`, one character being one unit of width.
/// That keeps these tests about the geometry — which is the part with the
/// judgement calls in it — instead of about whether a rendered PNG happened
/// to recognize.
final class TableLayoutTests: XCTestCase {
    // MARK: - Detection

    func testRecoversAThreeColumnTable() throws {
        let page = page(
            """
            Region    Q3        Q4
            North     1,204     1,881
            South     990       1,140
            East      1,530     1,402
            """
        )

        let text = try XCTUnwrap(
            TableLayout.textWithTables(lines: page.lines, fragments: page.fragments)
        )
        XCTAssertEqual(
            text,
            """
            | Region | Q3 | Q4 |
            | --- | --- | --- |
            | North | 1,204 | 1,881 |
            | South | 990 | 1,140 |
            | East | 1,530 | 1,402 |
            """
        )
    }

    /// Words inside one cell stay in that cell: only a channel clear through
    /// every row splits a column.
    func testMultiWordCellsStayInOneColumn() throws {
        let page = page(
            """
            Name             Role        Team
            Ada Lovelace     Engineer    Core
            Alan Turing      Analyst     Core
            """
        )

        let text = try XCTUnwrap(
            TableLayout.textWithTables(lines: page.lines, fragments: page.fragments)
        )
        XCTAssertTrue(
            text.contains("| Ada Lovelace | Engineer | Core |"),
            "Expected the two-word name to stay one cell, got: \(text)"
        )
    }

    /// The line above a table is not part of it, and survives unchanged.
    func testTextAroundATableIsKept() throws {
        let page = page(
            """
            Quarterly revenue
            Region    Q3        Q4
            North     1,204     1,881
            South     990       1,140
            Source: finance
            """
        )

        let text = try XCTUnwrap(
            TableLayout.textWithTables(lines: page.lines, fragments: page.fragments)
        )
        XCTAssertEqual(
            text,
            """
            Quarterly revenue

            | Region | Q3 | Q4 |
            | --- | --- | --- |
            | North | 1,204 | 1,881 |
            | South | 990 | 1,140 |

            Source: finance
            """
        )
    }

    /// A right-aligned numeric column has no consistent left edge, which is
    /// exactly why columns are found from the whitespace between them.
    func testFindsRightAlignedColumns() throws {
        let page = page(
            """
            Item          Cost
            Coffee           4
            Sandwich        12
            Cake             7
            """
        )

        let text = try XCTUnwrap(
            TableLayout.textWithTables(lines: page.lines, fragments: page.fragments)
        )
        XCTAssertTrue(text.contains("| Sandwich | 12 |"), text)
    }

    /// A four-column table with a wide line under it can also be read as a
    /// two-column table five rows tall. The wider reading wins, and the line
    /// stays a line.
    func testPrefersTheWiderReadingOverTheTallerOne() throws {
        let page = page(
            """
            Item      Qty       Cost      Total
            Coffee    2         4         8
            Tea       3         3         9
            Cake      1         7         7
            Note      see the receipt for details
            """
        )

        let text = try XCTUnwrap(
            TableLayout.textWithTables(lines: page.lines, fragments: page.fragments)
        )
        XCTAssertEqual(
            text,
            """
            | Item | Qty | Cost | Total |
            | --- | --- | --- | --- |
            | Coffee | 2 | 4 | 8 |
            | Tea | 3 | 3 | 9 |
            | Cake | 1 | 7 | 7 |

            Note see the receipt for details
            """
        )
    }

    /// A documentation table whose cells wrap: the row for `StreamSyncAgent`
    /// occupies four bands of words, three of which hold only the tail of the
    /// middle column. Read band by band this is mostly empty cells and fails
    /// the fill rule; read as the two rows it is, it is a table.
    func testJoinsWrappedCellsIntoOneRow() throws {
        let page = page(
            """
            Layer             Role                                            Stack
            StreamSyncAgent   Backend AI agent that automates stream          Python, SQLite,
                              operations - chat management, overlay           Redis, OpenAI
                              triggers, milestone tracking, sponsor           APIs
                              enforcement, reminders, cron jobs.
            Streamz           Public-facing metaprofile where creators        Next.js 15,
                              curate social links, collections,               React 19,
                              feeds, Web3 badges, and monetize through        TypeScript
                              affiliate links and referrals.
            """
        )

        let text = try XCTUnwrap(
            TableLayout.textWithTables(lines: page.lines, fragments: page.fragments)
        )
        XCTAssertEqual(
            text,
            """
            | Layer | Role | Stack |
            | --- | --- | --- |
            | StreamSyncAgent | Backend AI agent that automates stream operations - chat management, \
            overlay triggers, milestone tracking, sponsor enforcement, reminders, cron jobs. \
            | Python, SQLite, Redis, OpenAI APIs |
            | Streamz | Public-facing metaprofile where creators curate social links, collections, \
            feeds, Web3 badges, and monetize through affiliate links and referrals. \
            | Next.js 15, React 19, TypeScript |
            """
        )
    }

    // MARK: - Rejection

    /// Joining wrapped cells cannot buy the row count: four bands that are
    /// really two rows are two rows, and two rows is not a table.
    func testWrappedBandsDoNotCountTowardTheRowMinimum() {
        let page = page(
            """
            Region    Q3        Q4
            North     1,204     1,881
                      revised   final
                      again     twice
            """
        )

        XCTAssertNil(TableLayout.textWithTables(lines: page.lines, fragments: page.fragments))
    }

    func testProseIsNotATable() {
        let page = page(
            """
            The quick brown fox jumps over
            the lazy dog and then it turns
            around to look at what it did
            """
        )

        XCTAssertNil(TableLayout.textWithTables(lines: page.lines, fragments: page.fragments))
    }

    /// Two rows is a real table shape and is rejected anyway — a label over a
    /// value is indistinguishable from it.
    func testTwoRowsIsNotEnough() {
        let page = page(
            """
            Region    Q3        Q4
            North     1,204     1,881
            """
        )

        XCTAssertNil(TableLayout.textWithTables(lines: page.lines, fragments: page.fragments))
    }

    /// An indented block has a clear channel down its left, and one column
    /// beside it. Without the header-complete and fill rules this reads as a
    /// two-column table.
    func testIndentedTextIsNotATable() {
        let page = page(
            """
            Note      see below
            More
            Text
            Lines
            """
        )

        XCTAssertNil(TableLayout.textWithTables(lines: page.lines, fragments: page.fragments))
    }

    /// A numbered list whose items wrap clears every other rule: the markers
    /// leave a channel down the left, and the wrapped lines fold into their
    /// item. It is still a list, and `| 1. | Install the package… |` is a
    /// worse reading of the page than the lines themselves.
    func testAWrappedNumberedListIsNotATable() {
        let page = page(
            """
            1.   Install the package with brew and
                 then open the app for the first
                 time to grant permissions.
            2.   Copy something anywhere in macOS
                 and it appears in the panel
                 immediately.
            3.   Press shift command V to open it.
            """
        )
        XCTAssertNil(TableLayout.textWithTables(lines: page.lines, fragments: page.fragments))
    }

    /// The same list wrapped to two lines an item, which passed the fill and
    /// coverage rules on its own and became a table with empty first cells.
    func testAListThatWrapsOnceIsNotATableEither() {
        let page = page(
            """
            1.   Install the package with brew and
                 open the app to grant permissions.
            2.   Copy something anywhere in macOS
                 and it appears in the panel.
            3.   Press shift command V to open it.
            """
        )
        XCTAssertNil(TableLayout.textWithTables(lines: page.lines, fragments: page.fragments))
    }

    func testListMarkersAreToldFromValues() {
        for marker in ["1.", "2)", "(3", "a.", "iv.", "•", "-", "*", "10."] {
            XCTAssertTrue(TableLayout.isListMarker(marker), "\(marker) should read as a list marker")
        }
        // A rank column headed `#`, two-letter country codes, and anything
        // long enough to be content.
        for value in ["#", "US", "FR", "Q3", "Region", "1,204", "", "N/A"] {
            XCTAssertFalse(TableLayout.isListMarker(value), "\(value) should read as a value")
        }
    }

    func testEmptyInputIsNotATable() {
        XCTAssertNil(TableLayout.textWithTables(lines: [], fragments: []))
    }

    // MARK: - Rows

    func testRowGroupingUsesVerticalCentres() {
        let fragments = [
            fragment("a", x: 0, y: 0.10),
            fragment("b", x: 0.5, y: 0.104),
            fragment("c", x: 0, y: 0.30),
        ]
        let rows = TableLayout.rows(from: fragments, medianHeight: 0.02)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.fragments.map(\.text), ["a", "b"])
        XCTAssertEqual(rows.last?.fragments.map(\.text), ["c"])
    }

    // MARK: - Helpers

    private func fragment(_ text: String, x: CGFloat, y: CGFloat) -> TextFragment {
        TextFragment(
            text: text,
            rect: CGRect(x: x, y: y, width: CGFloat(text.count) * 0.01, height: 0.02),
            lineIndex: 0
        )
    }

    /// One character of the block is one `charWidth` of page width, one line
    /// is one `lineStep` down. Runs of non-space characters become words, and
    /// each input line becomes one recognized line.
    private func page(_ block: String) -> (lines: [String], fragments: [TextFragment]) {
        let charWidth: CGFloat = 0.01
        let lineHeight: CGFloat = 0.02
        let lineStep: CGFloat = 0.05

        var lines: [String] = []
        var fragments: [TextFragment] = []
        for (row, raw) in block.components(separatedBy: "\n").enumerated() {
            let characters = Array(raw)
            var words: [(text: String, column: Int)] = []
            var index = 0
            while index < characters.count {
                guard characters[index] != " " else {
                    index += 1
                    continue
                }
                let start = index
                var word = ""
                while index < characters.count, characters[index] != " " {
                    word.append(characters[index])
                    index += 1
                }
                words.append((word, start))
            }
            guard !words.isEmpty else { continue }

            lines.append(words.map(\.text).joined(separator: " "))
            let lineIndex = lines.count - 1
            for word in words {
                fragments.append(
                    TextFragment(
                        text: word.text,
                        rect: CGRect(
                            x: CGFloat(word.column) * charWidth,
                            y: CGFloat(row) * lineStep,
                            width: CGFloat(word.text.count) * charWidth,
                            height: lineHeight
                        ),
                        lineIndex: lineIndex
                    )
                )
            }
        }
        return (lines, fragments)
    }
}
