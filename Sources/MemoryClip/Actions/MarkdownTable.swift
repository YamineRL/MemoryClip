import Foundation

/// A table, in the one shape every part of the app agrees on.
///
/// OCR produces these from the geometry of a screenshot (`TableLayout`), and
/// they are stored the way everything else recognized is stored: as text, in
/// `ClipItem.ocrText`, spelled as a GitHub-flavoured Markdown table. That is
/// deliberate — a table has to survive search, export, the Markdown vault, the
/// pasteboard and a user who opens the note in TextEdit in five years, and a
/// string is the only representation all of those already handle.
///
/// So this type is not a storage format. It is the parse of one, used at the
/// two ends that want structure rather than text: the preview pane, which
/// draws a real grid, and the Apple Notes sink, which needs `<table>` markup
/// because pipes in a `<p>` are just pipes.
struct MarkdownTable: Equatable, Sendable {
    /// The first row. Markdown has no headerless table, so this is never
    /// empty for a table that round-trips.
    var header: [String]
    /// The data rows, each padded or truncated to `header.count` by the
    /// parser so consumers can index columns without bounds-checking.
    var rows: [[String]]

    var columnCount: Int { header.count }

    /// The table as GitHub-flavoured Markdown, with the alignment row every
    /// renderer requires between the header and the body.
    var markdown: String {
        var lines = [Self.row(header)]
        lines.append(Self.row(Array(repeating: "---", count: header.count)))
        for row in rows {
            lines.append(Self.row(Self.fitted(row, to: header.count)))
        }
        return lines.joined(separator: "\n")
    }

    private static func row(_ cells: [String]) -> String {
        "| " + cells.map(escaped).joined(separator: " | ") + " |"
    }

    /// A cell that cannot break out of its column.
    ///
    /// `|` is the only character that can — it would end the cell early and
    /// shift every value after it one column left, which for OCR of a table
    /// of numbers produces a table that is wrong rather than one that looks
    /// broken. Newlines and tabs collapse to spaces for the same reason: a
    /// Markdown table row is one line by definition.
    static func escaped(_ cell: String) -> String {
        var out = ""
        for character in cell {
            switch character {
            case "|": out += "\\|"
            case "\n", "\r", "\t": out += " "
            default: out.append(character)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// `row` at exactly `count` cells — padded with empties, never dropped
    /// silently past the end.
    static func fitted(_ row: [String], to count: Int) -> [String] {
        if row.count == count { return row }
        if row.count > count {
            // Fold the overflow into the last column rather than discarding
            // it: a cell that picked up a stray word is readable, a value
            // that vanished is not.
            var out = Array(row.prefix(count))
            let overflow = row.dropFirst(count).joined(separator: " ")
            if !overflow.isEmpty {
                out[count - 1] = out[count - 1].isEmpty ? overflow : out[count - 1] + " " + overflow
            }
            return out
        }
        return row + Array(repeating: "", count: count - row.count)
    }
}

/// A run of text, split at the tables inside it.
enum MarkdownBlock: Equatable, Sendable {
    case text(String)
    case table(MarkdownTable)
}

extension MarkdownTable {
    // MARK: - Parsing

    /// Split `text` into plain runs and the Markdown tables between them.
    ///
    /// Always returns something: text with no table in it comes back as a
    /// single `.text` block holding the input unchanged, so a caller can
    /// route everything through here without first asking whether it needs
    /// to.
    static func blocks(in text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var buffer: [String] = []
        var index = 0

        func flushText() {
            guard !buffer.isEmpty else { return }
            blocks.append(.text(buffer.joined(separator: "\n")))
            buffer.removeAll()
        }

        while index < lines.count {
            if let (table, next) = table(in: lines, startingAt: index) {
                flushText()
                blocks.append(.table(table))
                index = next
                continue
            }
            buffer.append(lines[index])
            index += 1
        }
        flushText()
        return blocks
    }

    /// Every table in `text`, in order. The shorthand for callers that only
    /// care whether tables are there and how many rows they carry.
    static func tables(in text: String) -> [MarkdownTable] {
        blocks(in: text).compactMap {
            if case .table(let table) = $0 { return table }
            return nil
        }
    }

    /// The table beginning at `start`, and the line index just past it.
    ///
    /// Requires a header, an alignment row of matching width, and at least
    /// one data row. The width match is what keeps ordinary prose out: a line
    /// of text with a pipe in it followed by a line of dashes is not a table
    /// unless the two agree on how many columns they have.
    private static func table(
        in lines: [String],
        startingAt start: Int
    ) -> (MarkdownTable, Int)? {
        guard start + 2 < lines.count else { return nil }
        guard let header = cells(in: lines[start]) else { return nil }
        guard let delimiter = cells(in: lines[start + 1]),
              delimiter.count == header.count,
              delimiter.allSatisfy(isAlignmentCell)
        else { return nil }

        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count,
              let row = cells(in: lines[index]),
              !row.allSatisfy(isAlignmentCell) {
            rows.append(fitted(row, to: header.count))
            index += 1
        }
        guard !rows.isEmpty else { return nil }
        return (MarkdownTable(header: header, rows: rows), index)
    }

    /// The cells of one table row, or nil when the line is not one.
    ///
    /// Splits on unescaped pipes only, so a cell holding a literal `|` — which
    /// `escaped` wrote as `\|` — comes back whole.
    static func cells(in line: String) -> [String]? {
        var cells: [String] = []
        var current = ""
        var escaping = false
        var sawPipe = false
        for character in line {
            if escaping {
                // Only `\|` is an escape here; anything else keeps its
                // backslash, because OCR of a Windows path or a regex is full
                // of backslashes that mean themselves.
                if character != "|" { current.append("\\") }
                current.append(character)
                escaping = false
                continue
            }
            switch character {
            case "\\": escaping = true
            case "|":
                sawPipe = true
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default: current.append(character)
            }
        }
        if escaping { current.append("\\") }
        guard sawPipe else { return nil }
        cells.append(current.trimmingCharacters(in: .whitespaces))

        // `| a | b |` splits to ["", "a", "b", ""] — the leading and trailing
        // pipes are delimiters, not empty first and last columns.
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    /// `---`, `:--`, `--:`, `:-:` — the alignment row's vocabulary.
    private static func isAlignmentCell(_ cell: String) -> Bool {
        var body = Substring(cell)
        guard !body.isEmpty else { return false }
        if body.first == ":" { body = body.dropFirst() }
        if body.last == ":" { body = body.dropLast() }
        return !body.isEmpty && body.allSatisfy { $0 == "-" }
    }
}
