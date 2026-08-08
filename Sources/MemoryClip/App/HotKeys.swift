import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Toggles the clip panel. Default: ⇧⌘V.
    static let togglePanel = Self("togglePanel", default: .init(.v, modifiers: [.shift, .command]))
}
