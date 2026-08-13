import Foundation

/// Turns a `NoteDraft` into the three text forms the sinks need, and works out
/// what to call the file.
///
/// Pure functions only — no filesystem, no AppKit, no `Process`. Same contract
/// as `ExportService`, and for the same payoff: the parts that are easy to get
/// silently wrong (front-matter quoting, file-name sanitisation, collision
/// suffixes) are testable without a vault on disk, and the sinks above are
/// left with nothing but I/O.
///
/// The one non-obvious rule: everything here is a function of the draft alone,
/// so re-composing the same clip produces byte-identical output and the same
/// file name. `MarkdownVaultSink` leans on that for idempotency.
enum NoteComposer {
    // MARK: - Formatting constants

    /// Front matter timestamps, matching `ExportService`: whole-second UTC
    /// ISO 8601 (`2026-08-13T14:22:03Z`). Obsidian's Dataview and every other
    /// front-matter reader parse this; a localized date string is a value only
    /// a human can read back.
    ///
    /// Held as a `FormatStyle` rather than an `ISO8601DateFormatter` because
    /// the formatter is a non-`Sendable` class and cannot be a `static let` in
    /// Swift 6 without an unsafe opt-out.
    static let iso8601 = Date.ISO8601FormatStyle()

    /// APFS's hard limit on one path component. Names are measured against it
    /// in UTF-8 bytes, never characters — see `clampedToUTF8Bytes`.
    static let maxFileNameBytes = 255

    /// The budget a composed name gets. Deliberately well under
    /// `maxFileNameBytes`: a name also has to survive being copied to a FAT/
    /// exFAT-formatted external drive or synced through a service with its own
    /// limit, and a vault full of 250-byte names is unusable in a file dialog
    /// long before the filesystem objects.
    static let maxFileNameComponentBytes = 200

    /// Heading for the block carrying the untouched recognition.
    static let rawTextHeading = "Original text"

    /// Heading for the block carrying the English rendering.
    ///
    /// A function of the draft rather than a constant, because "Translation"
    /// alone does not say which direction it went: the note's body is the
    /// language the user photographed, and the reader has to be able to tell
    /// at a glance which of the two blocks is the machine's. Falls back to
    /// the bare noun when the source language was not identified.
    static func translationHeading(for draft: NoteDraft) -> String {
        guard let identifier = draft.sourceLanguage, !identifier.isEmpty else {
            return "English translation"
        }
        return "English translation from \(LanguageDetector.displayName(forIdentifier: identifier))"
    }

    /// The line under the translation heading, saying where it came from.
    static let translationNote = "Translated on this Mac. The text above is what was actually on screen."

    /// The translation to emit, when there is one worth emitting.
    static func translationToEmit(for draft: NoteDraft) -> String? {
        guard let translation = draft.translation else { return nil }
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed != draft.body.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return trimmed
    }

    // MARK: - Markdown

    /// The note as a Markdown document: YAML front matter, then the body.
    ///
    /// Shaped for Obsidian (front matter keys it indexes, `![[wikilink]]`
    /// embeds) but every part of it degrades to ordinary Markdown, because the
    /// promise of this destination is that the note is a file the user owns —
    /// including after they stop using Obsidian.
    static func markdown(for draft: NoteDraft) -> String {
        var out = "---\n"
        out += "title: \(yamlEscaped(singleLine(draft.title)))\n"
        out += "created: \(draft.createdAt.formatted(iso8601))\n"
        // Absent keys are omitted rather than emitted empty: `source: ""` is a
        // claim that the clip came from an app with no name, and a Dataview
        // query filtering on `source` would count it.
        if let app = draft.sourceAppName, !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += "source: \(yamlEscaped(singleLine(app)))\n"
        }
        if !draft.tags.isEmpty {
            out += "tags:\n"
            for tag in draft.tags {
                out += "  - \(yamlEscaped(singleLine(tag)))\n"
            }
        }
        if let language = draft.sourceLanguage, !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The language the note's BODY is in, not the translation's — a
            // vault query for `lang: ar` is asking "what did I capture in
            // Arabic", and the answer is the original text.
            out += "lang: \(yamlEscaped(singleLine(language)))\n"
        }
        out += "memoryclip-uuid: \(draft.clipUUID.uuidString)\n"
        // The ORIGINAL location, kept even when the image was copied into the
        // vault: it is the only way back to the full-resolution screenshot on
        // the Desktop, and the only evidence of where the copy came from.
        if let source = draft.sourceFileURL {
            out += "screenshot: \(yamlEscaped(source.path(percentEncoded: false)))\n"
        }
        out += "---\n\n"

        // An H1 as well as the front-matter title. Obsidian renders the file
        // name as the heading and this looks redundant there — but opened in
        // any editor that does not parse front matter (TextEdit, GitHub, `cat`)
        // the file would otherwise begin with a wall of `---` metadata and no
        // visible title at all.
        let title = singleLine(draft.title)
        if !title.isEmpty {
            out += "# \(escapedHeadingText(title))\n\n"
        }

        let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            // Blockquoted so the model's sentence is visibly not part of the
            // captured text.
            out += summary
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
            out += "\n\n"
        }

        if let embed = imageMarkdown(for: draft) {
            out += embed + "\n\n"
        }

        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            out += body + "\n"
        }

        if let translation = translationToEmit(for: draft) {
            // Above the raw-OCR block, not below it: the translation is the
            // part a reader who does not speak the language came here for,
            // whereas the raw recognition is provenance.
            out += "\n## \(escapedHeadingText(translationHeading(for: draft)))\n\n"
            out += "*\(translationNote)*\n\n"
            out += translation + "\n"
        }

        if let raw = rawTextToEmit(for: draft) {
            // The raw recognition always travels with the note. A 3B on-device
            // model rejoining wrapped lines and dropping UI chrome is a
            // convenience layer; it also hallucinates, and when it does, the
            // cleaned text is the only copy of what was on screen unless this
            // block exists. Screenshots get deleted — the note is the record.
            out += "\n## \(rawTextHeading)\n\n"
            out += draft.wasRefined
                ? "*Exactly as recognised, before the on-device model cleaned it up.*\n\n"
                : "*Exactly as recognised.*\n\n"
            out += raw + "\n"
        }

        return out
    }

    /// How the screenshot appears in the Markdown body, if at all.
    ///
    /// Two shapes, and the difference matters:
    ///
    /// - `![[name.png]]` — an Obsidian embed, which resolves by searching the
    ///   VAULT for that file name. It works only for a file that lives inside
    ///   the vault, which is precisely why `MarkdownVaultSink` copies the image
    ///   in and sets `attachmentFileName` before calling here.
    /// - `[Screenshot](file:///…)` — a plain link, used when the image was not
    ///   copied. An embed pointing outside the vault renders as broken-image
    ///   text in Obsidian, so a link that actually opens the file is the honest
    ///   fallback rather than a prettier embed that shows nothing.
    private static func imageMarkdown(for draft: NoteDraft) -> String? {
        if let name = draft.attachmentFileName, !name.isEmpty {
            return "![[\(name)]]"
        }
        guard let url = draft.sourceFileURL else { return nil }
        // `absoluteString` is already percent-encoded, so a path with spaces
        // does not truncate the link target at the first space.
        return "[Screenshot](\(url.absoluteString))"
    }

    /// The raw recognition, when it is worth emitting: present, non-empty, and
    /// not just a whitespace-variant of the body it would sit beneath.
    private static func rawTextToEmit(for draft: NoteDraft) -> String? {
        guard let raw = draft.rawText else { return nil }
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else { return nil }
        guard trimmedRaw != draft.body.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return trimmedRaw
    }

    // MARK: - HTML (Apple Notes)

    /// The note as HTML, for Apple Notes — whose AppleScript `body` property
    /// takes an HTML fragment, not plain text.
    ///
    /// Notes takes the first line of `body` as the note's title, so the `<h1>`
    /// leads deliberately. Everything interpolated is escaped: a captured
    /// screenshot legitimately contains `<`, `&` and quotes (it is often a
    /// screenshot OF code), and unescaped it would either vanish into a bogus
    /// tag or corrupt the note.
    static func html(for draft: NoteDraft) -> String {
        var out = ""
        let title = singleLine(draft.title)
        if !title.isEmpty {
            out += "<h1>\(htmlEscaped(title))</h1>\n"
        }

        let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            out += "<p><i>\(htmlParagraphBody(summary))</i></p>\n"
        }

        // Notes' `attachment` element is READ-ONLY in its scripting dictionary:
        // there is no way to put an image into a note over AppleScript, and
        // `<img src="file://…">` in the body is stripped on import. A link is
        // the only thing that survives — this is a limitation of Notes, not a
        // bug here.
        if let url = draft.sourceFileURL {
            out += "<p><a href=\"\(htmlEscaped(url.absoluteString))\">Screenshot</a></p>\n"
        }

        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            out += htmlParagraphs(body) + "\n"
        }

        if !draft.tags.isEmpty {
            let tags = draft.tags.map { htmlEscaped(singleLine($0)) }.joined(separator: ", ")
            out += "<p>Tags: \(tags)</p>\n"
        }
        if let app = draft.sourceAppName, !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += "<p>From: \(htmlEscaped(singleLine(app)))</p>\n"
        }

        if let translation = translationToEmit(for: draft) {
            out += "<h2>\(htmlEscaped(translationHeading(for: draft)))</h2>\n"
            out += "<p><i>\(htmlEscaped(translationNote))</i></p>\n"
            out += htmlParagraphs(translation) + "\n"
        }

        if let raw = rawTextToEmit(for: draft) {
            out += "<h2>\(htmlEscaped(rawTextHeading))</h2>\n"
            out += draft.wasRefined
                ? "<p><i>Exactly as recognised, before the on-device model cleaned it up.</i></p>\n"
                : "<p><i>Exactly as recognised.</i></p>\n"
            out += htmlParagraphs(raw) + "\n"
        }

        return out
    }

    /// Escape the five characters that change the meaning of an HTML fragment.
    ///
    /// `&` is replaced FIRST — doing it last would re-escape the ampersands
    /// this function just introduced, turning `<` into `&amp;lt;`, which the
    /// user then reads as literal text in their note.
    ///
    /// `'` is escaped as the numeric `&#39;` rather than `&apos;`: the named
    /// entity is HTML5-only and older parsers render it verbatim.
    static func htmlEscaped(_ value: String) -> String {
        var out = value.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&#39;")
        return out
    }

    /// Escaped text with single newlines preserved as `<br>` — HTML collapses
    /// them otherwise and a recognised list turns into one run-on line.
    private static func htmlParagraphBody(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { htmlEscaped(String($0)) }
            .joined(separator: "<br>")
    }

    /// Blank-line-separated blocks become `<p>` elements; single newlines
    /// inside a block become `<br>`.
    private static func htmlParagraphs(_ text: String) -> String {
        text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
            .map { "<p>\(htmlParagraphBody($0))</p>" }
            .joined(separator: "\n")
    }

    // MARK: - Plain text

    /// The note as plain text, for destinations that want prose rather than a
    /// document — no front matter, no markup, nothing a Shortcut would have to
    /// strip before pasting it somewhere.
    static func plainText(for draft: NoteDraft) -> String {
        var lines: [String] = []
        let title = singleLine(draft.title)
        if !title.isEmpty { lines.append(title) }

        let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { lines.append(contentsOf: ["", summary]) }

        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { lines.append(contentsOf: ["", body]) }

        if let translation = translationToEmit(for: draft) {
            lines.append(contentsOf: ["", translationHeading(for: draft), "", translation])
        }

        var footer: [String] = []
        if !draft.tags.isEmpty {
            footer.append("Tags: " + draft.tags.map(singleLine).joined(separator: ", "))
        }
        if let app = draft.sourceAppName, !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            footer.append("From: \(singleLine(app))")
        }
        if let url = draft.sourceFileURL {
            footer.append("Screenshot: \(url.path(percentEncoded: false))")
        }
        footer.append("Captured: \(draft.createdAt.formatted(iso8601))")
        lines.append("")
        lines.append(contentsOf: footer)

        if let raw = rawTextToEmit(for: draft) {
            lines.append(contentsOf: ["", rawTextHeading, "", raw])
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - YAML

    /// A YAML scalar that means exactly what it says.
    ///
    /// Front matter is this module's injection surface — the analogue of CSV
    /// formula injection in `ExportService` — and the input is OCR of arbitrary
    /// screen content, so every one of these is a case that WILL show up:
    ///
    /// - `Deploy: checklist` unquoted parses as a nested mapping, so `title`
    ///   becomes a dictionary and the note's title silently disappears.
    /// - `# 4 of 7` starts a YAML comment: the value becomes empty.
    /// - `- item` reads as the start of a sequence.
    /// - A newline ends the scalar; everything after it is parsed as more front
    ///   matter, and a line of OCR that happens to contain a colon becomes a
    ///   key. This is how a screenshot rewrites its own metadata.
    /// - `yes`, `no`, `on`, `off`, `null`, `1.10`, `2026-08-13` all type-coerce
    ///   to something that is not the string the user saw.
    /// - A trailing `\` or an embedded `"` breaks the scalar even when quoted,
    ///   unless escaped.
    ///
    /// So: ALWAYS double-quote, never conditionally. Deciding per value which
    /// strings are "safe" is exactly the check that gets a case wrong, and a
    /// quoted scalar is valid YAML for every input including the boring ones.
    static func yamlEscaped(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                // Other C0 controls and DEL have no portable double-quoted
                // spelling worth emitting and are never meaningful in a title;
                // dropping them beats writing a document some parsers reject.
                if scalar.value < 0x20 || scalar.value == 0x7F { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: - File names

    /// The file name (without extension) for a note: a sortable timestamp then
    /// the title — `2026-08-13 1422 Deploy checklist`.
    ///
    /// The timestamp leads so a vault folder sorts chronologically by default,
    /// and it makes near-duplicate titles ("Screenshot", "Untitled") distinct
    /// without a collision counter.
    ///
    /// - Parameter timeZone: injectable so tests do not depend on the machine's
    ///   zone. The default is the LOCAL zone on purpose: this string is read by
    ///   a human who remembers taking the screenshot at 14:22 their time, not
    ///   at 12:22 UTC. (The front matter's `created` stays UTC — that one is
    ///   parsed by machines.)
    ///
    /// Deterministic for a given draft, which is what lets `MarkdownVaultSink`
    /// recognise the note it wrote last time.
    static func fileNameStem(for draft: NoteDraft, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        // en_US_POSIX or the format string is at the mercy of the user's
        // locale: a Japanese or Buddhist calendar renders `yyyy` as 2569.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: draft.createdAt)

        let title = sanitizedFileNameComponent(draft.title)
        let joined = title == fallbackFileNameComponent ? stamp : "\(stamp) \(title)"
        return clampedToUTF8Bytes(joined, limit: maxFileNameComponentBytes)
    }

    /// What a name becomes when nothing usable survives sanitising.
    static let fallbackFileNameComponent = "Note"

    /// A string safe to use as one path component.
    ///
    /// - `/` and `:` both go. `/` is the separator at the POSIX layer; `:` is
    ///   the separator in the old HFS/Carbon layer, and macOS still swaps the
    ///   two when it displays a name — a file created as `A:B` shows in Finder
    ///   as `A/B`, and one created through some APIs as `A/B` comes back as
    ///   `A:B`. Either one turns a title into a nonexistent subdirectory
    ///   somewhere in the stack. They become spaces rather than vanishing, so
    ///   `Prod/Staging` stays two words.
    /// - Control characters go (a newline in a file name is legal on APFS and
    ///   ruins every shell command the user will ever run on that vault).
    /// - Leading dots go: `.Deploy notes.md` is a hidden file, so the note the
    ///   user just asked for would not appear in their vault at all.
    /// - Whitespace runs collapse, because OCR of wrapped text produces them
    ///   constantly.
    ///
    /// The length clamp is measured in UTF-8 BYTES, not characters, because
    /// that is what APFS limits (255 of them). A 200-character title of CJK is
    /// 600 bytes and a title of emoji is 800; clamping by `count` would happily
    /// build a name the filesystem rejects with a `EINVAL` that surfaces as an
    /// unexplained "the note could not be written".
    ///
    /// Never returns an empty string — an empty component makes a URL that
    /// silently addresses the parent directory.
    static func sanitizedFileNameComponent(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in s.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { pendingSpace = true; continue }
            if scalar == "/" || scalar == ":" { pendingSpace = true; continue }
            if CharacterSet.whitespaces.contains(scalar) { pendingSpace = true; continue }
            if pendingSpace, !out.isEmpty { out.append(" ") }
            pendingSpace = false
            out.append(scalar)
        }

        var result = String(out)
        while result.hasPrefix(".") { result.removeFirst() }
        result = result.trimmingCharacters(in: .whitespaces)
        result = clampedToUTF8Bytes(result, limit: maxFileNameComponentBytes)
        return result.isEmpty ? fallbackFileNameComponent : result
    }

    /// `s` truncated to at most `limit` UTF-8 bytes, never mid-character.
    ///
    /// Iterating `Character`s rather than bytes is the point: cutting a UTF-8
    /// sequence in half produces a `String` that is invalid on disk and, worse,
    /// splits a grapheme cluster so a flag emoji becomes two regional
    /// indicators.
    static func clampedToUTF8Bytes(_ s: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard s.utf8.count > limit else { return s }
        var out = ""
        var used = 0
        for character in s {
            let size = String(character).utf8.count
            if used + size > limit { break }
            out.append(character)
            used += size
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// A URL in `directory` that `exists` says nothing occupies, appending
    /// ` 2`, ` 3`, … to `stem` until one is free.
    ///
    /// `exists` is injected rather than calling `FileManager` directly so this
    /// stays a pure function: the collision logic — the part with an off-by-one
    /// in it, since the first retry is 2 and not 1 — is testable against a
    /// `Set<URL>` with no vault, no temp directory and no cleanup.
    ///
    /// The suffix is a space and a number, matching what Finder and every
    /// download manager on the platform do, so a user seeing `… 2.md` in their
    /// vault already knows what it means.
    static func uniqueURL(
        directory: URL,
        stem: String,
        extension ext: String,
        exists: (URL) -> Bool
    ) -> URL {
        // Reserve room for the suffix and extension up front. Clamping only the
        // bare stem would let `<255-byte stem> 12.md` cross the limit exactly
        // when a collision forced the suffix on — a bug that never reproduces
        // until someone's vault has two long-titled notes in it.
        let extensionBytes = ext.isEmpty ? 0 : ext.utf8.count + 1
        let suffixReserve = 10 // " 12345678"
        let budget = min(
            maxFileNameComponentBytes,
            maxFileNameBytes - extensionBytes - suffixReserve
        )
        let base = clampedToUTF8Bytes(sanitizedFileNameComponent(stem), limit: budget)

        func url(named name: String) -> URL {
            directory.appending(path: ext.isEmpty ? name : "\(name).\(ext)")
        }

        var candidate = url(named: base)
        var counter = 2
        while exists(candidate) {
            // A vault with 999 same-named notes is not a real scenario, but an
            // unbounded loop against a caller-supplied `exists` that always
            // returns true is a hang, so fall through to a random suffix that
            // still fits the reserve above.
            if counter > 999 {
                let random = String(UUID().uuidString.prefix(8))
                return url(named: "\(base) \(random)")
            }
            candidate = url(named: "\(base) \(counter)")
            counter += 1
        }
        return candidate
    }

    // MARK: - Helpers

    /// Newlines and tabs flattened to single spaces.
    ///
    /// Applied to every value that has to occupy one line — a title, a tag, an
    /// app name. OCR routinely produces a "title" with a line break in it, and
    /// one in a Markdown `# ` heading ends the heading mid-sentence.
    private static func singleLine(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Heading text with the characters that would restructure the document
    /// neutralised.
    ///
    /// Only `#` at the start matters (it would deepen the heading level) — the
    /// rest of Markdown's syntax inside a heading is cosmetic, and escaping it
    /// all would put backslashes in front of every underscore in a title that
    /// came from a file name.
    private static func escapedHeadingText(_ value: String) -> String {
        value.hasPrefix("#") ? "\\" + value : value
    }
}
