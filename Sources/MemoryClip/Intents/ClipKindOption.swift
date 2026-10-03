import AppIntents
import Foundation

/// The `kind` parameter the intents expose, mirroring the panel's
/// `TypeFilter` one to one so "image" means the same thing in Shortcuts
/// that it does in a filter chip.
///
/// Titles stay literals rather than lookups: the metadata extractor
/// const-folds them at compile time, and the French names resolve at
/// display through the shared strings table.
enum ClipKindOption: String, AppEnum {
    case any
    case text
    case image
    case link
    case file
    case color

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Clip kind")

    static let caseDisplayRepresentations: [ClipKindOption: DisplayRepresentation] = [
        .any: "Any",
        .text: "Text",
        .image: "Image",
        .link: "Link",
        .file: "File",
        .color: "Color",
    ]

    /// The panel filter this option stands for.
    var typeFilter: TypeFilter {
        switch self {
        case .any: return .all
        case .text: return .text
        case .image: return .image
        case .link: return .link
        case .file: return .file
        case .color: return .color
        }
    }
}
