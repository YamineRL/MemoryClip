import Foundation

/// A navigation command produced by a vim-style keystroke.
enum VimCommand: Equatable {
    case down
    case up
    case top          // gg
    case bottom       // G
    case halfPageDown // ctrl-d
    case halfPageUp   // ctrl-u
    case paste        // Enter-equivalent (o)
    case pastePlain   // O — paste without formatting
    case pin          // p
    case delete       // dd
    case queueToggle  // q
    case queuePaste   // Q
    case enterSearch  // / — start a fresh search (clears the query)
    case enterInsert  // i — edit the existing query
    case saveNote     // n
    case addToCalendar // c
    case visual       // v — enter/leave visual mode
}

/// Modifier state relevant to vim keys.
///
/// Shift is accepted but deliberately ignored: shifted letters already arrive
/// as their uppercase character (`G`, `O`, `Q`), so the bindings key off the
/// character alone.
struct VimModifiers: OptionSet {
    let rawValue: Int
    static let control = VimModifiers(rawValue: 1 << 0)
    static let shift = VimModifiers(rawValue: 1 << 1)
}

/// Vim-style navigation for the clip panel (Phase 3).
///
/// Pure state machine: it maps keystrokes to commands (tracking multi-key
/// sequences like `gg` and `dd`) and resolves a command plus the current
/// list geometry into a new selection index. No SwiftUI, no model access —
/// the panel owns the side effects.
struct VimNavigator {
    /// Half-page jump size when the list height is unknown.
    static let defaultPageSize = 10

    /// The leading key of a pending two-key sequence (`g` or `d`), if any.
    private(set) var pending: Character?

    init(pending: Character? = nil) {
        self.pending = pending
    }

    /// Whether a two-key sequence is waiting for its second keystroke.
    var hasPending: Bool { pending != nil }

    /// Translate a keystroke into a command, consuming or opening a
    /// pending sequence as needed. Returns nil when the key is not a vim
    /// binding (the caller should let it fall through, e.g. to search).
    mutating func command(for key: Character, modifiers: VimModifiers = []) -> VimCommand? {
        if modifiers.contains(.control) {
            pending = nil
            switch key {
            case "d": return .halfPageDown
            case "u": return .halfPageUp
            default: return nil
            }
        }

        // Second key of a pending sequence.
        if let leading = pending {
            pending = nil
            switch (leading, key) {
            case ("g", "g"): return .top
            case ("d", "d"): return .delete
            default: return nil // aborted sequence swallows the key
            }
        }

        switch key {
        case "j": return .down
        case "k": return .up
        case "G": return .bottom
        case "g", "d":
            pending = key
            return nil
        case "o": return .paste
        case "O": return .pastePlain
        case "p": return .pin
        case "q": return .queueToggle
        case "Q": return .queuePaste
        case "/": return .enterSearch
        case "i": return .enterInsert
        // `n` in vim repeats the last search, and the panel has nothing to
        // repeat: its search filters the list as it is typed, so there is no
        // "next match" to jump to. That leaves the letter free, and it reads
        // as the first letter of the thing it does.
        case "n": return .saveNote
        // `c` in vim is the change operator, which waits for a motion or a
        // text object — and this panel has neither: there is nothing to change
        // in a list of clips. So the letter is free here too, and it reads as
        // the first letter of Calendar the way `n` does of Note. It fires on
        // the keystroke rather than arming a sequence, since there is no
        // second key that could complete it.
        case "c": return .addToCalendar
        // `v` is vim's own character-wise visual mode, and it means the same
        // thing here: the movement keys stop moving the cursor and start
        // dragging one end of a range behind it. A second `v` leaves, as it
        // does in vim.
        case "v": return .visual
        default: return nil
        }
    }

    /// Drop any half-typed sequence (Escape, panel reopen, search typed).
    mutating func reset() {
        pending = nil
    }

    /// New selection index after a movement command. Non-movement commands
    /// return the index unchanged. The result is always clamped into
    /// `0..<count` (or 0 for an empty list).
    static func newIndex(
        for command: VimCommand,
        index: Int,
        count: Int,
        pageSize: Int = defaultPageSize
    ) -> Int {
        guard count > 0 else { return 0 }
        let page = max(1, pageSize)
        let target: Int
        switch command {
        case .down: target = index + 1
        case .up: target = index - 1
        case .top: target = 0
        case .bottom: target = count - 1
        case .halfPageDown: target = index + page
        case .halfPageUp: target = index - page
        default: target = index
        }
        return min(max(target, 0), count - 1)
    }
}
