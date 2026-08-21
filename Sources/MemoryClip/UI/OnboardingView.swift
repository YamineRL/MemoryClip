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
    /// The synthetic ⌘V, which Accessibility can silently refuse —
    /// Settings → General → Pasting.
    case autoPaste
    /// Where notes are written, including the vault folder picker —
    /// Settings → Notes → Destination.
    case noteDestination
    /// Automatic calendar events, which is also where the write-only calendar
    /// permission is asked for — Settings → Calendar → Adding events.
    case calendarEvents
    /// The daily update check, the one setting that decides whether the app
    /// touches the network at all — Settings → General → Updates.
    case updateChecks
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
/// Which pages carry a control, and why they come first: the tour is a place
/// to *start using* MemoryClip, not a second Settings window, so a setting
/// earns a page only where the app cannot answer it on the user's behalf —
/// where notes go (`NoteSinkFactory` throws `noDestinationConfigured` until
/// someone picks a folder), whether events may be written (a TCC grant the
/// automatic path is forbidden to ask for itself), whether macOS will let the
/// synthetic ⌘V through, and launch at login, which an app with no Dock icon
/// will never be asked again by accident.
///
/// Those four pages run first and the reading matter last, because attention
/// is spent in the order it is given: a decision buried on page seven is a
/// decision made by whoever gives up before reaching it. Everything else stays
/// in Settings — the panel's own behaviour has working defaults, the Touch ID
/// lock wants a decision the user has not got the context for yet, and the
/// translation language list is 38 rows that start multi-hundred-megabyte
/// system downloads.
enum OnboardingFlow {
    static let steps: [OnboardingStep] = [
        OnboardingStep(
            id: "welcome",
            symbol: "clipboard",
            title: loc("Welcome to MemoryClip"),
            subtitle: loc("A menu-bar clipboard history for macOS."),
            bullets: [
                loc("Everything you copy — text, rich text, images, files, links, hex colors — is kept in a history on this Mac. Identical re-copies are deduplicated; old clips age out by count and by age (Settings → History)."),
                loc("MemoryClip lives in the menu bar (no Dock icon) and starts capturing as soon as it launches."),
                loc("Nothing you copy leaves this Mac: no sync, no accounts, no analytics. Luhn-valid card numbers, copies made in password managers and anything marked concealed on the pasteboard are skipped entirely. The only network call MemoryClip can make is the update check a few pages on, and it is off until you switch it on."),
            ],
            setup: .launchAtLogin
        ),
        OnboardingStep(
            id: "panel",
            symbol: "command",
            title: loc("Open the panel with ⇧⌘V"),
            subtitle: loc("The hotkey is the main way in; pasting back out is the one thing macOS can block."),
            bullets: [
                loc("Press ⇧⌘V anywhere to toggle the panel — ↑/↓ move the selection, Return pastes, ⇧Return pastes as plain text, and ⌘1…⌘9 paste the first nine results. Esc closes."),
                loc("Type to search across text, OCR text, colors, file names and the app you copied from; Space opens the preview, and again on a picture or a file opens Quick Look full size."),
                loc("Picking a clip simulates ⌘V into the app you came from. If macOS blocks the synthetic key event the clip is still on the clipboard — granting MemoryClip Accessibility in System Settings → Privacy & Security makes it reliable everywhere."),
                loc("The menu-bar glyph holds your last 5 clips, Pause Capture and Settings. The hotkey itself is rebindable in Settings → Shortcuts."),
            ],
            setup: .autoPaste
        ),
        OnboardingStep(
            id: "notes",
            symbol: "note.text",
            title: loc("Keep a clip as a note"),
            subtitle: loc("This is the one thing that needs a folder before it works."),
            bullets: [
                loc("Any clip carrying text — including the text read out of a screenshot — can be written out: select it in the panel and press ⌘S, or choose “Save as Note” from its context menu."),
                loc("Where this Mac has Apple Intelligence, the on-device model gives the note a title, a summary and tags (Settings → Notes); text in another language is translated into English first (Settings → Translation). Both run here, and both are already on."),
                loc("Choose a destination below. The Markdown folder is the default and starts out unset — until a folder is chosen, saving a note just tells you to choose one."),
            ],
            setup: .noteDestination
        ),
        OnboardingStep(
            id: "calendar",
            symbol: "calendar.badge.plus",
            title: loc("Turn a clip into an event"),
            subtitle: loc("A time, a meeting link, an address — read straight out of the text."),
            bullets: [
                loc("Select a clip that names a date and press ⌘E, or choose “Add to Calendar” from its context menu. The title, the start, the end, the meeting link and the address all come out of what you copied."),
                loc("Switch automatic events on below and a clip naming a time of day plus a meeting link or an address is added on its own; a bare date is left alone. Each one arrives as a notification carrying an Undo button."),
                loc("macOS asks once. MemoryClip asks only for permission to add events — it cannot read your calendar, so events go to whichever calendar is your default for new ones (Settings → Calendar)."),
            ],
            setup: .calendarEvents
        ),
        OnboardingStep(
            id: "updates",
            symbol: "arrow.down.circle",
            title: loc("Getting the next version"),
            subtitle: loc("MemoryClip does not update itself, and will not go looking unless you say so."),
            bullets: [
                loc("Installed with Homebrew? “brew upgrade --cask memoryclip” is all of it, and you can leave the switch below alone."),
                loc("Otherwise there is nothing to tell you a new version exists — MemoryClip has no Dock icon, no window and no sync, so a release can sit on GitHub for months unnoticed."),
                loc("Switch this on and once a day MemoryClip asks github.com what the newest release is. Nothing about you is sent: it is an anonymous read of a public page, and if there is nothing newer, nothing happens at all."),
                loc("When there is, you get one notification. Take it and MemoryClip downloads that release and opens the disk image, with Applications sitting right beside the app — the same drag as the first time. Nothing is installed behind your back."),
            ],
            setup: .updateChecks
        ),
        OnboardingStep(
            id: "extras",
            symbol: "wand.and.stars",
            title: loc("A few more things"),
            subtitle: loc("All on-device, all waiting in Settings when you want them."),
            bullets: [
                loc("Image OCR: text inside screenshots is extracted with the Vision framework in the background, so you can find a picture by the words in it."),
                loc("Screenshots can look after themselves — Settings → Screenshots keeps new ones in your history, and Settings → Notes can write a note for every screenshot with enough text in it."),
                loc("Pin a clip and it is never removed automatically; queue several (context menu → Add to Queue) and paste them in order; transform text in the preview (case, JSON, Base64, URL encode, sort/dedupe)."),
                loc("Optional Touch ID before the panel opens (Settings → Privacy), and vim keys for j/k, gg/G, ⌃d/⌃u, o/⇧O, p, n, c, dd, q/⇧Q (Settings → Panel)."),
                loc("This tour is in Settings → About whenever you want it again."),
            ]
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
            case .autoPaste:
                // Likewise: the Accessibility caveat is a bullet on this page.
                AutoPasteToggle(showsHint: false)
            case .noteDestination:
                NoteDestinationSetup(showsDetail: false)
            case .calendarEvents:
                // `showsDetail: false` keeps the switch and the missing-grant
                // callout and drops the rest; what qualifies as an event is
                // the page's second bullet.
                CalendarAutoCreateSetup(showsDetail: false)
            case .updateChecks:
                // The page's bullets already name the host and say what is
                // sent, so the control's own line would be the third telling.
                UpdateCheckToggle(showsHint: false)
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
            .accessibilityLabel(loc("Step %d of %d", index + 1, OnboardingFlow.count))

            Spacer()

            Button(loc("Back")) {
                index = OnboardingFlow.previousIndex(before: index)
            }
            .disabled(OnboardingFlow.isFirst(index))

            if OnboardingFlow.isLast(index) {
                Button(loc("Done"), action: onFinish)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(loc("Next")) {
                    index = OnboardingFlow.nextIndex(after: index)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Design.Space.wide)
        .padding(.vertical, Design.Space.roomy)
    }
}
