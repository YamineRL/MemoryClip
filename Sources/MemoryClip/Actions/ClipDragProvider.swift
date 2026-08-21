import AppKit

/// Turns a clip into the `NSItemProvider` a drag out of the panel carries.
///
/// Deliberately built on `PasteService.payload(for:plainOnly:)` rather than
/// mapping the kinds a second time: a drop and a paste have to hand over the
/// same thing, and two mappings would eventually disagree about which one a
/// screenshot gets. That payload is also validated before anything is
/// registered, so a clip carrying nothing droppable yields no provider instead
/// of an empty drag the destination has to refuse.
///
/// The one place a drag differs from a paste is arity: `onDrag` yields exactly
/// one provider, so a multi-file clip drags its first file.
@MainActor
enum ClipDragProvider {
    /// The provider for a clip, or nil when the clip carries nothing a drop
    /// could take.
    static func itemProvider(for item: ClipItem) -> NSItemProvider? {
        guard let payload = PasteService.payload(for: item, plainOnly: false) else { return nil }
        return provider(for: payload)
    }

    /// The provider for an already-validated payload.
    static func provider(for payload: PasteService.Payload) -> NSItemProvider? {
        // File URLs are checked first and win outright: a screenshot clip is a
        // reference to a picture the user's screenshot folder owns, and the
        // drop has to receive that path so Finder copies it and a mail
        // composer attaches it. Registering the bytes instead would hand over
        // a second, detached copy of a file that already exists.
        if let url = payload.urls.first {
            // Registers the file's own type ("public.png") alongside
            // `public.file-url`, from the path alone — the bytes are never
            // read here.
            return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
        }

        guard !payload.entries.isEmpty else { return nil }
        let provider = NSItemProvider()
        // Registration order is preference order: a destination takes the
        // first representation it understands, and `payload` already lists RTF
        // before the plain text under it.
        for entry in payload.entries {
            register(entry, on: provider)
        }
        return provider
    }

    /// Pasteboard types carry UTIs here (`public.utf8-plain-text`,
    /// `public.rtf`, `public.png`), which is what an item provider registers
    /// against.
    private static func register(_ entry: PasteService.Payload.Entry, on provider: NSItemProvider) {
        switch entry {
        case let .string(type, value):
            provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all) { completion in
                completion(Data(value.utf8), nil)
                return nil
            }
        case let .data(type, value):
            provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all) { completion in
                completion(value, nil)
                return nil
            }
        }
    }
}
