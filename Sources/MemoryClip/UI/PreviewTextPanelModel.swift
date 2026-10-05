import CoreGraphics

/// The two texts the preview's text panel can show.
enum PreviewTextTab: Equatable, Sendable {
    /// The clip's own text, or what was recognised in its picture.
    case original
    /// That text read back in the user's language.
    case translation
}

/// The rules behind the preview's text panel: which tabs it offers, which one
/// it shows, when it may switch on its own, and how tall it is.
///
/// Pure and free of SwiftUI so every rule is testable without a window. The
/// view feeds it the presenter's state as it changes and the user's picks,
/// and draws whatever `visibleTab` says.
///
/// The auto-switch is the rule the type exists for. A translation streams in
/// chunk by chunk, and switching to it on the first chunk would move the text
/// out from under someone reading the original. So the panel stays where it
/// is while the work runs and switches at most once, when it finishes, and
/// never after the user has picked a tab for this clip.
struct PreviewTextPanelModel: Equatable {
    /// Whether the presenter holds a translation, partial or finished.
    private(set) var hasTranslation = false
    /// Whether the presenter is still making one.
    private(set) var isTranslating = false
    /// The tab chosen, by the user or by the one automatic switch.
    private(set) var selected: PreviewTextTab
    /// The tab the user picked for this clip, nil until they pick one. The
    /// view records it as the session's preference for the clips after it.
    private(set) var explicitPick: PreviewTextTab?
    /// Whether the one automatic switch this clip is allowed has happened.
    private(set) var didAutoSwitch = false
    /// The user's last explicit pick on an earlier clip this session, or nil
    /// when they have not made one.
    let preference: PreviewTextTab?

    init(preference: PreviewTextTab? = nil) {
        self.preference = preference
        selected = .original
    }

    /// The tabs on offer: the original alone, or both once a translation is
    /// being made or has been made.
    var availableTabs: [PreviewTextTab] {
        hasTranslation || isTranslating ? [.original, .translation] : [.original]
    }

    /// The tab to draw. Falls back to the original when the selected tab is
    /// not on offer, so a translation that goes away never leaves the panel
    /// empty.
    var visibleTab: PreviewTextTab {
        availableTabs.contains(selected) ? selected : .original
    }

    /// Take in the presenter's state.
    ///
    /// Switches to the translation once, when a run finishes with a result,
    /// unless the user picked a tab for this clip or last picked the original.
    /// A translation that arrives already finished (from the cache) opens on
    /// the translation only for a user whose last pick was the translation.
    mutating func update(hasTranslation: Bool, isTranslating: Bool) {
        let finished = self.isTranslating && !isTranslating && hasTranslation
        let arrivedReady = !self.hasTranslation && hasTranslation && !isTranslating && !self.isTranslating
        self.hasTranslation = hasTranslation
        self.isTranslating = isTranslating

        guard explicitPick == nil, !didAutoSwitch, preference != .original else { return }
        if finished || (arrivedReady && preference == .translation) {
            selected = .translation
            didAutoSwitch = true
        }
    }

    /// The user chose `tab`. No automatic switch follows for this clip.
    mutating func pick(_ tab: PreviewTextTab) {
        selected = tab
        explicitPick = tab
    }

    /// Flip between the two tabs, as ⌘T does. Nothing happens while the
    /// original is the only tab.
    mutating func toggle() {
        guard availableTabs.count > 1 else { return }
        pick(visibleTab == .original ? .translation : .original)
    }

    /// How tall the panel is under an image clip's picture:
    /// `previewTextPanelHeight` at the pane's default height, plus a share of
    /// whatever the drag handle added past it.
    ///
    /// Depends on the pane alone and never on the text, so a translation
    /// streaming in cannot resize the panel or move the picture above it.
    static func panelHeight(paneHeight: CGFloat?) -> CGFloat {
        let base = Design.Size.previewTextPanelHeight
        guard let paneHeight else { return base }
        let extra = max(0, paneHeight - Design.Size.previewPaneHeight)
        return base + extra * Design.Size.previewTextPanelGrowthShare
    }
}

/// The tab the user last picked in the preview's text panel, kept for the
/// rest of the app session so the next clip opens the way they prefer.
@MainActor
enum PreviewTextTabPreference {
    /// Nil until the user picks a tab.
    static var lastPick: PreviewTextTab?
}
