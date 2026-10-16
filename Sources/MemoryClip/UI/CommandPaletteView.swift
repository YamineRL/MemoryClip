import SwiftUI

/// The ⌘K popover: every action the cursor clip offers, filtered as you type.
///
/// The same shape as `PinboardPickerView` on purpose, a field over a list
/// with the arrows walking it, so the panel has one picker idiom rather than
/// two. Each row names its group and, when there is one, the key that does
/// the same thing without the palette: the palette is also how those keys
/// are found.
///
/// Pure view, like the picker: it runs nothing itself. It reports the chosen
/// action and how Return was pressed, and the panel carries it out.
struct CommandPaletteView: View {
    /// What the clip offers, in catalogue order.
    let actions: [PaletteAction]
    /// Run counts at the moment the palette opened. A count that moved while
    /// it was open would reorder the rows under the cursor.
    let counts: [String: Int]
    let onRun: (PaletteAction, PaletteAction.Mode) -> Void
    let onCancel: () -> Void

    @State private var field = ""
    @FocusState private var fieldFocused: Bool
    @State private var cursor = 0

    private var rows: [PaletteAction] {
        PaletteAction.ranked(actions, query: field, counts: counts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(loc("Run an action…"), text: $field)
                .textFieldStyle(.plain)
                .font(.system(size: Design.Typography.bodySize))
                .focused($fieldFocused)
                .padding(.horizontal, Design.Space.loose)
                .padding(.vertical, Design.Space.roomy)
                .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
                    moveCursor(press.key == .downArrow ? 1 : -1)
                    return .handled
                }
                .onKeyPress(keys: [.return], phases: .down) { press in
                    commit(mode: Self.mode(for: press.modifiers))
                    return .handled
                }
                .onKeyPress(.escape, phases: .down) { _ in
                    onCancel()
                    return .handled
                }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, action in
                            row(action, cursor: cursor == index)
                                .onTapGesture { onRun(action, .paste) }
                        }
                        if rows.isEmpty {
                            Text(loc("No matching actions"))
                                .font(Design.Typography.footnote)
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                .padding(.horizontal, Design.Space.loose)
                                .padding(.vertical, Design.Space.roomy)
                        }
                    }
                    .padding(.vertical, Design.Space.hair)
                }
                // The arrows walk past the fold: follow the cursor, scrolling
                // no further than it takes to bring the row into view.
                .onChange(of: cursor) {
                    let visible = rows
                    guard visible.indices.contains(cursor) else { return }
                    proxy.scrollTo(visible[cursor].id)
                }
            }
            // Twice the picker's height: there are three times as many rows,
            // and the point of the list is to be read.
            .frame(maxHeight: 300)

            Divider()

            Text(loc("↩ paste · ⌘↩ replace · ⌥↩ copy · esc close"))
                .font(Design.Typography.keycap)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .padding(.horizontal, Design.Space.loose)
                .padding(.vertical, Design.Space.roomy)
        }
        .frame(width: 320)
        .onAppear { fieldFocused = true }
        .onChange(of: field) { cursor = 0 }
    }

    /// ⌘ wins over ⌥ when both are held: replacing is the deliberate one of
    /// the two, and nothing should be written over a clip by a stray chord.
    static func mode(for modifiers: EventModifiers) -> PaletteAction.Mode {
        if modifiers.contains(.command) { return .replace }
        if modifiers.contains(.option) { return .copy }
        return .paste
    }

    private func row(_ action: PaletteAction, cursor isCursor: Bool) -> some View {
        HStack(spacing: Design.Space.roomy) {
            Text(action.title)
                .font(Design.Typography.chip)
                .lineLimit(1)
            Spacer()
            Text(action.group)
                .font(Design.Typography.footnote)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
            if let shortcut = action.shortcut {
                Text(shortcut)
                    .font(Design.Typography.keycap)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
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
        .accessibilityLabel(action.title)
        .accessibilityValue(action.group)
        .accessibilityAddTraits(isCursor ? [.isButton, .isSelected] : .isButton)
    }

    private func moveCursor(_ delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        cursor = (cursor + delta + count) % count
    }

    private func commit(mode: PaletteAction.Mode) {
        let visible = rows
        guard visible.indices.contains(cursor) else { return }
        onRun(visible[cursor], mode)
    }
}
