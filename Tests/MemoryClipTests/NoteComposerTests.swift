import XCTest

@testable import MemoryClip

/// The note document itself: front matter that survives a YAML parser, an
/// image reference that resolves, and a file name a filesystem accepts.
final class NoteComposerTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_800_000_000)

    private func draft(
        title: String = "Deploy checklist",
        summary: String = "The steps for shipping 2.1.",
        tags: [String] = ["deploy", "release"],
        body: String = "1. Tag the release\n2. Run the build",
        rawText: String? = nil,
        wasRefined: Bool = true,
        sourceAppName: String? = "Safari",
        sourceFileURL: URL? = nil,
        attachmentFileName: String? = nil
    ) -> NoteDraft {
        NoteDraft(
            clipUUID: UUID(uuidString: "8B7F0C1E-0000-4000-8000-00000000ABCD")!,
            title: title,
            summary: summary,
            tags: tags,
            body: body,
            rawText: rawText,
            wasRefined: wasRefined,
            createdAt: created,
            sourceAppName: sourceAppName,
            sourceFileURL: sourceFileURL,
            attachmentFileName: attachmentFileName
        )
    }

    // MARK: - Front matter

    func testFrontMatterCarriesTheClipIdentity() {
        let markdown = NoteComposer.markdown(for: draft())
        XCTAssertTrue(markdown.hasPrefix("---\n"))
        // The uuid is what lets a re-export recognise its own earlier note
        // instead of writing a second one.
        XCTAssertTrue(markdown.contains("memoryclip-uuid: 8B7F0C1E-0000-4000-8000-00000000ABCD"))
        XCTAssertTrue(markdown.contains("source: \"Safari\""))
        XCTAssertTrue(markdown.contains("  - \"deploy\""))
    }

    func testAbsentMetadataIsOmittedRatherThanEmitedEmpty() {
        let markdown = NoteComposer.markdown(for: draft(tags: [], sourceAppName: nil))
        XCTAssertFalse(markdown.contains("source:"), "an empty source: is a claim, not an absence")
        XCTAssertFalse(markdown.contains("tags:"))
    }

    func testTitlesThatWouldCorruptTheDocumentAreEscaped() {
        // Every one of these breaks or silently changes meaning unquoted:
        // a colon starts a nested key, a leading # is a comment, a leading
        // dash is a list item, a newline ends the scalar entirely.
        for hostile in [
            "Fix: the login bug",
            "#deploy",
            "- item",
            "He said \"go\"",
            "line one\nline two",
            "back\\slash",
        ] {
            let escaped = NoteComposer.yamlEscaped(hostile)
            XCTAssertTrue(escaped.hasPrefix("\""), "\(hostile) must be quoted")
            XCTAssertTrue(escaped.hasSuffix("\""))
            // The value must be one line: a raw newline would terminate the
            // scalar and turn the rest of the title into a bogus key.
            XCTAssertFalse(escaped.dropFirst().dropLast().contains("\n"))
        }
        XCTAssertEqual(NoteComposer.yamlEscaped("He said \"go\""), "\"He said \\\"go\\\"\"")
        XCTAssertEqual(NoteComposer.yamlEscaped("back\\slash"), "\"back\\\\slash\"")
    }

    // MARK: - Body

    func testAnAttachmentBecomesAnObsidianEmbed() {
        let markdown = NoteComposer.markdown(
            for: draft(attachmentFileName: "Screenshot 2026-08-13.png")
        )
        XCTAssertTrue(markdown.contains("![[Screenshot 2026-08-13.png]]"))
    }

    func testAnUncopiedScreenshotBecomesALinkNotAnEmbed() {
        // An embed pointing outside the vault renders as broken-image text in
        // Obsidian, so the fallback has to be a link that actually opens.
        let url = URL(fileURLWithPath: "/Users/me/Desktop/Screenshot at 14.22.png")
        let markdown = NoteComposer.markdown(for: draft(sourceFileURL: url))
        XCTAssertFalse(markdown.contains("![["))
        XCTAssertTrue(markdown.contains("[Screenshot](file:///"))
        // Percent-encoded, so the link target does not stop at the first space.
        XCTAssertFalse(markdown.contains("Screenshot at 14.22.png)"))
    }

    func testTheRawRecognitionTravelsWithTheNote() {
        let markdown = NoteComposer.markdown(
            for: draft(body: "Tag the release", rawText: "Tag  the reIease", wasRefined: true)
        )
        XCTAssertTrue(markdown.contains("## \(NoteComposer.rawTextHeading)"))
        XCTAssertTrue(markdown.contains("Tag  the reIease"))
    }

    func testRawTextIsNotRepeatedWhenItIsTheBody() {
        let markdown = NoteComposer.markdown(
            for: draft(body: "same text", rawText: "same text", wasRefined: false)
        )
        XCTAssertFalse(markdown.contains("## \(NoteComposer.rawTextHeading)"))
    }

    // MARK: - HTML

    func testHTMLEscapesContentThatWouldOtherwiseVanish() {
        // Screenshots of code are the common case, and `<div>` unescaped
        // disappears into the note as markup.
        let markdown = NoteComposer.html(for: draft(body: "if (a < b && c) return \"x\";"))
        XCTAssertTrue(markdown.contains("&lt;"))
        XCTAssertTrue(markdown.contains("&amp;"))
        XCTAssertFalse(markdown.contains("a < b"))
    }

    func testHTMLEscapingCoversTheFullSet() {
        XCTAssertEqual(
            NoteComposer.htmlEscaped("&<>\"'"),
            "&amp;&lt;&gt;&quot;&#39;"
        )
    }

    // MARK: - File names

    func testSeparatorsInATitleNeverBecomePathComponents() {
        // `/` is the POSIX separator and `:` the old HFS one, and macOS still
        // swaps them when displaying names — either turns a title into a
        // nonexistent subdirectory.
        XCTAssertEqual(NoteComposer.sanitizedFileNameComponent("Prod/Staging"), "Prod Staging")
        XCTAssertEqual(NoteComposer.sanitizedFileNameComponent("Fix: login"), "Fix login")
    }

    func testHiddenFileNamesAreImpossible() {
        // `.Deploy.md` would not appear in the user's vault at all.
        XCTAssertEqual(NoteComposer.sanitizedFileNameComponent("...Deploy"), "Deploy")
    }

    func testControlCharactersAndWhitespaceRunsCollapse() {
        XCTAssertEqual(NoteComposer.sanitizedFileNameComponent("a\nb\t\tc   d"), "a b c d")
    }

    func testAnUnusableTitleFallsBackRatherThanReturningEmpty() {
        // An empty path component silently addresses the parent directory.
        XCTAssertEqual(
            NoteComposer.sanitizedFileNameComponent("///"),
            NoteComposer.fallbackFileNameComponent
        )
        XCTAssertEqual(
            NoteComposer.sanitizedFileNameComponent(""),
            NoteComposer.fallbackFileNameComponent
        )
    }

    func testLengthIsClampedInBytesNotCharacters() {
        // 200 emoji is 800 UTF-8 bytes — a name APFS rejects outright, even
        // though `count` says it is well under any plausible limit.
        let emoji = String(repeating: "🌍", count: 200)
        let clamped = NoteComposer.sanitizedFileNameComponent(emoji)
        XCTAssertLessThanOrEqual(clamped.utf8.count, NoteComposer.maxFileNameComponentBytes)
        // …and never mid-character: a half-written sequence is invalid on disk.
        XCTAssertTrue(clamped.allSatisfy { $0 == "🌍" })
    }

    func testFileNameStemLeadsWithASortableTimestamp() {
        let stem = NoteComposer.fileNameStem(
            for: draft(title: "Deploy checklist"),
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertEqual(stem, "2027-01-15 0800 Deploy checklist")
    }

    func testFileNameStemIsDeterministicForTheSameDraft() {
        // This is what lets a re-export find the note it wrote last time.
        let one = NoteComposer.fileNameStem(for: draft(), timeZone: TimeZone(identifier: "UTC")!)
        let two = NoteComposer.fileNameStem(for: draft(), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(one, two)
    }

    func testCollisionsGetASuffix() {
        let directory = URL(fileURLWithPath: "/vault")
        let taken: Set<String> = ["/vault/Note.md", "/vault/Note 2.md"]
        let url = NoteComposer.uniqueURL(
            directory: directory,
            stem: "Note",
            extension: "md",
            exists: { taken.contains($0.path) }
        )
        XCTAssertEqual(url.lastPathComponent, "Note 3.md")
    }

    func testNoCollisionMeansNoSuffix() {
        let url = NoteComposer.uniqueURL(
            directory: URL(fileURLWithPath: "/vault"),
            stem: "Note",
            extension: "md",
            exists: { _ in false }
        )
        XCTAssertEqual(url.lastPathComponent, "Note.md")
    }

    // MARK: - AppleScript

    func testAppleScriptStringsAreEscaped() {
        // A quote in a title is a syntax error in the generated script, which
        // surfaces as an opaque -2741 rather than as anything about the title.
        XCTAssertEqual(NotesAppSink.appleScriptEscaped("He said \"go\""), "He said \\\"go\\\"")
        XCTAssertEqual(NotesAppSink.appleScriptEscaped("back\\slash"), "back\\\\slash")
    }

    func testGeneratedScriptQuotesEveryInterpolation() {
        let script = NotesAppSink.script(
            folder: "My \"Notes\"",
            title: "Fix \"login\"",
            body: "<h1>Fix</h1>"
        )
        // No unescaped quote may reach the script: the escaped forms are the
        // only ones that appear.
        XCTAssertTrue(script.contains("My \\\"Notes\\\""))
        XCTAssertTrue(script.contains("Fix \\\"login\\\""))
    }
}
