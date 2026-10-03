import AppIntents
import Foundation

/// A clip as Shortcuts and Spotlight see it: a stable id plus the fields
/// a picker or a result list can show. `text` carries the content for
/// text-bearing clips and is nil for images and secrets — nothing an
/// intent hands out ever holds a secret's plaintext.
struct ClipEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Clip")
    static let defaultQuery = ClipEntityQuery()

    let id: UUID
    let title: String
    let kind: ClipKind
    let created: Date
    let sourceApp: String?
    let text: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(created.formatted(date: .abbreviated, time: .shortened))",
            image: .init(systemName: Self.symbolName(for: kind))
        )
    }

    init(clip: ClipItem) {
        id = clip.uuid
        title = Self.title(for: clip)
        kind = clip.kind
        created = clip.createdAt
        sourceApp = clip.sourceAppName
        // Secrets have no `text` on the row at all once feat/secrets is
        // merged, so this stays nil for them without a special case; the
        // masked title comes from `title(for:)` below.
        text = clip.kind == .image ? nil : clip.text
    }

    /// The kind's SF Symbol, mirroring the card's glyph choice.
    static func symbolName(for kind: ClipKind) -> String {
        switch kind {
        case .text, .richText: return "doc.plaintext"
        case .image: return "photo"
        case .link: return "link"
        case .file: return "doc"
        case .color: return "paintpalette"
        }
    }

    /// "First line, or refined title, or file name" — the same fallback
    /// chain the card uses, ending on the kind's own name.
    ///
    /// On the integration branch a secret resolves here too: its `text` is
    /// nil, so the mask on `secretMasked` becomes the title instead of the
    /// first line — add `if clip.isSecret { return clip.secretMasked ?? … }`
    /// there.
    static func title(for clip: ClipItem) -> String {
        if let refined = clip.refinedTitle, !refined.isEmpty {
            return refined
        }
        if let text = clip.text,
           let line = text.split(separator: "\n", maxSplits: 1).first {
            return String(line)
        }
        if let name = clip.fileURLStrings.first.map(ClipDisplay.displayName), !name.isEmpty {
            return name
        }
        return ClipDisplay.kindLabel(clip.kind, isScreenshot: clip.isScreenshot)
    }
}

/// How the Shortcuts clip picker resolves and searches entities.
///
/// Both entry points go through `ClipIntentService`, so the picker's
/// matching is the panel's matching (`ClipFilter` over the store) and the
/// lock gate covers browsing as well as running.
struct ClipEntityQuery: EntityStringQuery {
    func entities(for identifiers: [ClipEntity.ID]) async throws -> [ClipEntity] {
        guard let service = await ClipIntentService.live() else { return [] }
        var found: [ClipEntity] = []
        for id in identifiers {
            if let entity = try await service.resolve(id) {
                found.append(entity)
            }
        }
        return found
    }

    func entities(matching string: String) async throws -> [ClipEntity] {
        guard let service = await ClipIntentService.live() else { return [] }
        return try await service.search(query: string, limit: ClipIntentService.searchLimitMax)
    }

    func suggestedEntities() async throws -> [ClipEntity] {
        guard let service = await ClipIntentService.live() else { return [] }
        return try await service.search(query: "", limit: 20)
    }
}
