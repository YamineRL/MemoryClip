import CoreGraphics
import Foundation

/// One recognized word and the box it occupied on the page.
struct TextFragment: Sendable, Equatable {
    var text: String
    /// Normalized to the image, TOP-left origin, y growing downward — reading
    /// order rather than Vision's bottom-left convention. `OCRService` flips
    /// it once at the boundary so nothing below has to think about it.
    var rect: CGRect
    /// Which recognized line the word came from. Lines are the unit the
    /// non-table output is written in, so a table is only allowed to consume
    /// whole ones — see `consumesWholeLines`.
    var lineIndex: Int
}

/// Recovering tables from where the words sat on the page.
///
/// # Why this exists
///
/// Vision reports lines of text in reading order and nothing about structure,
/// so a screenshot of a table arrives as `joinedText` output that reads:
///
///     Region Q3 Q4
///     North 1,204 1,881
///     South 990 1,140
///
/// which is not a table, is not searchable as one, and pasted into a note is
/// three lines of numbers whose columns the reader has to guess. The columns
/// were never in the text — they were in the geometry, and the geometry is
/// right there in the observations.
///
/// # The method
///
/// Words are grouped into rows by vertical position, then columns are found
/// by **whitespace projection**: an x-interval that no word in any row of the
/// run overlaps is a gutter, and the gutters are the column separators. This
/// is why the detector does not need to know whether a column is left-,
/// right- or centre-aligned, and why it does not fire on prose — a paragraph
/// has no vertical channel running clear through it, because the word gaps on
/// one line sit over letters on the next.
///
/// # The bias
///
/// A missed table costs the old flat text, which is what the app produced
/// before this file existed. A false table reorders the user's only copy of
/// what was on screen. So every threshold here is set to reject: three rows
/// minimum, a complete header row, and most cells filled. Text that does not
/// clear all of them is returned untouched.
enum TableLayout {
    // MARK: - Thresholds

    /// Header plus two data rows. Two rows is a real table and this rejects
    /// it on purpose: a label above a value, an icon beside a caption, and
    /// any two-line fragment with a consistent indent all look exactly like
    /// a two-row table, and there is no signal left to separate them.
    static let minimumRows = 3

    /// A single column is just text.
    static let minimumColumns = 2

    /// How wide a clear vertical channel has to be, in median character
    /// widths, before it counts as a column separator rather than a space.
    ///
    /// One character width is the gap between two ordinary words, so the
    /// threshold has to sit above it; typeset tables leave far more. Two is
    /// the smallest value that never fired on the inter-word gaps of the
    /// prose samples, measured against the same screenshots the OCR
    /// benchmarks use.
    static let gutterCharacterWidths: CGFloat = 2

    /// The share of cells that must carry text. A grid of mostly-empty cells
    /// is scattered words that happened to line up, not a table.
    static let minimumFillRatio = 0.75

    /// The share of rows in which a given column must carry text. Catches the
    /// column that exists only because two words on two rows left a channel.
    static let minimumColumnCoverage = 0.6

    /// Rows are grouped by comparing centres against this multiple of the
    /// median word height. Below half a line the grouping splits rows that
    /// merely differ in font size; much above it, tightly-set rows merge.
    static let rowToleranceHeights: CGFloat = 0.6

    /// Detection is skipped above this many rows or words. The search is
    /// quadratic in rows, and a screenshot with hundreds of lines of text on
    /// it is a wall of prose, not a table worth the scan.
    static let maximumRows = 200
    static let maximumFragments = 4000

    // MARK: - Entry point

    /// `lines` with any tables among them replaced by Markdown tables.
    ///
    /// Returns nil when nothing table-shaped was found — the caller then
    /// keeps the text it already had, byte for byte. That is the contract
    /// that makes this safe to run on every image: a screenshot with no table
    /// in it is not merely unharmed, it takes a path that cannot alter it.
    ///
    /// - Parameters:
    ///   - lines: the recognized lines, in reading order, as the flat output
    ///     would have emitted them.
    ///   - fragments: the words of those lines, each carrying its `lineIndex`
    ///     into `lines`.
    static func textWithTables(lines: [String], fragments: [TextFragment]) -> String? {
        guard lines.count >= minimumRows else { return nil }
        guard !fragments.isEmpty, fragments.count <= maximumFragments else { return nil }

        let heights = fragments.map(\.rect.height).sorted()
        let medianHeight = heights[heights.count / 2]
        guard medianHeight > 0 else { return nil }
        guard let characterWidth = medianCharacterWidth(fragments) else { return nil }

        let rows = rows(from: fragments, medianHeight: medianHeight)
        guard rows.count >= minimumRows, rows.count <= maximumRows else { return nil }

        var lineTotals: [Int: Int] = [:]
        for fragment in fragments { lineTotals[fragment.lineIndex, default: 0] += 1 }

        let found = tables(
            in: rows,
            gutterWidth: gutterCharacterWidths * characterWidth,
            lineTotals: lineTotals
        )
        guard !found.isEmpty else { return nil }
        return render(lines: lines, tables: found)
    }

    // MARK: - Rows

    /// A band of words sharing a baseline.
    struct Row: Equatable {
        var fragments: [TextFragment]
        /// Running mean of the members' vertical centres.
        var centerY: CGFloat
    }

    /// Group words into rows by vertical centre, top to bottom.
    ///
    /// The tolerance comes from the median word height across the whole
    /// image rather than from the row being built: a row-local measure
    /// shrinks to whichever member has the smallest box — a comma, a `.`, a
    /// superscript — and then rejects the rest of its own row.
    static func rows(from fragments: [TextFragment], medianHeight: CGFloat) -> [Row] {
        let tolerance = rowToleranceHeights * medianHeight
        var rows: [Row] = []
        for fragment in fragments.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            let center = fragment.rect.midY
            if var last = rows.last, abs(center - last.centerY) <= tolerance {
                let count = CGFloat(last.fragments.count)
                last.centerY = (last.centerY * count + center) / (count + 1)
                last.fragments.append(fragment)
                rows[rows.count - 1] = last
            } else {
                rows.append(Row(fragments: [fragment], centerY: center))
            }
        }
        for index in rows.indices {
            rows[index].fragments.sort { $0.rect.minX < $1.rect.minX }
        }
        return rows
    }

    /// Median width of one character, used as the unit for gutter width.
    ///
    /// Measured per word and divided by its character count, so it is a
    /// property of the type on the page rather than of the image's aspect
    /// ratio — normalized coordinates squash x and y by different amounts,
    /// and comparing an x-distance against a y-height would make the
    /// threshold depend on how wide the screenshot happened to be.
    ///
    /// Single-character words are skipped: their box is one glyph plus the
    /// side bearings, which over-reads the width badly for `I` or `1`.
    static func medianCharacterWidth(_ fragments: [TextFragment]) -> CGFloat? {
        let widths = fragments.compactMap { fragment -> CGFloat? in
            let count = fragment.text.count
            guard count >= 2, fragment.rect.width > 0 else { return nil }
            return fragment.rect.width / CGFloat(count)
        }.sorted()
        guard !widths.isEmpty else { return nil }
        let median = widths[widths.count / 2]
        return median > 0 ? median : nil
    }

    // MARK: - Columns

    /// The x-intervals covered by a run of rows, coalesced and sorted.
    ///
    /// Grown one row at a time by `merged(_:adding:)` rather than rebuilt per
    /// candidate: the search extends a run row by row, and rebuilding would
    /// make it quadratic in words as well as in rows.
    static func merged(_ intervals: [(min: CGFloat, max: CGFloat)], adding row: Row) -> [(min: CGFloat, max: CGFloat)] {
        let incoming = row.fragments.map { (min: $0.rect.minX, max: $0.rect.maxX) }
        var out: [(min: CGFloat, max: CGFloat)] = []
        out.reserveCapacity(intervals.count + incoming.count)

        var left = 0
        var right = 0
        while left < intervals.count || right < incoming.count {
            let next: (min: CGFloat, max: CGFloat)
            if right >= incoming.count || (left < intervals.count && intervals[left].min <= incoming[right].min) {
                next = intervals[left]
                left += 1
            } else {
                next = incoming[right]
                right += 1
            }
            if var last = out.last, next.min <= last.max {
                last.max = max(last.max, next.max)
                out[out.count - 1] = last
            } else {
                out.append(next)
            }
        }
        return out
    }

    /// The mid-points of the clear vertical channels between `intervals`.
    ///
    /// One boundary per gutter, so a run with two gutters has three columns.
    static func boundaries(between intervals: [(min: CGFloat, max: CGFloat)], gutterWidth: CGFloat) -> [CGFloat] {
        var out: [CGFloat] = []
        for index in 1..<max(intervals.count, 1) where intervals[index].min - intervals[index - 1].max > gutterWidth {
            out.append((intervals[index - 1].max + intervals[index].min) / 2)
        }
        return out
    }

    /// The cells of `rows`, split at `boundaries`.
    ///
    /// A word belongs to the column its centre falls in, so a value that
    /// slightly overhangs its column — a wide header over narrow numbers —
    /// still lands where a reader would put it.
    static func grid(rows: ArraySlice<Row>, boundaries: [CGFloat]) -> [[String]] {
        rows.map { row in
            var cells = [String](repeating: "", count: boundaries.count + 1)
            for fragment in row.fragments {
                var column = 0
                while column < boundaries.count, fragment.rect.midX > boundaries[column] { column += 1 }
                cells[column] = cells[column].isEmpty ? fragment.text : cells[column] + " " + fragment.text
            }
            return cells
        }
    }

    /// `grid` with every band of words that continues the band above it folded
    /// into it, cells joined with a space — the rows a reader would count.
    ///
    /// A cell too long for its column wraps, and each wrapped line is its own
    /// band of words on the page — so one logical row of a documentation table
    /// arrives here as six rows, five of them holding nothing but the tail of
    /// the middle column. Judged as they arrive, those five are mostly empty
    /// cells, which is precisely what the fill and coverage rules are built to
    /// throw out, and the table is lost. Worse, the tails line up with each
    /// other: the rows below the first one have a complete "header" and a
    /// clear channel of their own, so the search settles on them and prints a
    /// two-column table made entirely of sentence fragments. The rows have to
    /// be put back together before anything judges them.
    ///
    /// The cue is an empty first column. A table is read left to right and the
    /// first column is what names the row — the key, the label, the region —
    /// so a band that does not open one did not start a row.
    ///
    /// Two other cues were considered:
    ///
    /// - Anchoring on whichever column carries text in the most rows. On the
    ///   screenshot this was written for that is the wrapped column itself:
    ///   the description is present on every band exactly because it is the
    ///   one that overflows. Anchoring there merges nothing.
    /// - Comparing vertical gaps, the step between logical rows against the
    ///   step between wrapped lines inside a cell. In a bordered table with
    ///   ordinary cell padding those two differ by a few points, which is
    ///   inside the spread of Vision's box heights, and in a table whose rows
    ///   are each one line tall there is no second population to measure
    ///   against at all.
    ///
    /// What this leaves is the table whose *first* column wraps: the second
    /// line of that cell opens a first column and so starts a logical row that
    /// should not exist. That splits one row in two rather than joining two
    /// into one, which pushes the fill ratio down, not up — the run is
    /// rejected the way it is today. Failing back to the old behaviour is the
    /// point: nothing here is allowed to buy a table by lowering a threshold.
    static func logicalRows(_ grid: [[String]]) -> [[String]] {
        var out: [[String]] = []
        for row in grid {
            guard row.first?.isEmpty == true, var last = out.last else {
                out.append(row)
                continue
            }
            for column in row.indices where !row[column].isEmpty {
                last[column] = last[column].isEmpty ? row[column] : last[column] + " " + row[column]
            }
            out[out.count - 1] = last
        }
        return out
    }

    /// Whether a grid is worth calling a table. See the thresholds above for
    /// why each of these is set where it is.
    static func isTable(_ grid: [[String]]) -> Bool {
        guard grid.count >= minimumRows, let columns = grid.first?.count, columns >= minimumColumns else {
            return false
        }
        // A complete header is required for two reasons: Markdown has no
        // headerless table, and a partial first row is the tell that the run
        // started one line too early — on a caption or a section title that
        // happens to sit above the table.
        guard grid[0].allSatisfy({ !$0.isEmpty }) else { return false }
        // A first column of nothing but list markers is a list, not a table.
        // A numbered or bulleted list whose items wrap clears every other rule
        // here — the markers leave a channel down the left that runs the whole
        // height, the wrapped lines fold into their item, and what comes out is
        // a two-column table whose header is "1.". The list is the more
        // faithful reading of the page, and it is what the flat text already
        // gives, so this hands it back rather than inventing columns for it.
        guard !grid.allSatisfy({ isListMarker($0[0]) }) else { return false }

        let filled = grid.reduce(0) { $0 + $1.count(where: { !$0.isEmpty }) }
        guard Double(filled) >= minimumFillRatio * Double(grid.count * columns) else { return false }

        for column in 0..<columns {
            let present = grid.count(where: { !$0[column].isEmpty })
            guard Double(present) >= minimumColumnCoverage * Double(grid.count) else { return false }
        }
        return true
    }

    /// Bullets a list item can begin with, the plain hyphen among them.
    ///
    /// The hyphen looks dangerous — a table cell of `-` meaning "none" is
    /// ordinary — but it only matters when EVERY cell of the first column is
    /// one, header included, and a table whose entire first column reads `-`
    /// has no first column. Against that, `- item` is the commonest bullet
    /// there is, so leaving it out would miss the lists most worth declining.
    /// A rank column headed `#` is deliberately not in here.
    static let listBullets: Set<Character> = ["-", "–", "—", "•", "·", "‣", "▪", "◦", "*"]

    /// Whether a cell is a list marker rather than a value: `•`, `-`, `1.`,
    /// `2)`, `(3`, `a.`, `iv.`.
    ///
    /// Length-capped because the point is a mark that introduces an item, and
    /// anything longer is content.
    static func isListMarker(_ cell: String) -> Bool {
        guard !cell.isEmpty, cell.count <= 5 else { return false }
        if cell.count == 1, let character = cell.first, listBullets.contains(character) { return true }

        var body = Substring(cell)
        if body.first == "(" { body = body.dropFirst() }
        if let last = body.last, last == "." || last == ")" { body = body.dropLast() }
        guard !body.isEmpty else { return false }
        if body.allSatisfy(\.isNumber) { return true }
        // `a.` and `iv.` — an enumerator, not a word. Two letters at most, so
        // a first column of two-letter codes ("US", "FR") is not mistaken for
        // one.
        return body.count <= 2 && body.allSatisfy { $0.isLetter && $0.isLowercase }
    }

    // MARK: - Search

    /// A table found in the page, and the lines it accounts for.
    struct Found: Equatable {
        var table: MarkdownTable
        /// Indices into the caller's `lines`, all of them fully inside the
        /// table.
        var lineIndices: Set<Int>
        /// Where the table is emitted — the first line it replaces.
        var firstLine: Int
    }

    /// Every table in the page, left to right, top to bottom.
    ///
    /// For each starting row the run is extended downward one row at a time.
    /// Adding a row can only ever cover more of the x-axis, so the column
    /// count is monotonically non-increasing as the run grows — which is what
    /// makes this cheap: the only candidates worth scoring are the longest
    /// run at each distinct column count, and there are at most as many of
    /// those as the first pair of rows had columns.
    ///
    /// Among those candidates the widest-and-tallest wins (`rows × columns`),
    /// so a four-column table that could be read as a two-column one by
    /// swallowing the paragraph beneath it is read as four.
    static func tables(
        in rows: [Row],
        gutterWidth: CGFloat,
        lineTotals: [Int: Int]
    ) -> [Found] {
        var found: [Found] = []
        var start = 0

        while start + minimumRows <= rows.count {
            var intervals: [(min: CGFloat, max: CGFloat)] = []
            var candidates: [(end: Int, boundaries: [CGFloat])] = []
            var previous: [CGFloat]?
            var end = start

            while end < rows.count {
                intervals = merged(intervals, adding: rows[end])
                let current = boundaries(between: intervals, gutterWidth: gutterWidth)
                if current.count + 1 < minimumColumns {
                    // The run has collapsed to a single column, and no row
                    // below can open a gutter back up.
                    if let previous { candidates.append((end: end - 1, boundaries: previous)) }
                    previous = nil
                    break
                }
                if let previous, previous.count != current.count {
                    candidates.append((end: end - 1, boundaries: previous))
                }
                previous = current
                end += 1
            }
            if let previous { candidates.append((end: end - 1, boundaries: previous)) }

            // Widest-and-tallest first, and on down: a candidate can still
            // fail the fill and whole-line rules, and the next one is a
            // genuinely different reading of the same rows rather than a
            // consolation prize. Height here counts bands of words, which is
            // only a lower bound on rows once wrapped cells are joined — the
            // real row count is checked against `minimumRows` in `isTable`,
            // after the join.
            let ranked = candidates
                .filter { $0.end - start + 1 >= minimumRows }
                .sorted { lhs, rhs in
                    (lhs.end - start + 1) * (lhs.boundaries.count + 1)
                        > (rhs.end - start + 1) * (rhs.boundaries.count + 1)
                }

            var accepted: Found?
            for candidate in ranked {
                if let table = table(
                    rows: rows[start...candidate.end],
                    boundaries: candidate.boundaries,
                    lineTotals: lineTotals
                ) {
                    accepted = table
                    start = candidate.end + 1
                    break
                }
            }
            if let accepted {
                found.append(accepted)
            } else {
                start += 1
            }
        }
        return found
    }

    /// Build and validate the table for one run of rows.
    ///
    /// The bands of words are joined into logical rows first — see
    /// `logicalRows` — because a wrapped cell arrives as several bands
    /// and the fill and coverage rules are only meaningful against the rows a
    /// reader would count.
    ///
    /// Rejects a run that owns only part of a recognized line. The output
    /// keeps Vision's line order and swaps whole lines for the table, so a
    /// half-consumed line would either lose its remaining words or print them
    /// twice — and a line straddling the edge of a table is a sign the row
    /// grouping got it wrong anyway.
    static func table(
        rows: ArraySlice<Row>,
        boundaries: [CGFloat],
        lineTotals: [Int: Int]
    ) -> Found? {
        let cells = logicalRows(grid(rows: rows, boundaries: boundaries))
        guard isTable(cells) else { return nil }

        var counts: [Int: Int] = [:]
        for row in rows {
            for fragment in row.fragments { counts[fragment.lineIndex, default: 0] += 1 }
        }
        for (line, count) in counts where lineTotals[line] != count { return nil }
        guard let firstLine = counts.keys.min() else { return nil }

        return Found(
            table: MarkdownTable(header: cells[0], rows: Array(cells.dropFirst())),
            lineIndices: Set(counts.keys),
            firstLine: firstLine
        )
    }

    // MARK: - Rendering

    /// Emit the page: recognized lines in their original order, with each
    /// table printed once, in place of the first line it replaced.
    ///
    /// Tables are surrounded by blank lines because a Markdown table butted
    /// against a paragraph does not render as a table in most readers —
    /// including Obsidian, which is where these notes go.
    static func render(lines: [String], tables: [Found]) -> String {
        var startsAt: [Int: MarkdownTable] = [:]
        var consumed: Set<Int> = []
        for found in tables {
            startsAt[found.firstLine] = found.table
            consumed.formUnion(found.lineIndices)
        }

        var out: [String] = []
        for (index, line) in lines.enumerated() {
            if let table = startsAt[index] {
                if let last = out.last, !last.isEmpty { out.append("") }
                out.append(table.markdown)
                out.append("")
                continue
            }
            guard !consumed.contains(index) else { continue }
            out.append(line)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }
}
