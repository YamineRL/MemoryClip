import SwiftUI

/// A setting the tour lets you change on the page that explains it.
///
/// A case names *which* existing control the page carries; `OnboardingView` is
/// the only thing that knows what it looks like, and the control itself lives
/// in `SettingsControls.swift` alongside the Settings window that renders the
/// same struct. Two consequences worth stating, because they are the point:
///
/// - Nothing here is first-run-only state. Each case maps onto a setting that
///   already existed and a UserDefaults key the Settings window already reads,
///   so a tour that is skipped, closed or re-run leaves exactly the
///   configuration the user chose — never a half-finished setup step.
/// - The flow stays pure data. A test can assert the tour still offers the
///   note destination without standing up SwiftUI.
enum OnboardingSetup: String, CaseIterable, Equatable, Sendable {
    /// The `SMAppService` login item — Settings → General → Startup.
    case launchAtLogin
    /// Where notes are written, including the vault folder picker —
    /// Settings → Notes → Destination.
    case noteDestination
}

/// One page of the first-run tour. Pure data so the flow can be tested
/// without instantiating any view.
struct OnboardingStep: Identifiable, Equatable, Sendable {
    /// Stable identifier used by tests and for `ForEach` identity.
    let id: String
    let symbol: String
    let title: String
    let subtitle: String
    let bullets: [String]
    /// The control this page offers, if it offers one. Always optional and
    /// never a gate: `Next` and `Done` ignore it entirely, so a user who
    /// touches nothing still reaches the end of the tour.
    var setup: OnboardingSetup? = nil
}

/// Step definitions plus the (pure) navigation arithmetic for the onboarding
/// window. Everything here is UI-free and unit-tested; `OnboardingView` only
/// renders it.
///
/// Copy rule: every claim below must describe behaviour that exists in the
/// shipped code — hotkeys from `HotKeys`/`PanelView`, the dropdown from
/// `StatusController`, the privacy posture from `SensitiveFilter` /
/// `AppLockService`, the note pipeline from `NoteCoordinator` /
/// `NoteSinkFactory`, and the auto-paste caveat as worded in `SettingsView`.
///
/// Which pages carry a control, and why only these: the tour is a place to
/// *start using* MemoryClip, not a second Settings window. A setting earns a
/// page when a new user has to answer it before the feature works at all
/// (where notes go — `NoteSinkFactory` throws `noDestinationConfigured` until
/// they do) or when the first launch is the only moment it is naturally asked
/// (launch at login — an app with no Dock icon is not relaunched by accident).
/// Everything else stays in Settings: the panel's own behaviour has working
/// defaults, the Touch ID lock and screenshot watching each want a decision
/// the user has not got the context for yet, and the translation language list
/// is 38 rows that start multi-hundred-megabyte system downloads — it belongs
/// beside the pipeline that reports which language it actually met.
enum OnboardingFlow {
    static let steps: [OnboardingStep] = [
        OnboardingStep(
            id: "welcome",
            symbol: "clipboard",
            title: "Welcome to MemoryClip",
            subtitle: "A menu-bar clipboard history for macOS.",
            bullets: [
                "Everything you copy — text, rich text, images, files, links, hex colors — is kept in a local history.",
                "MemoryClip lives in the menu bar (no Dock icon) and starts capturing as soon as it launches.",
                "Identical re-copies are deduplicated; old clips age out by count and by age (Settings → History).",
            ],
            setup: .launchAtLogin
        ),
        OnboardingStep(
            id: "panel",
            symbol: "command",
            title: "Open the panel with ⇧⌘V",
            subtitle: "The global hotkey is the main way in.",
            bullets: [
                "Press ⇧⌘V anywhere to toggle the clip panel; press it again (or Esc) to close.",
                "The shortcut is rebindable in Settings → Shortcuts.",
                "You can also click the clipboard glyph in the menu bar and choose “Open MemoryClip”.",
            ]
        ),
        OnboardingStep(
            id: "keyboard",
            symbol: "keyboard",
            title: "Paste without the mouse",
            subtitle: "The panel is keyboard-first: the search field always has focus.",
            bullets: [
                "Type to search across text, OCR text, colors, file names and source app; filter chips narrow by type or by the app you copied from.",
                "↑/↓ move the selection, Return pastes, ⇧Return pastes as plain text.",
                "⌘1…⌘9 instantly paste the first nine results.",
                "Space toggles the preview pane, which also offers text transforms (case, JSON, Base64, URL encode, sort/dedupe).",
                "Pin a clip from its row button or context menu — pinned clips are never removed automatically.",
            ]
        ),
        OnboardingStep(
            id: "menubar",
            symbol: "menubar.arrow.up.rectangle",
            title: "The menu-bar dropdown",
            subtitle: "For the clip you copied a moment ago.",
            bullets: [
                "The dropdown lists your last 5 clips — click one to paste it into the app you were just in.",
                "“Pause Capture” stops recording until you resume; the menu-bar glyph changes to a pause symbol.",
                "“Clear All History…” nukes everything (with a confirmation). Exporting your history as JSON or CSV lives in Settings → History.",
            ]
        ),
        OnboardingStep(
            id: "privacy",
            symbol: "lock.shield",
            title: "Private by construction",
            subtitle: "Fully on-device, permission-minimal.",
            bullets: [
                "Zero network calls: no sync, no accounts, no analytics. History lives in a local database file.",
                "No Accessibility, Screen Recording or Input Monitoring permission is required for capture, search or copy.",
                "Sensitive content is skipped: Luhn-valid card numbers, copies made in password managers, and anything marked transient/concealed on the pasteboard.",
                "Optional Touch ID lock before the panel opens (Settings → Security & Privacy, off by default).",
            ]
        ),
        OnboardingStep(
            id: "autopaste",
            symbol: "arrow.down.doc",
            title: "About automatic paste",
            subtitle: "The one place macOS can get in the way.",
            bullets: [
                "After you pick a clip, MemoryClip simulates ⌘V into the previous app.",
                "If macOS blocks synthetic key events (Accessibility not granted), the clip is still copied — just paste manually with ⌘V.",
                "Granting MemoryClip Accessibility in System Settings → Privacy & Security makes auto-paste reliable everywhere; you can also turn the attempt off in Settings → General.",
            ]
        ),
        OnboardingStep(
            id: "extras",
            symbol: "wand.and.stars",
            title: "A few extras",
            subtitle: "Available now, all on-device.",
            bullets: [
                "Image OCR: text inside screenshots is extracted with the Vision framework in the background, so you can find an image by the words in it.",
                "Queue mode: mark several clips (context menu → Add to Queue), then paste them in order with one action.",
                "Vim keys: opt in under Settings → Panel for j/k, gg/G, ⌃d/⌃u, o/⇧O, p, n, dd, q/⇧Q in normal mode; press / or i to search, Esc to go back to normal.",
            ]
        ),
        OnboardingStep(
            id: "notes",
            symbol: "note.text",
            title: "Keep a clip as a note",
            subtitle: "The one thing worth setting up now: where those notes land.",
            bullets: [
                "Any clip carrying text — including the text read out of a screenshot — can be written out: select it in the panel and press ⌘S, or choose “Save as Note” from its context menu.",
                "Where this Mac has Apple Intelligence, the on-device model gives the note a title, a summary and tags; text in another language is translated into English first. Both run here, and both are already on (Settings → Notes).",
                "Choose a destination below. The Markdown folder is the default and starts out unset — until a folder is chosen, saving a note just tells you to choose one.",
                "Screenshots can do this by themselves: Settings → Screenshots keeps new ones in your history, and Settings → Notes can write a note for every screenshot with enough text in it.",
            ],
            setup: .noteDestination
        ),
    ]

    static var count: Int { steps.count }

    /// Index of the next step, clamped to the last one (and to 0 from below).
    static func nextIndex(after index: Int) -> Int {
        clamp(clamp(index) + 1)
    }

    /// Index of the previous step, clamped to the first one.
    static func previousIndex(before index: Int) -> Int {
        clamp(clamp(index) - 1)
    }

    static func isFirst(_ index: Int) -> Bool { clamp(index) == 0 }

    static func isLast(_ index: Int) -> Bool { clamp(index) == count - 1 }

    /// Safe accessor: out-of-range indices resolve to the nearest step.
    static func step(at index: Int) -> OnboardingStep {
        steps[clamp(index)]
    }

    static func clamp(_ index: Int) -> Int {
        min(max(index, 0), count - 1)
    }
}

/// First-run tour content. Navigation state is a single clamped index; all of
/// the arithmetic lives in `OnboardingFlow`.
struct OnboardingView: View {
    /// Called when the user finishes or dismisses the tour.
    let onFinish: () -> Void

    @State private var index: Int

    /// - Parameter startingAt: which page opens. Clamped through
    ///   `OnboardingFlow` like every other index here, so no caller can open
    ///   the window on nothing. Defaulted because the tour is normally read
    ///   from the front; it is a parameter at all so a single page can be put
    ///   on screen directly rather than paged to — which is how the pages that
    ///   carry controls were rendered and checked.
    init(startingAt index: Int = 0, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _index = State(initialValue: OnboardingFlow.clamp(index))
    }

    private var step: OnboardingStep { OnboardingFlow.step(at: index) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            page
            Divider()
            footer
                .background(Design.Palette.chrome)
        }
        .frame(width: Design.Size.sheetWidth, height: Design.Size.sheetHeight)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Design.Space.loose) {
            // The welcome page leads with the app mark rather than a glyph in
            // a tile — it is the one page that introduces the app rather than
            // a feature, and it is the only place in the UI the logo appears
            // at a size worth showing. Every later step keeps the SF Symbol in
            // the same tile the clip rows use, so the tour and the panel it
            // describes share one visual language.
            if step.id == "welcome" {
                Image(nsImage: BrandMark.tileImage(pointSize: Design.Size.onboardingTile))
                    .frame(width: Design.Size.onboardingTile, height: Design.Size.onboardingTile)
                    .accessibilityHidden(true)
            } else {
                IconTile(size: Design.Size.onboardingTile, radius: Design.Radius.field) {
                    Image(systemName: step.symbol)
                        .font(.system(size: 22, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                }
                .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: Design.Space.snug) {
                Text(step.title)
                    .font(.title2.weight(.semibold))
                Text(step.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Design.Space.wide)
        .background(Design.Palette.chrome)
    }

    /// The body of a page: what the step says, then — on the pages that have
    /// one — the control that lets you act on it without leaving the tour.
    ///
    /// The control sits inside the same scroll view as the bullets rather than
    /// in a band of its own, because it is the last item of the page's
    /// argument, not a separate demand: a folder picker pinned above the
    /// footer would read as a step to complete before `Next` will let you
    /// past, which is precisely what it is not.
    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.roomy) {
                ForEach(Array(step.bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .firstTextBaseline, spacing: Design.Space.roomy) {
                        // A checkmark rather than an anonymous dot: each
                        // bullet is a thing the app already does for you.
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tint)
                            .frame(width: Design.Space.roomy)
                            .accessibilityHidden(true)
                        Text(bullet)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let setup = step.setup {
                    setupControls(for: setup)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Design.Space.wide)
        }
        // Restart the scroll position when the page changes.
        .id(step.id)
    }

    /// The Settings controls themselves — the same structs the Settings window
    /// renders, in their less verbose form. Nothing is duplicated here: this
    /// switch is the whole of the tour's knowledge of what a setting looks
    /// like.
    @ViewBuilder
    private func setupControls(for setup: OnboardingSetup) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.roomy) {
            switch setup {
            case .launchAtLogin:
                // The hint is off because the bullet above it already says
                // MemoryClip is a menu-bar app with no Dock icon.
                LaunchAtLoginToggle(showsHint: false)
            case .noteDestination:
                NoteDestinationSetup(showsDetail: false)
            }
        }
        .padding(Design.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .designPane(radius: Design.Radius.control, fill: Design.Palette.chrome)
    }

    private var footer: some View {
        HStack(spacing: Design.Space.roomy) {
            // Progress dots. The current one is a wider capsule as well as a
            // tinted one, so the position reads without relying on colour.
            HStack(spacing: Design.Space.snug) {
                ForEach(OnboardingFlow.steps) { entry in
                    let isCurrent = entry.id == step.id
                    Capsule(style: .continuous)
                        .fill(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(Design.Palette.hairline))
                        .frame(
                            width: isCurrent ? Design.Size.progressDot * 3 : Design.Size.progressDot,
                            height: Design.Size.progressDot
                        )
                }
            }
            .animation(Design.Motion.standard, value: index)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(index + 1) of \(OnboardingFlow.count)")

            Spacer()

            Button("Back") {
                index = OnboardingFlow.previousIndex(before: index)
            }
            .disabled(OnboardingFlow.isFirst(index))

            if OnboardingFlow.isLast(index) {
                Button("Done", action: onFinish)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Next") {
                    index = OnboardingFlow.nextIndex(after: index)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Design.Space.wide)
        .padding(.vertical, Design.Space.roomy)
    }
}
