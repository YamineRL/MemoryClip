import AppKit
import SwiftUI

/// What the pinboard picker settled on (PRD 06).
enum PinboardPickerAction {
    /// Return pressed or the popover dismissed with a selection: the boards
    /// the clip should belong to. One clip belongs to at most one board, so
    /// the caller reads `first`; the set shape exists for the row toggle
    /// UI, which is multi-select shaped even though only one can apply.
    case dismiss(Set<UUID>)
    /// Return pressed with the field's text asking to become a board.
    case create(String)
    /// Esc: leave everything as it was.
    case cancel
}

/// The `P` / ⌘P popover: "which board should this clip live in?"
///
/// A type-to-filter list of the pinboards (the gmail-label picker shape),
/// deliberately: label pickers are the pattern people already know for
/// "file this under a thing that is not a folder". The current membership
/// arrives checked; toggling is one keypress on a row; Return files the
/// clip and dismisses. When the field's text names no board, a
/// "Create New Board" row at the bottom takes the whole answer instead.
///
/// Pure view: the popover holds no model context and writes nothing. It
/// reports a `PinboardPickerAction` and the caller (the panel) applies it.
struct PinboardPickerView: View {
    /// All boards, in strip order.
    let boards: [Pinboard]
    /// The boards the clip currently sits in (zero or one).
    @State var picked: Set<UUID>
    /// The text field's contents: a filter against the board names, or the
    /// name of a board to create.
    @State private var field = ""
    @FocusState private var fieldFocused: Bool
    /// The row the arrows move: `.board` or `.create`.
    @State private var cursor = 0
    let nameProposal: String
    let onAction: (PinboardPickerAction) -> Void

    init(
        boards: [Pinboard],
        selection: Set<UUID>,
        nameProposal: String,
        onAction: @escaping (PinboardPickerAction) -> Void
    ) {
        self.boards = boards
        _picked = State(initialValue: selection)
        self.nameProposal = nameProposal
        self.onAction = onAction
    }

    /// The boards the field's text has not filtered out.
    private var visibleBoards: [Pinboard] {
        let needle = field.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return boards }
        return boards.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    /// Whether the field names a board nothing is called yet, which is
    /// what makes the create row an offer rather than a duplicate. With an
    /// empty field the row offers the clip's first line instead: usually
    /// the board a clip wants is the thing it is about.
    private var creatableName: String? {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        guard let name = trimmed.isEmpty
                ? Pinboard.normalizedName(nameProposal)
                : Pinboard.normalizedName(field)
        else { return nil }
        if Pinboard.named(name, in: boards) != nil { return nil }
        return name
    }

    /// How many rows the arrows walk: the visible boards, plus the create
    /// row when the field names one.
    private var rowCount: Int {
        visibleBoards.count + (creatableName == nil ? 0 : 1)
    }

    /// Which row the cursor sits on: `.board` for a listed board, `.create`
    /// for the trailing create row.
    private enum Row: Equatable {
        case board(Pinboard)
        case create
    }

    private var cursorRow: Row? {
        let boardRows = visibleBoards
        if cursor < boardRows.count, cursor >= 0 {
            return .board(boardRows[cursor])
        }
        if creatableName != nil, cursor == boardRows.count {
            return .create
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(loc("File under…"), text: $field)
                .textFieldStyle(.plain)
                .font(.system(size: Design.Typography.bodySize))
                .focused($fieldFocused)
                .padding(.horizontal, Design.Space.loose)
                .padding(.vertical, Design.Space.roomy)
                // Typing filters; the arrows walk the rows; Return picks or
                // creates; Esc closes. The field owns all of it, and there is
                // nowhere else for the keys to go.
                .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
                    moveCursor(press.key == .downArrow ? 1 : -1)
                    return .handled
                }
                .onKeyPress(keys: [.return], phases: .down) { _ in
                    commit()
                    return .handled
                }
                .onKeyPress(.escape, phases: .down) { _ in
                    onAction(.cancel)
                    return .handled
                }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleBoards.enumerated()), id: \.element.uuid) { index, board in
                        row(board, cursor: cursor == index)
                            .onTapGesture { toggle(board) }
                    }
                    if let name = creatableName {
                        createRow(name, cursor: cursor == visibleBoards.count)
                            .onTapGesture { onAction(.create(name)) }
                    }
                    if visibleBoards.isEmpty, creatableName == nil {
                        Text(loc("No pinboards yet"))
                            .font(Design.Typography.footnote)
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .padding(.horizontal, Design.Space.loose)
                            .padding(.vertical, Design.Space.roomy)
                    }
                }
                .padding(.vertical, Design.Space.hair)
            }
            // A picker is a list that should never grow past the panel.
            .frame(maxHeight: 220)

            Divider()

            HStack(spacing: Design.Space.roomy) {
                Text(loc("↑↓ pick · ↩ file · esc close"))
                    .font(Design.Typography.keycap)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                Spacer()
                Button(loc("Done")) { onAction(.dismiss(picked)) }
                    .buttonStyle(.borderless)
                    .font(Design.Typography.footnote)
            }
            .padding(.horizontal, Design.Space.loose)
            .padding(.vertical, Design.Space.roomy)
        }
        .frame(width: 240)
        .onAppear { fieldFocused = true }
        // A typed filter that hides the cursor's row re-parks it at the top
        // rather than pointing past the end of the list.
        .onChange(of: field) { cursor = 0 }
    }

    /// One board row: colour dot, name, checkmark when the clip is filed.
    private func row(_ board: Pinboard, cursor isCursor: Bool) -> some View {
        HStack(spacing: Design.Space.roomy) {
            Circle()
                .fill(board.color)
                .frame(width: Design.Size.chipDot, height: Design.Size.chipDot)
                .accessibilityHidden(true)
            Text(board.name)
                .font(Design.Typography.chip)
                .lineLimit(1)
            Spacer()
            if picked.contains(board.uuid) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Design.Palette.accent)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Design.Space.loose)
        .padding(.vertical, Design.Space.snug)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                .fill(isCursor ? Design.Palette.accent.opacity(0.15) : .clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(board.name)
        .accessibilityAddTraits(picked.contains(board.uuid) ? [.isSelected] : [])
        .accessibilityHint(loc("Toggles the board for this clip"))
    }

    /// The trailing row the field's text becomes when it names no board:
    /// "Create New Board".
    private func createRow(_ name: String, cursor isCursor: Bool) -> some View {
        HStack(spacing: Design.Space.roomy) {
            Image(systemName: "plus.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Design.Palette.accent)
                .accessibilityHidden(true)
            Text(loc("Create \"%@\"", name))
                .font(Design.Typography.chip)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, Design.Space.loose)
        .padding(.vertical, Design.Space.snug)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                .fill(isCursor ? Design.Palette.accent.opacity(0.15) : .clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(loc("Create board \"%@\"", name))
    }

    private func moveCursor(_ delta: Int) {
        guard rowCount > 0 else { return }
        cursor = (cursor + delta + rowCount) % rowCount
    }

    /// Clicked a row: flip the board's membership. One clip sits in at most
    /// one board, so toggling a new one clears the rest.
    private func toggle(_ board: Pinboard) {
        if picked.contains(board.uuid) {
            picked.remove(board.uuid)
        } else {
            picked = [board.uuid]
        }
    }

    /// Return: the row under the cursor answers (a board toggles and files;
    /// the create row makes the board), and with no cursor the whole set as
    /// it stands is the answer.
    private func commit() {
        switch cursorRow {
        case .board(let board):
            toggle(board)
            onAction(.dismiss(picked))
        case .create:
            if let name = creatableName {
                onAction(.create(name))
            } else {
                onAction(.dismiss(picked))
            }
        case nil:
            onAction(.dismiss(picked))
        }
    }
}
