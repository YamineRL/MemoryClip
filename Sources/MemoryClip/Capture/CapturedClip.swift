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
}
