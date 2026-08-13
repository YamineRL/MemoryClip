import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

/// The kind of payload a clip carries.
enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text
    case richText
    case image
    case file
    case link
    case color
}

/// One captured clipboard entry.
///
/// Note: do not add a property named `id` — `PersistentModel` already
/// satisfies `Identifiable` via `PersistentIdentifier`.
@Model
final class ClipItem {
    var uuid: UUID
    var kindRaw: String
    var text: String?
    var richTextData: Data?
    /// The full image payload, held OUTSIDE the row.
    ///
    /// Inline, SwiftData materialized every blob during a fetch — measured
    /// 527 MB resident (and 1281 ms) for a fetch of 500 retina screenshots,
    /// with touching the blobs afterwards costing 0 MB, i.e. no faulting to
    /// rely on. With external storage the same fetch is 18.7 MB / 29 ms and
    /// the bytes are read only when something actually asks for them.
    ///
    /// `.externalStorage` is a storage-strategy change, not a schema change:
    /// the attribute keeps its name, type and optionality, so the column and
    /// its version hash are unchanged and existing rows keep their inline
    /// bytes (verified by opening a copy of the real store). New writes go to
    /// the store's external-record directory, and the backfill rewrites old
    /// rows as it passes over them.
    @Attribute(.externalStorage) var imageData: Data?
    /// A tiny (row-sized) rendering of `imageData`, kept so the clip list can
    /// draw image rows without materializing the full blob.
    ///
    /// SwiftData materializes `Data` attributes eagerly during a fetch — a
    /// measured 1391 MB resident for 500 retina screenshots — so a list that
    /// reads `imageData` pays for every megabyte of every visible AND
    /// invisible row. A thumbnail is ~600x smaller.
    ///
    /// Optional, so an existing store migrates in place: SwiftData's
    /// lightweight migration can add a nullable column to rows that predate
    /// it, which a mandatory attribute without a default cannot.
    var thumbnailData: Data?
    var fileURLStrings: [String]
    var colorHex: String?
    var contentHash: String
    var sourceBundleID: String?
    var sourceAppName: String?
    var createdAt: Date
    var lastUsedAt: Date?
    var isPinned: Bool
    /// Text extracted from an image clip by OCRService (Phase 3). nil until
    /// recognition has run; empty when recognition found nothing legible.
    var ocrText: String?
    /// True once OCR has been attempted for this clip, successful or not —
    /// keeps the extractor from retrying the same image forever.
    ///
    /// The default value is what lets an existing (pre-Phase-3) store
    /// migrate in place: without it SwiftData rejects the new mandatory
    /// attribute on rows that predate it.
    var ocrAttempted: Bool = false
    /// True once a thumbnail has been generated for this clip, successful or
    /// not — keeps the backfill from re-decoding an undecodable blob forever.
    /// Defaults to false so pre-existing rows migrate in place and are then
    /// picked up by the lazy backfill.
    var thumbnailAttempted: Bool = false
    /// True when this clip is a screenshot MemoryClip picked up from the
    /// screenshot folder rather than from the pasteboard.
    ///
    /// Such a clip is a `.file` clip holding a REFERENCE: `fileURLStrings`
    /// points at the image on disk and `imageData` is deliberately empty, so
    /// a day of screenshots costs a few thumbnails rather than a few hundred
    /// megabytes. The flag is what lets the OCR and thumbnail backlogs treat
    /// it as an image even though its kind is `.file`, and what keeps
    /// ordinary file clips (a copied PDF, a folder) out of those backlogs.
    ///
    /// Defaulted, so a pre-existing store migrates in place.
    var isScreenshot: Bool = false
    /// A short title for the clip, produced by the local model.
    var refinedTitle: String?
    /// One or two sentences summarising the clip, from the local model.
    var refinedSummary: String?
    /// The cleaned-up version of `ocrText`: OCR slips corrected, wrapped
    /// lines rejoined, interface chrome dropped.
    ///
    /// Never replaces `ocrText`. The raw recognition stays the record of what
    /// was actually on screen, and every note carries it too — a 3B model is
    /// a convenience layer over the text, not a more authoritative copy of it.
    var refinedText: String?
    /// Topic tags suggested by the local model, used in note front matter.
    var refinedTags: [String] = []
    /// True once refinement has been attempted, successful or not — the same
    /// "never retry forever" contract as `ocrAttempted`.
    var refineAttempted: Bool = false
    /// Filesystem path (or, for non-file destinations, a human-readable
    /// locator) of the note written for this clip. Non-nil means "a note
    /// exists", which is what makes a second export update rather than
    /// duplicate.
    var notePath: String?
    /// When the note was last written.
    var noteExportedAt: Date?

    var kind: ClipKind {
        get { ClipKind(rawValue: kindRaw) ?? .text }
        set { kindRaw = newValue.rawValue }
    }

    init(
        uuid: UUID = UUID(),
        kind: ClipKind,
        text: String? = nil,
        richTextData: Data? = nil,
        imageData: Data? = nil,
        thumbnailData: Data? = nil,
        fileURLStrings: [String] = [],
        colorHex: String? = nil,
        contentHash: String,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        createdAt: Date = .now,
        lastUsedAt: Date? = nil,
        isPinned: Bool = false,
        ocrText: String? = nil,
        ocrAttempted: Bool = false,
        thumbnailAttempted: Bool = false,
        isScreenshot: Bool = false,
        refinedTitle: String? = nil,
        refinedSummary: String? = nil,
        refinedText: String? = nil,
        refinedTags: [String] = [],
        refineAttempted: Bool = false,
        notePath: String? = nil,
        noteExportedAt: Date? = nil
    ) {
        self.uuid = uuid
        self.kindRaw = kind.rawValue
        self.text = text
        self.richTextData = richTextData
        self.imageData = imageData
        self.thumbnailData = thumbnailData
        self.fileURLStrings = fileURLStrings
        self.colorHex = colorHex
        self.contentHash = contentHash
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.isPinned = isPinned
        self.ocrText = ocrText
        self.ocrAttempted = ocrAttempted
        self.thumbnailAttempted = thumbnailAttempted
        self.isScreenshot = isScreenshot
        self.refinedTitle = refinedTitle
        self.refinedSummary = refinedSummary
        self.refinedText = refinedText
        self.refinedTags = refinedTags
        self.refineAttempted = refineAttempted
        self.notePath = notePath
        self.noteExportedAt = noteExportedAt
    }

    // MARK: - Image payloads

    /// The screenshot this clip references, when it is one.
    ///
    /// `fileURLStrings` holds `URL.absoluteString`, so this round-trips
    /// through `URL(string:)` rather than treating the entry as a path.
    var screenshotURL: URL? {
        guard isScreenshot else { return nil }
        return fileURLStrings.first.flatMap(URL.init(string:))
    }

    /// Where the pixels for this clip live, if it has any.
    ///
    /// Unifies the two shapes an image clip now comes in — pasteboard bytes
    /// in the row, or a screenshot referenced on disk — so thumbnailing and
    /// OCR have one thing to consume instead of branching on `isScreenshot`
    /// at every call site.
    ///
    /// Note the `isEmpty` check: rows written before `imageData` gained
    /// `.externalStorage` read back as empty `Data` rather than nil.
    var imagePayload: ImagePayload? {
        if let data = imageData, !data.isEmpty { return .data(data) }
        if let url = screenshotURL { return .fileURL(url) }
        return nil
    }

    /// Indexes, all measured:
    /// - `contentHash` — the dedup lookup on every capture (6.6x at 10k rows,
    ///   31x at 50k against the same query without it).
    /// - `createdAt` — every list fetch sorts on it, and the cap trim now
    ///   fetches only the oldest `overflow` rows in that order.
    /// - `uuid` — `items(withUUIDs:)` resolves queue ids one indexed row at
    ///   a time (a `Set.contains` inside a `#Predicate` is NOT translated to
    ///   SQL and scanned the whole table: 15.1 ms at 50k).
    /// - `kindRaw` + the two attempted flags — the OCR and thumbnail backlogs
    ///   (`pendingOCR` scanned 25.8 ms at 50k).
    #Index<ClipItem>(
        [\.contentHash],
        [\.createdAt],
        [\.uuid],
        [\.kindRaw, \.ocrAttempted],
        [\.kindRaw, \.thumbnailAttempted],
        [\.isScreenshot, \.ocrAttempted],
        [\.isScreenshot, \.thumbnailAttempted],
        [\.refineAttempted]
    )
}

/// Image bytes, either held inline or referenced on disk.
///
/// `Sendable` on purpose: it crosses to a background task for thumbnailing
/// and recognition, both of which happen off the main actor.
enum ImagePayload: Sendable {
    case data(Data)
    case fileURL(URL)
}

/// Row-sized renderings of image clips.
///
/// Deliberately nonisolated and free of SwiftData/AppKit view types: the
/// backfill runs it off the main actor over `Data`, which is Sendable.
enum ClipThumbnail {
    /// Longest edge in pixels. The row draws at 34pt, the preview uses the
    /// thumbnail only as a placeholder, so 128px covers both at 2x.
    static let maxPixelSize = 128

    /// A small PNG rendering of whatever the clip's pixels are, inline or
    /// on disk.
    static func make(from payload: ImagePayload, maxPixelSize: Int = maxPixelSize) -> Data? {
        switch payload {
        case .data(let data): return make(from: data, maxPixelSize: maxPixelSize)
        case .fileURL(let url): return make(fromFileAt: url, maxPixelSize: maxPixelSize)
        }
    }

    /// A small PNG rendering of `data`, or nil when it does not decode as an
    /// image. ImageIO's thumbnail path decodes at the target size rather than
    /// decompressing the full bitmap first.
    static func make(from data: Data, maxPixelSize: Int = maxPixelSize) -> Data? {
        guard !data.isEmpty else { return nil }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { return nil }

        return encodedThumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    /// A small PNG rendering of an image file, or nil when it is missing or
    /// undecodable.
    ///
    /// `CGImageSourceCreateWithURL` reads only the bytes it needs, so a 12 MB
    /// retina screenshot becomes a 10 KB thumbnail without the full bitmap
    /// ever being resident — which is the whole reason screenshot clips hold
    /// a path instead of a blob.
    static func make(fromFileAt url: URL, maxPixelSize: Int = maxPixelSize) -> Data? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { return nil }

        return encodedThumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    /// Shared tail of both entry points: ask ImageIO for a thumbnail and
    /// encode it as PNG.
    private static func encodedThumbnail(from source: CGImageSource, maxPixelSize: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
