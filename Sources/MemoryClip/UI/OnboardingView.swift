import SwiftUI

/// One page of the first-run tour. Pure data so the flow can be tested
/// without instantiating any view.
struct OnboardingStep: Identifiable, Equatable, Sendable {
    /// Stable identifier used by tests and for `ForEach` identity.
    let id: String
    let symbol: String
    let title: String
    let subtitle: String
    let bullets: [String]
}

/// Step definitions plus the (pure) navigation arithmetic for the onboarding
/// window. Everything here is UI-free and unit-tested; `OnboardingView` only
/// renders it.
///
/// Copy rule: every claim below must describe behaviour that exists in the
/// shipped code — hotkeys from `HotKeys`/`PanelView`, the dropdown from
/// `StatusController`, the privacy posture from `SensitiveFilter` /
/// `AppLockService`, and the auto-paste caveat as worded in `SettingsView`.
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
            ]
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
                "“Clear All History…” nukes everything (with a confirmation), and history can be exported as JSON or CSV.",
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
                "Vim keys: opt in under Settings → Panel for j/k, gg/G, ⌃d/⌃u, o/⇧O, p, dd, q/⇧Q in normal mode; press / or i to search, Esc to go back to normal.",
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

    @State private var index = 0

    private var step: OnboardingStep { OnboardingFlow.step(at: index) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            bullets
            Divider()
            footer
                .background(Design.Palette.chrome)
        }
        .frame(width: Design.Size.sheetWidth, height: Design.Size.sheetHeight)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Design.Space.loose) {
            // The step glyph in the same tile the clip rows use, so the tour
            // and the panel it describes share one visual language.
            IconTile(size: Design.Size.onboardingTile, radius: Design.Radius.field) {
                Image(systemName: step.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
            }
            .accessibilityHidden(true)

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

    private var bullets: some View {
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
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Design.Space.wide)
        }
        // Restart the scroll position when the page changes.
        .id(step.id)
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
