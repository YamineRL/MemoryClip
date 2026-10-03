import XCTest

@testable import MemoryClip

/// Covers the editing session's pure rules (escape layering, dirty tracking,
/// monospaced drafts) and `ClipStore.applyEdit`/`restoreEdit`, which own the
/// save semantics: kind and hash re-derived through `ContentParser.parseText`,
/// derived fields reset, duplicates merged, undoable by snapshot.
@MainActor
final class ClipEditTests: XCTestCase {
    private func makeStore() throws -> ClipStore {
        try ClipStore(inMemory: true)
    }

    /// The capture path for a string, used to seed rows exactly the way a
    /// copy would have written them.
    private func seed(_ store: ClipStore, _ text: String) throws -> ClipItem {
        let clip = try XCTUnwrap(
            ContentParser.parseText(text),
            "fixture text should parse like a copy would"
        )
        store.insert(clip, sourceBundleID: "com.example.test", sourceAppName: "TestApp")
        return try XCTUnwrap(store.recent(limit: 1).first, "the seeded clip should be fetchable")
    }

    // MARK: - Escape layering

    /// The observable rule the editor's Escape key lives by: clean draft
    /// leaves at once, dirty draft warns first and only the second press
    /// discards. Getting this order wrong is a silent data-loss bug: a
    /// single Escape would throw the draft away.
    func testEscapeActionLayers() {
        XCTAssertEqual(
            ClipEdit.escapeAction(hasChanges: false, discardArmed: false), .leave,
            "nothing to lose: leave"
        )
        XCTAssertEqual(
            ClipEdit.escapeAction(hasChanges: false, discardArmed: true), .leave,
            "an armed confirm on a since-cleaned draft still just leaves"
        )
        XCTAssertEqual(
            ClipEdit.escapeAction(hasChanges: true, discardArmed: false), .confirmDiscard,
            "first Escape on a dirty draft warns, it does not discard"
        )
        XCTAssertEqual(
            ClipEdit.escapeAction(hasChanges: true, discardArmed: true), .discard,
            "the warned second Escape discards"
        )
    }

    // MARK: - Session dirty tracking

    /// `hasChanges` is measured against the text the clip held when the
    /// editor opened, so a draft typed and then deleted back to the original
    /// is clean again, and a draft restored from the in-memory stash still
    /// counts as unsaved.
    func testSessionMeasuresChangesAgainstTheSavedText() {
        let item = ClipItem(kind: .text, text: "original", contentHash: "h")
        var session = ClipEdit.Session(item: item, draft: nil, restoredDraft: false)
        XCTAssertFalse(session.hasChanges)

        session.draft = "edited"
        XCTAssertTrue(session.hasChanges)

        session.draft = "original"
        XCTAssertFalse(session.hasChanges, "typed then reverted is clean")
    }

    func testRestoredDraftStillCountsAsUnsaved() {
        let item = ClipItem(kind: .text, text: "original", contentHash: "h")
        let session = ClipEdit.Session(item: item, draft: "draft from before", restoredDraft: true)
        XCTAssertTrue(session.hasChanges)
        XCTAssertEqual(session.draft, "draft from before")
        XCTAssertTrue(session.restoredDraft)
    }

    /// A fresh keystroke after the discard warning disarms it; otherwise
    /// the next Escape would discard a draft the user demonstrably wants.
    func testTypingDisarmsTheDiscardWarning() {
        let item = ClipItem(kind: .text, text: "original", contentHash: "h")
        var session = ClipEdit.Session(item: item, draft: nil, restoredDraft: false)
        session.draft = "edited"
        session.discardArmed = true

        session.draft = "edited more"
        XCTAssertFalse(session.discardArmed)
    }

    // MARK: - Monospaced drafts

    /// A colour's hex is the one draft the preview already renders
    /// monospaced; ordinary text stays in the body font.
    func testOnlyColorDraftsOpenMonospaced() {
        XCTAssertTrue(
            ClipEdit.prefersMonospaced(
                for: ClipItem(kind: .color, text: "#FF8800", colorHex: "#FF8800", contentHash: "h")
            )
        )
        for kind in [ClipKind.text, .richText, .link] {
            XCTAssertFalse(
                ClipEdit.prefersMonospaced(for: ClipItem(kind: kind, text: "t", contentHash: "h")),
                "\(kind) should edit in the body font"
            )
        }
    }

    // MARK: - parseText: the seam between capture and edit

    /// `parseText` is what an edit re-derives through, so it must behave
    /// like the copied-string tail of `parse` did: verbatim text for plain
    /// strings, normalized hex for colours, trimmed URL for links, and nil
    /// for the whitespace-only input a pasteboard copy never produces.
    func testParseTextMatchesCopyClassification() {
        let text = ContentParser.parseText("  hello  ")
        XCTAssertEqual(text?.kind, .text)
        XCTAssertEqual(text?.text, "  hello  ", "plain text keeps its whitespace")
        XCTAssertEqual(text?.hash, ContentParser.hashText("text:  hello  "))

        let color = ContentParser.parseText("#ff8800")
        XCTAssertEqual(color?.kind, .color)
        XCTAssertEqual(color?.colorHex, "#FF8800")
        XCTAssertEqual(color?.hash, ContentParser.hashText("color:#FF8800"))

        let link = ContentParser.parseText("  https://example.com/a  ")
        XCTAssertEqual(link?.kind, .link)
        XCTAssertEqual(link?.text, "https://example.com/a")
        XCTAssertEqual(link?.hash, ContentParser.hashText("link:https://example.com/a"))

        XCTAssertNil(ContentParser.parseText("   \n\t  "))
    }

    // MARK: - applyEdit

    /// The heart of the feature: saving an edit re-derives kind and hash the
    /// way capture would, so an edited clip files itself under what it now
    /// is rather than what it used to be.
    func testApplyEditRederivesKindAndHash() throws {
        let store = try makeStore()
        let item = try seed(store, "a plain sentence")

        let snapshot = store.applyEdit(item, newText: "https://example.com")

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(item.kind, .link)
        XCTAssertEqual(item.text, "https://example.com")
        XCTAssertEqual(
            item.contentHash, ContentParser.hashText("link:https://example.com")
        )
        XCTAssertEqual(snapshot?.kind, .text)
        XCTAssertEqual(snapshot?.text, "a plain sentence")
        XCTAssertEqual(snapshot?.contentHash, ContentParser.hashText("text:a plain sentence"))
    }

    func testApplyEditRecognizesAColor() throws {
        let store = try makeStore()
        let item = try seed(store, "not a colour")

        store.applyEdit(item, newText: " #00ff41 ")

        XCTAssertEqual(item.kind, .color)
        XCTAssertEqual(item.colorHex, "#00FF41")
        XCTAssertEqual(item.text, "#00FF41")
        XCTAssertEqual(item.contentHash, ContentParser.hashText("color:#00FF41"))
    }

    /// A rich-text clip saves flattened: the RTF bytes are the old content's
    /// formatting, and keeping them would show stale styled text over the
    /// edited words.
    func testApplyEditFlattensRichText() throws {
        let store = try makeStore()
        let rtf = Data("rtf".utf8)
        let item = ClipItem(
            kind: .richText, text: "styled", richTextData: rtf,
            contentHash: ContentParser.hashData(rtf)
        )
        store.context.insert(item)
        try store.context.save()

        store.applyEdit(item, newText: "styled, now plain")

        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.text, "styled, now plain")
        XCTAssertNil(item.richTextData)
        XCTAssertEqual(item.contentHash, ContentParser.hashText("text:styled, now plain"))
    }

    /// Editing a clip down to whitespace keeps the row: a copy never makes
    /// one, but deleting a clip as a side effect of an edit would surprise.
    func testApplyEditToWhitespaceKeepsTheRowAsPlainText() throws {
        let store = try makeStore()
        let item = try seed(store, "something")

        store.applyEdit(item, newText: "   ")

        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.text, "   ", "exactly what was typed, not the trimmed form")
        XCTAssertEqual(item.contentHash, ContentParser.hashText("text:   "))
        XCTAssertFalse(item.isDeleted)
        XCTAssertEqual(store.recent(limit: 10).count, 1)
    }

    /// Title, summary, tags, language and translations describe the old text;
    /// once the text is gone they are stale rather than merely old, and a
    /// stale summary is worse than none because it is searchable.
    func testApplyEditDropsDerivedFields() throws {
        let store = try makeStore()
        let item = ClipItem(
            kind: .text, text: "original",
            contentHash: ContentParser.hashText("text:original"),
            refinedTitle: "Old title", refinedSummary: "Old summary",
            refinedText: "Old cleaned", refinedTags: ["old"],
            refineAttempted: true,
            sourceLanguage: "fr", translatedText: "translated",
            clipTranslationText: "clip translated",
            clipTranslationSource: "fr", clipTranslationTarget: "en",
            notePath: "/tmp/note.md", noteExportedAt: .now,
            calendarEventID: "event-1"
        )
        store.context.insert(item)
        try store.context.save()

        store.applyEdit(item, newText: "replacement")

        XCTAssertNil(item.refinedTitle)
        XCTAssertNil(item.refinedSummary)
        XCTAssertNil(item.refinedText)
        XCTAssertEqual(item.refinedTags, [])
        XCTAssertFalse(item.refineAttempted)
        XCTAssertNil(item.sourceLanguage)
        XCTAssertNil(item.translatedText)
        XCTAssertNil(item.clipTranslationText)
        XCTAssertNil(item.clipTranslationSource)
        XCTAssertNil(item.clipTranslationTarget)
        // The note file and the calendar event still exist; the edit does
        // not orphan them.
        XCTAssertEqual(item.notePath, "/tmp/note.md")
        XCTAssertEqual(item.calendarEventID, "event-1")
    }

    /// Editing a clip into content that already exists must not leave two
    /// rows with one hash: the edited clip survives, the older creation date
    /// and either pin win, and data only the duplicate held (its note, its
    /// calendar event, its later lastUsedAt) moves rather than vanishing.
    func testApplyEditMergesIntoTheExistingDuplicate() throws {
        let store = try makeStore()
        let old = ClipItem(
            kind: .text, text: "target text",
            contentHash: ContentParser.hashText("text:target text"),
            createdAt: Date(timeIntervalSinceNow: -3600),
            lastUsedAt: Date(timeIntervalSinceNow: -60),
            isPinned: true, notePath: "/tmp/note.md", calendarEventID: "event-9"
        )
        store.context.insert(old)
        try store.context.save()
        let item = try seed(store, "edit me")
        let originalCreatedAt = item.createdAt

        store.applyEdit(item, newText: "target text")

        XCTAssertEqual(store.recent(limit: 10).count, 1, "the duplicate row is gone")
        XCTAssertEqual(store.recent(limit: 10).first?.uuid, item.uuid, "the edited clip survives")
        XCTAssertEqual(item.createdAt, old.createdAt, "the older creation date wins")
        XCTAssertTrue(item.isPinned, "a pin on the duplicate survives")
        XCTAssertEqual(item.lastUsedAt, old.lastUsedAt, "the fresher usage wins")
        XCTAssertEqual(item.notePath, "/tmp/note.md")
        XCTAssertEqual(item.calendarEventID, "event-9")
        XCTAssertNil(store.item(withUUID: old.uuid), "the duplicate row is deleted")
        XCTAssertTrue(originalCreatedAt > item.createdAt)
    }

    /// The key press has no menu item to hide behind, so on an uneditable
    /// clip applyEdit must be a no-op rather than a write that can only
    /// corrupt: images and files have no text for the draft to have replaced.
    func testApplyEditDeclinesNonEditableKinds() throws {
        let store = try makeStore()
        let item = ClipItem(kind: .file, fileURLStrings: ["/tmp/a.txt"], contentHash: "file-hash")
        store.context.insert(item)
        try store.context.save()

        XCTAssertNil(store.applyEdit(item, newText: "anything"))
        XCTAssertEqual(item.contentHash, "file-hash")
        XCTAssertEqual(item.fileURLStrings, ["/tmp/a.txt"])
    }

    // MARK: - restoreEdit

    /// ⌘Z's whole contract: the snapshot hands back exactly the content the
    /// clip held before the edit: kind, text, hash and the RTF payload a
    /// flattened rich-text clip would otherwise have lost for good.
    func testRestoreEditPutsTheContentBack() throws {
        let store = try makeStore()
        let rtf = Data("rtf".utf8)
        let item = ClipItem(
            kind: .richText, text: "styled", richTextData: rtf,
            contentHash: ContentParser.hashData(rtf)
        )
        store.context.insert(item)
        try store.context.save()

        let snapshot = store.applyEdit(item, newText: "#A1B2C3")
        XCTAssertEqual(item.kind, .color)

        store.restoreEdit(snapshot!)

        XCTAssertEqual(item.kind, .richText)
        XCTAssertEqual(item.text, "styled")
        XCTAssertEqual(item.richTextData, rtf)
        XCTAssertEqual(item.contentHash, ContentParser.hashData(rtf))
        XCTAssertNil(item.colorHex)
    }

    /// The snapshot outlives the row: a clip deleted after the edit must not
    /// be resurrected or crash when the undo lands.
    func testRestoreEditOnAGoneClipIsANoOp() throws {
        let store = try makeStore()
        let item = try seed(store, "soon gone")
        let snapshot = store.applyEdit(item, newText: "edited")!
        store.context.delete(item)
        try store.context.save()

        store.restoreEdit(snapshot)

        XCTAssertEqual(store.recent(limit: 10).count, 0)
    }
}
