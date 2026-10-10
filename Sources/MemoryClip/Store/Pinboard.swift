import Foundation
import SwiftData
import SwiftUI

/// A named, manually ordered group of pinned clips (PRD 06).
///
/// Pins used to be one flat list: `ClipItem.isPinned`. A pinboard is the
/// named version of the same idea. A clip filed here is still pinned
/// (membership implies `isPinned`, which is what keeps it exempt from the
/// cap and the retention sweep), but it answers to a name, a colour and a
/// position of its own.
///
/// "Pinned" in the panel is NOT a pinboard: it is the set of pinned clips
/// with no board (`isPinned && pinboard == nil`), which is exactly where
/// every pin captured before boards existed lands, untouched.
///
/// A clip belongs to at most one board (`ClipItem.pinboard` is a to-one),
/// and leaving a board never deletes the clip: deleting a board files its
/// members back into Pinned.
@Model
final class Pinboard {
    var uuid: UUID
    var name: String
    /// `PinboardColor.rawValue`: a name rather than a colour value, so the
    /// palette can be retuned without migrating stored rows.
    var colorName: String
    /// Position in the chip strip. Kept as a dense 0…n-1 sequence by
    /// `move(by:in:)`; any increasing sequence would sort the same, but a
    /// dense one has a story a reader can check by eye.
    var order: Int
    var createdAt: Date

    /// The clips filed here. Nullify rather than cascade: a board is a
    /// grouping, and deleting the grouping must never delete the clips;
    /// they land back in Pinned.
    @Relationship(deleteRule: .nullify, inverse: \ClipItem.pinboard)
    var clips: [ClipItem] = []

    init(
        uuid: UUID = UUID(),
        name: String,
        colorName: String,
        order: Int,
        createdAt: Date = .now
    ) {
        self.uuid = uuid
        self.name = name
        self.colorName = colorName
        self.order = order
        self.createdAt = createdAt
    }
}

/// The eight system colours a pinboard can take.
///
/// Stored by name (`Pinboard.colorName`) so that retuning the palette never
/// migrates a stored row. `grey` sits last rather than first: a new board
/// should read as a colour, not as the absence of one.
enum PinboardColor: String, CaseIterable, Sendable {
    case red, orange, yellow, green, teal, blue, purple, grey

    /// The chip's dot and the card badge's swatch.
    var color: Color {
        switch self {
        case .red: return Color(nsColor: .systemRed)
        case .orange: return Color(nsColor: .systemOrange)
        case .yellow: return Color(nsColor: .systemYellow)
        case .green: return Color(nsColor: .systemGreen)
        case .teal: return Color(nsColor: .systemTeal)
        case .blue: return Color(nsColor: .systemBlue)
        case .purple: return Color(nsColor: .systemPurple)
        case .grey: return Color(nsColor: .systemGray)
        }
    }

    /// The name shown in the Colour submenu and read by VoiceOver.
    var label: String {
        switch self {
        case .red: return loc("Red")
        case .orange: return loc("Orange")
        case .yellow: return loc("Yellow")
        case .green: return loc("Green")
        case .teal: return loc("Teal")
        case .blue: return loc("Blue")
        case .purple: return loc("Purple")
        case .grey: return loc("Grey")
        }
    }

    /// `raw` as a colour, or nil for a name no version has written:
    /// tolerated rather than fatal, because an import hands over whatever
    /// the file claims.
    init?(named raw: String?) {
        guard let raw, let color = PinboardColor(rawValue: raw) else { return nil }
        self = color
    }

    /// The first colour no board in `boards` is using: the assignment a new
    /// board gets, so a strip of boards starts out distinct. Once all eight
    /// are taken the wheel turns and red serves again.
    static func nextUnused(in boards: [Pinboard]) -> PinboardColor {
        let used = Set(boards.map(\.colorName))
        return allCases.first { !used.contains($0.rawValue) } ?? .red
    }
}

/// The manual ordering inside a pinboard.
///
/// Each member carries a `Double` (`ClipItem.pinboardOrder`); a move between
/// two members writes the midpoint between their values. Halving reaches a
/// floor: when the gap between the neighbours falls under `minimumGap` the
/// whole board is renumbered 0, 1, 2… and the move lands on its fresh
/// ordinal instead of writing a value that collides.
enum PinboardOrder {
    /// The smallest gap `between` will halve; tighter than this the board
    /// renumbers instead of splitting.
    static let minimumGap = 1e-9

    /// The value for a slot strictly between `lower` and `upper`. nil means
    /// "no room": the caller renumbers rather than writing a collision.
    ///
    /// The boundary cases never run out: appending steps one past the tail,
    /// and inserting at the head steps one below it.
    static func between(_ lower: Double?, _ upper: Double?) -> Double? {
        switch (lower, upper) {
        case (nil, nil):
            return 0
        case (nil, let upper?):
            return upper - 1
        case (let lower?, nil):
            return lower + 1
        case (let lower?, let upper?):
            let gap = upper - lower
            guard gap >= minimumGap else { return nil }
            return lower + gap / 2
        }
    }

    /// The order for a member appended to `board`'s tail.
    static func appending(to board: Pinboard) -> Double {
        (board.orderedClips.last?.pinboardOrder ?? -1) + 1
    }

    /// Rewrite `members`' orders as a dense 0…n-1 in their current sequence.
    static func renumber(_ members: [ClipItem]) {
        for (index, member) in members.enumerated() {
            member.pinboardOrder = Double(index)
        }
    }

    /// Board-order comparator: ordered members ascending, then unordered
    /// ones (a clip filed before orders existed, or one whose order was
    /// never written) last, newest first among ties.
    static func comesBefore(_ lhs: ClipItem, _ rhs: ClipItem) -> Bool {
        let a = lhs.pinboardOrder ?? .greatestFiniteMagnitude
        let b = rhs.pinboardOrder ?? .greatestFiniteMagnitude
        if a != b { return a < b }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.uuid.uuidString < rhs.uuid.uuidString
    }
}

extension Pinboard {
    /// The longest name a board may carry, counted as the user counts it:
    /// in grapheme clusters.
    static let maximumNameLength = 40

    /// `raw` trimmed, or nil when what is left is not a name a board may
    /// carry (empty, or over `maximumNameLength`).
    static func normalizedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...maximumNameLength).contains(name.count) ? name : nil
    }

    /// Every board in chip order.
    ///
    /// A fetch does not reliably see rows still pending a save, so the
    /// context's un-saved inserts are folded in: `create` and the import
    /// merge must both see the board a caller just made but has not stored.
    static func all(in context: ModelContext) -> [Pinboard] {
        var boards = context.fetchLogged(
            FetchDescriptor<Pinboard>(sortBy: [SortDescriptor(\Pinboard.order)])
        ) ?? []
        // The mirror image on the way out: a row deleted but not yet saved
        // still answers a fetch, and a dead board must not keep answering
        // `named(_:)` or holding a chip spot for the rest of the statement.
        let pendingDeletes = Set(context.deletedModelsArray.compactMap {
            ($0 as? Pinboard)?.uuid
        })
        boards.removeAll { pendingDeletes.contains($0.uuid) }
        for case let board as Pinboard in context.insertedModelsArray
        where !boards.contains(where: { $0.uuid == board.uuid }) {
            boards.append(board)
        }
        return boards.sorted { $0.order < $1.order }
    }

    /// The board named `name`, matched case-insensitively: the one question
    /// behind the chip strip, the duplicate-name guard and the import merge.
    static func named(_ name: String, in context: ModelContext) -> Pinboard? {
        named(name, in: all(in: context))
    }

    /// The board named `name` among `boards`, matched case-insensitively;
    /// the array form for callers holding the strip's boards already.
    static func named(_ name: String, in boards: [Pinboard]) -> Pinboard? {
        boards.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    /// The board's colour as a `Color`: the stored name looked up, grey for
    /// a name no version has written.
    var color: Color {
        (PinboardColor(named: colorName) ?? .grey).color
    }

    /// Create a board. Nil when the name fails `normalizedName` or is
    /// already taken (case-insensitively). `color` is an optional hint;
    /// absent or unknown names fall to the next unused colour.
    ///
    /// Mutates only. The caller saves, so a create can ride inside a wider
    /// transaction (an import files clips into the board it just made).
    @discardableResult
    static func create(named raw: String, color rawColor: String? = nil, in context: ModelContext) -> Pinboard? {
        guard let name = normalizedName(raw), named(name, in: context) == nil else { return nil }
        let boards = all(in: context)
        let board = Pinboard(
            name: name,
            colorName: (PinboardColor(named: rawColor) ?? PinboardColor.nextUnused(in: boards)).rawValue,
            order: (boards.map(\.order).max() ?? -1) + 1
        )
        context.insert(board)
        return board
    }

    /// Rename under the same rules `create` enforces. False (nothing
    /// changed) when the name is invalid or already belongs to another board.
    @discardableResult
    func rename(to raw: String, in context: ModelContext) -> Bool {
        guard let name = Pinboard.normalizedName(raw) else { return false }
        if let existing = Pinboard.named(name, in: context), existing.uuid != uuid { return false }
        self.name = name
        return true
    }

    /// Move the board `delta` places along the chip strip. The whole row is
    /// renumbered afterwards: `order` is a dense sequence, and a swap is
    /// only worth keeping if the numbering says so.
    func move(by delta: Int, in context: ModelContext) {
        var boards = Pinboard.all(in: context)
        guard let from = boards.firstIndex(where: { $0.uuid == uuid }) else { return }
        let to = from + delta
        guard boards.indices.contains(to) else { return }
        boards.swapAt(from, to)
        for (index, board) in boards.enumerated() { board.order = index }
    }

    /// Delete the board. Its members land in Pinned (pinned, unboarded) and
    /// none of them is deleted: a board is a grouping, not ownership.
    func delete(in context: ModelContext) {
        for clip in clips {
            clip.pinboard = nil
            clip.pinboardOrder = nil
        }
        context.delete(self)
    }

    /// Members in the board's manual order (see `PinboardOrder`).
    var orderedClips: [ClipItem] {
        clips.sorted(by: PinboardOrder.comesBefore)
    }
}

extension ClipItem {
    /// File the clip into `board`: pinned (a member must survive the cap
    /// and the retention sweep), and into at most one board, so filing a
    /// clip that is already filed elsewhere moves it. `order` places it in
    /// the board's manual order; nil appends past the tail.
    ///
    /// Mutates only. The caller saves.
    func file(into board: Pinboard, order: Double? = nil) {
        let slot = order ?? PinboardOrder.appending(to: board)
        pinboard = board
        pinboardOrder = slot
        isPinned = true
    }

    /// Drop the board, keep the pin: the clip lands in Pinned.
    func removeFromBoard() {
        pinboard = nil
        pinboardOrder = nil
    }

    /// Pin to Pinned: pinned and deliberately board-less. Choosing the
    /// Pinned row in the picker is this, not a bare `isPinned` write; a clip
    /// already filed somewhere has to leave its board too.
    func pinToPinned() {
        isPinned = true
        pinboard = nil
        pinboardOrder = nil
    }

    /// Unpin entirely. A board member leaves its board with the pin.
    func unpin() {
        isPinned = false
        pinboard = nil
        pinboardOrder = nil
    }

    /// Move to slot `target` within `board`'s manual order.
    ///
    /// Writes the midpoint between the new neighbours; when the gap is too
    /// tight to halve, or any member still lacks an order, the whole board
    /// is renumbered first, so a move can never leave two clips tied.
    func move(within board: Pinboard, to target: Int) {
        var members = board.orderedClips
        guard let from = members.firstIndex(where: { $0.uuid == uuid }) else { return }
        if members.contains(where: { $0.pinboardOrder == nil }) {
            PinboardOrder.renumber(members)
        }
        members.remove(at: from)
        let slot = min(max(target, 0), members.count)
        members.insert(self, at: slot)
        let lower = slot > 0 ? members[slot - 1].pinboardOrder : nil
        let upper = slot + 1 < members.count ? members[slot + 1].pinboardOrder : nil
        if let order = PinboardOrder.between(lower, upper) {
            pinboardOrder = order
        } else {
            PinboardOrder.renumber(members)
        }
    }

    /// One step along the board: `⌥←` is -1, `⌥→` is +1.
    func move(within board: Pinboard, by delta: Int) {
        guard let index = board.orderedClips.firstIndex(where: { $0.uuid == uuid }) else { return }
        move(within: board, to: index + delta)
    }
}
