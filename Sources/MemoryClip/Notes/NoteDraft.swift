import Foundation

/// Everything a note needs, flattened away from SwiftData.
///
/// The same split as `ClipExport` in ExportService, for the same reason: a
/// `ClipItem` is a `@Model` object bound to its `ModelContext`, so passing one
/// to a sink would drag the persistence layer into code that runs off the main
/// actor and shells out to `Process`. The caller reads the model once, builds
/// this value, and the whole note module then works on something `Sendable`
/// that a test can construct in one line.
///
/// Note the ordering contract on `attachmentFileName`: it is the one field a
/// sink fills in rather than the caller, because only the sink knows what the
/// image ended up being called once it was copied into the vault. Composition
/// reads it, so a sink must copy the attachment BEFORE it composes.
struct NoteDraft: Sendable, Equatable {
    /// `ClipItem.uuid` — written into the front matter so a re-export can
    /// recognise its own earlier note instead of writing a second one.
    var clipUUID: UUID
    /// The note's title. Model-produced (`refinedTitle`) when refinement ran,
    /// otherwise whatever the caller could derive from the text.
    var title: String
    /// One or two sentences (`refinedSummary`). May be empty.
    var summary: String
    /// Topic tags (`refinedTags`). May be empty.
    var tags: [String]
    /// The note's text: `refinedText` when the model cleaned the recognition
    /// up, else the raw `ocrText`.
    var body: String
    /// The original OCR, carried alongside `body` when the two differ.
    ///
    /// nil when nothing was cleaned up (there is no point storing the same
    /// string twice) — see `NoteComposer.markdown(for:)` for why it is emitted
    /// at all.
    var rawText: String?
    /// The English rendering of `body`, when the text was captured in another
    /// language. nil for an English clip, and for one whose language this Mac
    /// cannot translate.
    ///
    /// It sits alongside `body` rather than replacing it for the same reason
    /// `rawText` does: the note is a record of what was on screen, and a
    /// translation is a second reading of it. A reader who knows the original
    /// language should not have to read the machine's English to check what
    /// it said.
    var translation: String?
    /// What `body` is written in, as a BCP-47 identifier ("ar", "ja"), when
    /// it was identified. Written into front matter so a vault can be queried
    /// by language, and used to name the language in the note's headings.
    var sourceLanguage: String?
    /// True when `body` came out of the local model rather than straight from
    /// recognition. Drives the wording around the raw-text section: a reader
    /// needs to know which of the two blocks is the machine-edited one.
    var wasRefined: Bool
    /// The clip's capture time, not the export time — the note is a record of
    /// when the screenshot was taken, and the file name is built from it, so
    /// re-exporting the same clip lands on the same name.
    var createdAt: Date
    /// The app the clip came from (`ClipItem.sourceAppName`), when known.
    var sourceAppName: String?
    /// The screenshot on disk (`ClipItem.screenshotURL`), when there is one.
    /// Pasteboard image clips hold their bytes in the row and have no file, so
    /// this is nil for them — they carry `imageData` instead.
    var sourceFileURL: URL?
    /// The clip's own pixels (`ClipItem.imageData`), for an image copied to the
    /// pasteboard rather than screenshotted to disk.
    ///
    /// The other half of `sourceFileURL`: between them every picture a clip can
    /// hold has somewhere for a sink to read it from, so an image clip's note
    /// gets the same embedded picture a screenshot's does. Which of the two a
    /// clip has is an accident of how it was captured — ⌘C in Preview rather
    /// than ⇧⌘4 — and is not something the reader of the note should be able to
    /// tell from what ends up in it.
    ///
    /// PNG, as `ContentParser.imageData(for:)` encodes it (TIFF only when that
    /// fails), which is what lets the sink name the copy `.png` without
    /// sniffing the bytes.
    var imageData: Data?
    /// The file name the image ended up with inside the destination, set by a
    /// sink after it copied the image in. nil means "the image was not copied",
    /// which is what makes `NoteComposer` fall back to a plain `file://` link.
    var attachmentFileName: String?

    init(
        clipUUID: UUID,
        title: String,
        summary: String = "",
        tags: [String] = [],
        body: String,
        rawText: String? = nil,
        translation: String? = nil,
        sourceLanguage: String? = nil,
        wasRefined: Bool = false,
        createdAt: Date = .now,
        sourceAppName: String? = nil,
        sourceFileURL: URL? = nil,
        imageData: Data? = nil,
        attachmentFileName: String? = nil
    ) {
        self.clipUUID = clipUUID
        self.title = title
        self.summary = summary
        self.tags = tags
        self.body = body
        self.rawText = rawText
        self.translation = translation
        self.sourceLanguage = sourceLanguage
        self.wasRefined = wasRefined
        self.createdAt = createdAt
        self.sourceAppName = sourceAppName
        self.sourceFileURL = sourceFileURL
        self.imageData = imageData
        self.attachmentFileName = attachmentFileName
    }

    /// Whether there is anything worth writing.
    ///
    /// A draft can be legitimately empty: a screenshot of a photo OCRs to
    /// nothing, and the refiner then has nothing to title or summarise. Every
    /// sink guards on this so the failure is `NoteError.nothingToWrite` — a
    /// sentence the user can act on — rather than a file full of front matter
    /// and no note, or a blank entry in Notes.
    ///
    /// A picture on its own counts: a note that is just the image is still
    /// a note the user asked for.
    var hasContent: Bool {
        if sourceFileURL != nil { return true }
        if let imageData, !imageData.isEmpty { return true }
        let filled = [title, summary, body, translation ?? ""].contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return filled
    }
}
