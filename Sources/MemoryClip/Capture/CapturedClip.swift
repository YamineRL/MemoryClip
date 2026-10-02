import Foundation

/// A pasteboard snapshot taken by the watcher, not yet persisted.
struct CapturedClip: Sendable {
    var kind: ClipKind
    var text: String?
    var richTextData: Data?
    var imageData: Data?
    var fileURLStrings: [String]
    var colorHex: String?
    var hash: String
    /// The URL as it was copied, when `text` holds a cleaned version of it.
    var originalText: String?

    init(
        kind: ClipKind,
        text: String? = nil,
        richTextData: Data? = nil,
        imageData: Data? = nil,
        fileURLStrings: [String] = [],
        colorHex: String? = nil,
        hash: String,
        originalText: String? = nil
    ) {
        self.kind = kind
        self.text = text
        self.richTextData = richTextData
        self.imageData = imageData
        self.fileURLStrings = fileURLStrings
        self.colorHex = colorHex
        self.hash = hash
        self.originalText = originalText
    }
}
