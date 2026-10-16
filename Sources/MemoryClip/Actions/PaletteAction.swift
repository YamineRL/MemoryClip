import Foundation

/// One row of the command palette (⌘K): something the panel can do to the
/// clip under the cursor.
///
/// The palette and the card's context menu both ask `available(for:)` which
/// commands a clip offers, so the two cannot drift apart: a transform added
/// here appears in both, and a gate tightened here hides the item in both.
/// The gates are the ones the panel's keys already use (`canSaveNote` for ⌘S,
/// `mightHaveEvent` for ⌘E), so the keys agree with them too.
///
/// Running a command is the panel's business, not this type's: it needs the
/// selection, the editor's undo and the pinboard picker, all of which are
/// panel state. What lives here is the part that can be tested without one.
struct PaletteAction: Identifiable, Hashable {
    enum Command: Hashable, Sendable {
        case transform(Transform)
        case copy
        case pastePlain
        case saveNote
        case addToCalendar
        case pinTo
        case toggleQueue
        case showQR
        case revealInFinder

        /// Every command, in the order an empty palette lists them before
        /// run counts reorder it: the panel's own commands first, because
        /// they are the ones with keys to teach, then the transforms grouped
        /// the way the Transform submenu groups them.
        static let all: [Command] = [
            .copy, .pastePlain, .saveNote, .addToCalendar, .pinTo, .toggleQueue, .showQR, .revealInFinder
        ] + Transform.allCases.map { .transform($0) }

        /// Stable across launches and languages: it keys the run counts in
        /// UserDefaults, so it can never be a localized title.
        var id: String {
            switch self {
            case .transform(let transform): "transform." + transform.rawValue
            case .copy: "copy"
            case .pastePlain: "pastePlain"
            case .saveNote: "saveNote"
            case .addToCalendar: "addToCalendar"
            case .pinTo: "pinTo"
            case .toggleQueue: "toggleQueue"
            case .showQR: "showQR"
            case .revealInFinder: "revealInFinder"
            }
        }

        var group: String {
            switch self {
            case .transform(let transform): transform.group.label
            case .copy, .pastePlain, .showQR, .revealInFinder: loc("Clip")
            case .saveNote: loc("Note")
            case .addToCalendar: loc("Calendar")
            case .pinTo: loc("Pinboard")
            case .toggleQueue: loc("Queue")
            }
        }

        /// The key that does the same thing outside the palette. Only keys
        /// that work in every input mode: a vim letter shown to someone who
        /// has vim mode off would teach a key that types into the search.
        var shortcut: String? {
            switch self {
            case .copy: "⌘C"
            case .pastePlain: "⇧↩"
            case .saveNote: "⌘S"
            case .addToCalendar: "⌘E"
            case .pinTo: "⌘P"
            case .transform, .toggleQueue, .showQR, .revealInFinder: nil
            }
        }

        /// The gate that needs no work: what kind of clip this is and what
        /// it already has. A transform passing it is only a candidate;
        /// whether it does anything is `applicableTransforms(to:)`'s call.
        ///
        /// A secret offers only what can act on ciphertext, which is why its
        /// menu is the short one.
        @MainActor
        func passesGate(_ item: ClipItem) -> Bool {
            switch self {
            case .copy, .toggleQueue:
                true
            case .pastePlain, .pinTo:
                !item.isSecret
            case .transform:
                !item.isSecret && ClipDisplay.isTextBearing(item.kind)
            case .saveNote:
                // Also offered while OCR is pending; the export waits for it.
                ClipDisplay.canSaveNote(item) || (item.isAwaitingOCR && !item.isSecret)
            case .addToCalendar:
                ClipDisplay.mightHaveEvent(item)
            case .showQR:
                !item.isSecret && item.kind == .link
            case .revealInFinder:
                !item.isSecret && item.isScreenshot
            }
        }
    }

    /// What Return was pressed with. Only a transform has a result to
    /// place, so the panel's own commands do their one thing in every mode.
    enum Mode: Sendable {
        /// Return: paste the result into the app the panel was opened over.
        case paste
        /// ⌘Return: write the result over the clip, as a saved edit would.
        case replace
        /// ⌥Return: put the result on the clipboard and stay in the panel.
        case copy
    }

    let command: Command
    /// Resolved for the clip, because some titles say what a second run
    /// would do: "Update Note", "Remove from Queue".
    let title: String

    var id: String { command.id }
    var group: String { command.group }
    var shortcut: String? { command.shortcut }

    /// Whether this action does anything to the clip. For a transform that
    /// means running it, so a list of these is built once per palette open
    /// rather than per keystroke.
    @MainActor
    func isApplicable(to item: ClipItem) -> Bool {
        guard command.passesGate(item) else { return false }
        guard case .transform(let transform) = command else { return true }
        return Self.applies(transform, to: item.text)
    }

    /// Every action `item` offers, in catalogue order.
    ///
    /// `transforms` is the answer of `applicableTransforms(to:)` when the
    /// caller already has it: the card works it out off the main actor
    /// once per content change, since a context menu is built on every
    /// render and a JSON parse of a long clip is not something to repeat
    /// on hover. Nil runs the transforms here.
    @MainActor
    static func available(
        for item: ClipItem,
        isQueued: Bool = false,
        transforms: Set<Transform>? = nil
    ) -> [PaletteAction] {
        let applicable = transforms ?? applicableTransforms(to: item.text)
        return Command.all.compactMap { command in
            guard command.passesGate(item) else { return nil }
            if case .transform(let transform) = command, !applicable.contains(transform) {
                return nil
            }
            return PaletteAction(command: command, title: title(of: command, for: item, isQueued: isQueued))
        }
    }

    /// The transforms that change `text`. One that leaves it as it was is
    /// left out with the ones that fail: uppercasing text that is already
    /// upper case is a row that promises something and then does nothing.
    nonisolated static func applicableTransforms(to text: String?) -> Set<Transform> {
        Set(Transform.allCases.filter { applies($0, to: text) })
    }

    private nonisolated static func applies(_ transform: Transform, to text: String?) -> Bool {
        guard let text, let result = TransformService.apply(transform, to: text) else { return false }
        return result != text
    }

    @MainActor
    private static func title(of command: Command, for item: ClipItem, isQueued: Bool) -> String {
        switch command {
        case .transform(let transform): transform.label
        case .copy: loc("Copy")
        case .pastePlain: loc("Paste as Plain Text")
        case .saveNote: item.notePath == nil ? loc("Save as Note") : loc("Update Note")
        case .addToCalendar: item.calendarEventID == nil ? loc("Add to Calendar") : loc("Add to Calendar Again")
        case .pinTo: loc("Pin to…")
        case .toggleQueue: isQueued ? loc("Remove from Queue") : loc("Add to Queue")
        case .showQR: loc("Show QR Code")
        case .revealInFinder: loc("Reveal in Finder")
        }
    }

    /// The rows for a query: the actions whose title or group contains it,
    /// title matches ahead of group-only ones, then the most-run first, then
    /// catalogue order. Typing "json" therefore puts Format JSON on top until
    /// Minify JSON has been run more often.
    static func ranked(_ actions: [PaletteAction], query: String, counts: [String: Int]) -> [PaletteAction] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let scored = actions.enumerated().compactMap { offset, action -> (PaletteAction, Bool, Int, Int)? in
            let titleMatch = needle.isEmpty || action.title.localizedCaseInsensitiveContains(needle)
            guard titleMatch || action.group.localizedCaseInsensitiveContains(needle) else { return nil }
            return (action, titleMatch, counts[action.id] ?? 0, offset)
        }
        return scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 }
            if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
            return lhs.3 < rhs.3
        }.map(\.0)
    }
}

/// How often each palette action has been run, so the ones a person reaches
/// for rise to the top.
///
/// Counts only, keyed by `Command.id`: which clip an action ran on stays in
/// the history, where the user can delete it, rather than in a preference
/// file nobody looks at.
struct PaletteRunCounts {
    static let defaultsKey = "commandPalette.runCounts"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String: Int] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: Int] ?? [:]
    }

    func record(_ id: String) {
        var counts = load()
        counts[id, default: 0] += 1
        defaults.set(counts, forKey: Self.defaultsKey)
    }
}
