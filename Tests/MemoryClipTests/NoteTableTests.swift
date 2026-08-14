import XCTest

@testable import MemoryClip

/// The two consumers that need structure rather than text: Apple Notes, whose
/// body is HTML, and the guard that decides whether a model's rewrite may
/// replace the recognition.
final class TableConsumerTests: XCTestCase {
    private func draft(body: String) -> NoteDraft {
        NoteDraft(
            clipUUID: UUID(),
            title: "Revenue",
            body: body,
            createdAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
    }

    func testAppleNotesGetsARealTable() {
        let html = NoteComposer.html(
            for: draft(
                body: """
                Quarterly revenue

                | Region | Q3 |
                | --- | --- |
                | North | 1,204 |
                """
            )
        )

        XCTAssertTrue(html.contains("<p>Quarterly revenue</p>"), html)
        XCTAssertTrue(html.contains("<th>Region</th><th>Q3</th>"), html)
        XCTAssertTrue(html.contains("<td>North</td><td>1,204</td>"), html)
        XCTAssertFalse(html.contains("| --- |"), "Pipes should not survive into Notes: \(html)")
    }

    func testTableCellsAreStillHTMLEscaped() {
        let html = NoteComposer.html(
            for: draft(body: "| a | b |\n| --- | --- |\n| <script> | AT&T |")
        )
        XCTAssertTrue(html.contains("<td>&lt;script&gt;</td>"), html)
        XCTAssertTrue(html.contains("<td>AT&amp;T</td>"), html)
    }

    func testMarkdownNotesCarryTheTableThrough() {
        let table = "| Region | Q3 |\n| --- | --- |\n| North | 1,204 |"
        XCTAssertTrue(NoteComposer.markdown(for: draft(body: table)).contains(table))
        XCTAssertTrue(NoteComposer.plainText(for: draft(body: table)).contains(table))
    }

    // MARK: - Guard

    private let raw = """
        Revenue by region

        | Region | Q3 |
        | --- | --- |
        | North | 1,204 |
        | South | 990 |
        """

    func testGuardRejectsARewriteThatFlattensATable() {
        let flattened = """
            Revenue by region. Region Q3, North 1,204, South 990.
            """
        XCTAssertFalse(RefinementGuard.preservesTables(cleaned: flattened, raw: raw))
        XCTAssertFalse(RefinementGuard.isPlausible(cleaned: flattened, raw: raw))
    }

    func testGuardRejectsARewriteThatDropsARow() {
        let shortened = """
            Revenue by region

            | Region | Q3 |
            | --- | --- |
            | North | 1,204 |
            """
        XCTAssertFalse(RefinementGuard.preservesTables(cleaned: shortened, raw: raw))
    }

    /// Fixing OCR damage inside a cell is the reason the model runs at all.
    func testGuardAcceptsCellLevelRepairs() {
        let repaired = raw.replacingOccurrences(of: "1,204", with: "1,264")
        XCTAssertTrue(RefinementGuard.preservesTables(cleaned: repaired, raw: raw))
        XCTAssertTrue(RefinementGuard.isPlausible(cleaned: repaired, raw: raw))
    }

    func testGuardIgnoresTextWithNoTable() {
        XCTAssertTrue(RefinementGuard.preservesTables(cleaned: "anything", raw: "no tables here"))
    }
}
