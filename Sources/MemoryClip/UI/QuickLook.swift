import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where the bytes behind a full-size Quick Look preview live.
///
/// Quick Look only ever reads files, so the two shapes a clip's content comes
/// in have to be told apart before a preview can be handed over: a clip that
/// already references something on disk is ready to show, while pasteboard
/// image bytes need a file written for them first.
enum QuickLookSource: Equatable, Sendable {
    /// Something already on disk — a screenshot, or any `.file` clip.
    case file(URL)
    /// Image bytes held in the row, which `QuickLookCache` has to spill to a
    /// file before Quick Look can read them.
    case pasteboardImage
}

/// What pressing Space does in the panel.
///
/// Space escalates rather than toggling: it opens the preview pane, then —
/// on a clip Quick Look can show — goes full size, and only on a clip Quick
/// Look has nothing to do with does the second press close the pane again.
/// Escape still unwinds the whole way out, so nothing is trapped.
enum PanelSpaceAction: Equatable {
    case openPreview
    case openQuickLook
    case closePreview
}

/// Which clips Quick Look can show full size, in what order, and starting
/// where.
///
/// Deliberately pure and free of AppKit: the decisions are the part worth
/// testing, and `QLPreviewPanel` needs a window server that the test suite
/// does not have. `QuickLookController` is the seam that turns these values
/// into a panel on screen.
enum QuickLook {
    /// Where this clip's preview would come from, or nil when Quick Look has
    /// nothing to show for it.
    ///
    /// Anything backed by a real file qualifies — a screenshot, a copied PDF,
    /// a folder — because Quick Look already knows how to render all of them,
    /// and so do pasteboard image clips, whose pixels live in the row. Text,
    /// rich text, links and colours are deliberately out: the preview pane
    /// already shows them better than a Finder-style overlay would, and it is
    /// what Space keeps doing for them.
    ///
    /// The check is structural — a kind and a URL string — so building the
    /// list for a whole page of clips never touches `imageData` and never
    /// faults an external blob in. Whether the bytes are actually there is
    /// settled later, once per clip, by whoever resolves the URL.
    static func source(for item: some ClipDisplayable) -> QuickLookSource? {
        if item.kind == .image { return .pasteboardImage }
        // `fileURLStrings` holds `URL.absoluteString`, so this round-trips
        // through `URL(string:)` rather than treating the entry as a path —
        // a name with spaces is stored percent-encoded, and only the encoded
        // form survives the trip back to the filesystem.
        guard let first = item.fileURLStrings.first,
              let url = URL(string: first),
              url.isFileURL
        else { return nil }
        return .file(url)
    }

    static func canPreview(_ item: some ClipDisplayable) -> Bool {
        source(for: item) != nil
    }

    /// The name Quick Look puts over the preview.
    ///
    /// A file shows its own name, which is what Finder does. A pasteboard
    /// image has no name — its temp file is named after a uuid, and a uuid
    /// over the picture would be worse than nothing — so the local model's
    /// title stands in when there is one.
    static func title(for item: some ClipDisplayable) -> String {
        if item.kind != .image, let first = item.fileURLStrings.first {
            let name = ClipDisplay.displayName(first)
            if !name.isEmpty { return name }
        }
        let refined = item.refinedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !refined.isEmpty { return refined }
        return ClipDisplay.kindLabel(item.kind, isScreenshot: item.isScreenshot)
    }

    /// The Quick Look-able clips of the panel's current list, in list order,
    /// paired with the position of the clip Quick Look was invoked from.
    ///
    /// The whole filtered list rather than the one clip, so ← and → walk the
    /// history full size the way arrowing through a Finder folder does. nil
    /// when the invoked clip is not one Quick Look can show, which is the
    /// case where Space closes the preview pane instead.
    static func plan<T: ClipDisplayable>(
        for items: [T],
        startingAt uuid: UUID
    ) -> (items: [T], index: Int)? {
        let previewable = items.filter { canPreview($0) }
        guard let index = previewable.firstIndex(where: { $0.uuid == uuid }) else { return nil }
        return (previewable, index)
    }

    /// What Space should do, given the state of the preview pane and whether
    /// the clip under it is one Quick Look can show.
    static func spaceAction(previewVisible: Bool, canQuickLook: Bool) -> PanelSpaceAction {
        guard previewVisible else { return .openPreview }
        return canQuickLook ? .openQuickLook : .closePreview
    }
}

/// The files written for pasteboard image clips so Quick Look has something
/// to read.
///
/// Quick Look is a file previewer: it takes URLs, not bytes. Screenshots
/// already have a file, but a picture copied from the pasteboard lives in the
/// clip row, so it has to be spilled to disk. The caches directory is the
/// right home for that — the system may reap it whenever it likes, and every
/// file here can be rebuilt from the store on demand.
enum QuickLookCache {
    /// `~/Library/Caches/app.memoryclip/QuickLook`.
    ///
    /// Namespaced by bundle identifier for the same reason the store is: the
    /// app is unsandboxed, so the bare caches directory is shared with every
    /// other unsandboxed app on the Mac.
    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches
            .appendingPathComponent("app.memoryclip", isDirectory: true)
            .appendingPathComponent("QuickLook", isDirectory: true)
    }

    /// The filename extension these bytes should carry, read out of the image
    /// itself rather than assumed.
    ///
    /// The extension is not cosmetic: Quick Look picks a generator by file
    /// type, and a JPEG or a HEIC named `.png` is a preview that either fails
    /// or renders through the wrong path. ImageIO reads only the header to
    /// answer this. nil means the bytes are not an image anything on this Mac
    /// can identify, and there is therefore nothing worth writing out.
    static func fileExtension(forImageData data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier)
        else { return nil }
        return type.preferredFilenameExtension
    }

    /// The file Quick Look should read for a pasteboard image clip, written
    /// on demand and reused thereafter.
    ///
    /// Keyed by clip uuid, so paging back onto a clip a second time costs a
    /// `stat` rather than another copy of a retina screenshot. An existing
    /// file is trusted when it is non-empty — a zero-byte one is the trace of
    /// a write that died half way, and rewriting it is cheaper than showing a
    /// blank preview forever.
    ///
    /// Nothing here deletes: the caches directory is the system's to reap,
    /// and a clip that outlives its temp file simply gets it written again.
    static func fileURL(
        forClip uuid: UUID,
        imageData: Data,
        in directory: URL = QuickLookCache.directory
    ) throws -> URL? {
        guard let ext = fileExtension(forImageData: imageData) else { return nil }
        let file = directory.appendingPathComponent("\(uuid.uuidString).\(ext)")

        let manager = FileManager.default
        let existing = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if let existing, existing > 0 { return file }

        // 0700, like the store directory: these are copies of whatever the
        // user had on their clipboard, and the caches directory they land in
        // is world-readable by default.
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try imageData.write(to: file, options: [.atomic])
        return file
    }
}
