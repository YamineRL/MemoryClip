import Foundation

/// Editing a clip's text inside the preview pane.
///
/// The rules that decide whether a clip offers the action live in
/// `ClipDisplay.canEdit`; what saving does to the row lives in
/// `ClipStore.applyEdit`. This type holds what is left: the session state the
/// panel keeps while an edit is open, the snapshot a save hands back for the
/// panel's in-memory undo, and the small pure decisions both sides share.
enum ClipEdit {
    /// One open editing session: which clip, the live draft, and what the
    /// next Escape does.
    ///
    /// Held by the panel as `@State`. `item` is the live model: the editor
    /// reads the clip's kind from it, and `draft` is what the text view is
    /// editing. Nothing here is persisted: the whole session exists only
    /// while the panel is alive.
    struct Session {
        /// Fresh for every open, and used as the editor view's identity, so
        /// reopening always gets a clean text view instead of one that still
        /// holds the previous clip's undo stack and selection.
        let id = UUID()
        let item: ClipItem
        /// The clip's text when the session opened; the reference "unsaved"
        /// is measured against. A restored draft still counts as unsaved
        /// changes: it was never written to the store.
        let savedText: String
        var draft: String {
            // Kept typing after the warn means the draft is wanted again:
            // the next Escape asks once more rather than discarding over a
            // keystroke the user never saw as an answer.
            didSet { discardArmed = false }
        }
        /// First-Escape confirm armed: the inline "discard?" notice is up,
        /// and a second Escape throws the draft away.
        var discardArmed = false
        /// Whether the draft came back from a stash rather than from the
        /// clip; drives the "Unsaved draft restored." toast.
        let restoredDraft: Bool

        var hasChanges: Bool { draft != savedText }

        init(item: ClipItem, draft: String?, restoredDraft: Bool) {
            self.item = item
            savedText = item.text ?? ""
            self.draft = draft ?? savedText
            self.restoredDraft = restoredDraft
        }
    }

    /// What a clip looked like just before a save replaced its text, kept so
    /// the panel's session undo can put it back.
    ///
    /// `kind` alone would not be enough: the hash has to move back with it or
    /// the restored clip deduplicates against the wrong payload, and the
    /// colour hex is the `color` kind's payload, not derived state.
    struct Snapshot: Equatable {
        let uuid: UUID
        let text: String?
        let richTextData: Data?
        let kind: ClipKind
        let colorHex: String?
        let contentHash: String
    }

    /// Whether the draft opens monospaced.
    ///
    /// Only for clips whose content the preview already renders monospaced:
    /// a colour's hex is the one place today; code-looking text is a display
    /// choice the cards do not make, so plain text stays in the body font.
    static func prefersMonospaced(for item: some ClipDisplayable) -> Bool {
        item.kind == .color
    }

    /// What one press of Escape does while an edit is open. The layering is
    /// a pure decision so the two-step discard is testable without a view.
    enum EscapeAction: Equatable {
        /// Nothing to lose: leave the editor at once.
        case leave
        /// Unsaved changes and no confirm yet: show the inline notice.
        case confirmDiscard
        /// The notice is already up: throw the draft away and leave.
        case discard
    }

    static func escapeAction(hasChanges: Bool, discardArmed: Bool) -> EscapeAction {
        guard hasChanges else { return .leave }
        return discardArmed ? .discard : .confirmDiscard
    }
}
