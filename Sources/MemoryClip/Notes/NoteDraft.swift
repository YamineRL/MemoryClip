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
    /// this is nil for them.
    var sourceFileURL: URL?
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
        wasRefined: Bool = false,
        createdAt: Date = .now,
        sourceAppName: String? = nil,
        sourceFileURL: URL? = nil,
        attachmentFileName: String? = nil
    ) {
        self.clipUUID = clipUUID
        self.title = title
        self.summary = summary
        self.tags = tags
        self.body = body
        self.rawText = rawText
        self.wasRefined = wasRefined
        self.createdAt = createdAt
        self.sourceAppName = sourceAppName
        self.sourceFileURL = sourceFileURL
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
    /// A screenshot on its own counts: a note that is just the image is still
    /// a note the user asked for.
    var hasContent: Bool {
        if sourceFileURL != nil { return true }
        let filled = [title, summary, body].contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return filled
    }
}
