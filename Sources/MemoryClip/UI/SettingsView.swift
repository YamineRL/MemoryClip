import SwiftUI
import ServiceManagement
import KeyboardShortcuts

/// Settings window content: a sidebar of panes beside the selected pane.
///
/// Was a `TabView` of eight `tabItem`s. Eight is past what a tab strip can
/// carry — the labels crowd until they are unreadable, and a tab strip offers
/// no keyboard route between panes at all, so the only way to reach Notes was
/// to aim at it. A `NavigationSplitView` fixes both at once: the sidebar has
/// room to name and group all eight, and a `List` with a selection binding is
/// arrow-key navigable and VoiceOver-navigable for free.
///
/// The window, not this view, owns the frame (see `SettingsWindowController`).
/// A settings window that resizes as you move between panes is the classic
/// tell of a hand-rolled one, so no pane is allowed to size the window: each
/// fills whatever it is given and scrolls if it must.
struct SettingsView: View {
    /// Survives closing the window, so reopening Settings lands where you left
    /// it — the whole point of a navigable window is that you can be somewhere
    /// in it.
    @AppStorage(SettingsKeys.settingsPane) private var pane: SettingsPane = .default

    /// Focus is explicit because arrow-key navigation is the headline feature
    /// here and it only works when the list is first responder. Left to
    /// itself, a freshly ordered-in window puts first responder on the window,
    /// so the first arrow key press would go nowhere.
    @FocusState private var focus: Focus?

    private enum Focus: Hashable {
        case sidebar
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
        } detail: {
            detail
        }
        // `.balanced` keeps the sidebar a peer of the detail pane rather than
        // an overlay that can slide away: in a settings window the index is
        // permanent furniture, not a disclosure.
        .navigationSplitViewStyle(.balanced)
        // Left alone, SwiftUI hands first responder to the first focusable
        // control in the *detail* pane — General's launch-at-login switch — so
        // the arrow keys do nothing until the sidebar has been clicked once,
        // which is exactly the problem this rebuild exists to solve.
        //
        // Both halves are needed. `defaultFocus` states the intent for every
        // later focus reset; the deferred assignment is what actually claims
        // first responder on the very first appearance, because at `onAppear`
        // the hosting view is not yet in a key window and a focus request made
        // then is dropped. One runloop turn later the window is key and it
        // sticks. AppKit remembers first responder across close/reopen, so
        // this runs once and every subsequent opening lands on the sidebar too.
        .defaultFocus($focus, .sidebar, priority: .userInitiated)
        .onAppear {
            DispatchQueue.main.async { focus = .sidebar }
        }
    }

    private var sidebar: some View {
        List(selection: $pane) {
            ForEach(SettingsPane.groups) { group in
                // Two spellings rather than an `if let` inside one `Section`,
                // because a `Section` given an `EmptyView` header still
                // reserves its header slot.
                if let title = group.title {
                    Section(title) { rows(of: group) }
                } else {
                    Section { rows(of: group) }
                }
            }
        }
        .listStyle(.sidebar)
        .focused($focus, equals: .sidebar)
        .navigationSplitViewColumnWidth(
            min: Design.Size.settingsSidebarMinWidth,
            ideal: Design.Size.settingsSidebarWidth,
            max: Design.Size.settingsSidebarMaxWidth
        )
        .accessibilityLabel("Settings panes")
    }

    private func rows(of group: SettingsPaneGroup) -> some View {
        ForEach(group.panes) { entry in
            Label {
                Text(entry.title)
            } icon: {
                SettingsIcon(symbol: entry.symbol, tint: entry.tint)
            }
            // The tag is what makes the row selectable, which is what makes
            // ↑/↓ move between panes.
            .tag(entry)
            // The glyph is decorative (`SettingsIcon` hides itself), so the
            // row would otherwise announce as just its title — which is right,
            // but only by accident. Stating it keeps it right if the row ever
            // gains a badge.
            .accessibilityLabel(entry.title)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeader(pane: pane)
            Divider()
            pane.content
        }
        // Top alignment so a short pane (History) sits under its header
        // instead of floating in the middle of the window.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // `NavigationSplitView` retitles the window from the detail pane, and
        // left to itself it would put the pane name there — directly above the
        // header band that already says it, twice in 40 points. System
        // Settings can get away with the pane name alone because it is the
        // only settings window on the Mac; MemoryClip's is one of many, and a
        // window called "General" says nothing about whose General it is.
        .navigationTitle(SettingsWindowController.windowTitle)
    }
}

/// The band at the top of every pane.
///
/// Carries two things a tab strip used to: which pane you are in, and its
/// glyph, so the sidebar row and the pane you landed on are visibly the same
/// thing. Fixed height regardless of pane, which is what puts every pane's
/// first control on the same y.
private struct SettingsPaneHeader: View {
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: Design.Space.roomy) {
            SettingsIcon(
                symbol: pane.symbol,
                tint: pane.tint,
                size: Design.Size.settingsHeaderIcon,
                radius: Design.Radius.control
            )
            Text(pane.title)
                .font(.title2.weight(.semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Space.wide)
        .padding(.vertical, Design.Space.roomy)
        // The same chrome the onboarding window puts behind its header, so
        // MemoryClip's two "framed content" windows are framed the same way.
        .background(Design.Palette.chrome)
        // One element, so VoiceOver reads "General, heading" rather than
        // stepping through a decorative tile to reach the word.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SettingsPane {
    /// The pane's form. Unchanged from the tabbed version — this rebuild
    /// re-housed the panes, it did not redesign them.
    @MainActor
    @ViewBuilder
    var content: some View {
        switch self {
        case .general: GeneralSettingsPane()
        case .shortcuts: ShortcutsSettingsPane()
        case .history: HistorySettingsPane()
        case .panel: PanelSettingsPane()
        case .privacy: PrivacySettingsPane()
        case .screenshots: ScreenshotSettingsPane()
        case .notes: NotesSettingsPane()
        case .about: AboutSettingsPane()
        }
    }
}

// MARK: - Shared pieces

/// The explanatory line that sits under a settings control.
///
/// Was repeated ten times as `Text(...).font(.caption).foregroundStyle(.secondary)`;
/// naming it keeps every hint on the same size, colour and wrapping rule, and
/// gives one place to adjust the contrast of the whole settings window.
private struct SettingsHint: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            // Long hints must wrap rather than being truncated to one line.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The tinted, rounded glyph that leads a settings row.
///
/// Gives every control the same leading slot, so a form of otherwise
/// unrelated toggles and pickers scans as one column instead of a wall of
/// left-aligned sentences. The colour is what distinguishes a row at a
/// glance; the symbol says which one.
private struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = Design.Size.settingsIcon
    var radius: CGFloat = Design.Radius.small

    /// The glyph is set at 55% of the tile — the ratio the 20-point row tile
    /// was already drawn at — so the larger header tile is the same badge
    /// scaled up rather than a second, differently-proportioned one.
    private var glyphSize: CGFloat { size * 0.55 }

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: glyphSize, weight: .semibold))
                    // The tiles are saturated system colours, which macOS
                    // tunes to stay legible under white in both appearances.
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// An inline message that has to be noticed — currently only the
/// launch-at-login failure.
///
/// A bare red caption disappears into a grouped form; a tinted, outlined
/// block with its own glyph reads as "something went wrong here" without
/// resorting to an alert.
private struct SettingsCallout: View {
    let text: String
    var symbol: String = "exclamationmark.triangle.fill"
    // `.systemRed`, which macOS retunes per appearance, rather than the flat
    // `.red` that reads muddy on a dark form background.
    var tint: Color = Color(nsColor: .systemRed)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.snug) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .padding(.horizontal, Design.Space.roomy)
        .padding(.vertical, Design.Space.normal)
        .designPane(radius: Design.Radius.control, fill: tint.opacity(0.12))
    }
}

/// One key combination in the Shortcuts pane, drawn as a cap.
///
/// Matches the ⌘1…⌘9 hints in the panel's rows, so the same keystroke looks
/// the same wherever MemoryClip mentions it.
private struct ShortcutCap: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(Color(nsColor: .labelColor))
            .padding(.horizontal, Design.Space.snug)
            .padding(.vertical, Design.Space.hair)
            .designPane(radius: Design.Radius.tiny, fill: Design.Palette.surface)
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @AppStorage(SettingsKeys.autoPaste) private var autoPaste = true
    @AppStorage(SettingsKeys.appearance) private var appearance: AppearanceSetting = .system

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle(isOn: launchAtLoginBinding) {
                    Label {
                        Text("Launch at login")
                    } icon: {
                        SettingsIcon(symbol: "power", tint: Color(nsColor: .systemGreen))
                    }
                }
                if let launchAtLoginError {
                    SettingsCallout(text: launchAtLoginError)
                }
                SettingsHint("MemoryClip runs as a menu-bar app: no Dock icon, no window until you open the panel.")
            }

            Section("Appearance") {
                Picker(selection: $appearance) {
                    ForEach(AppearanceSetting.allCases) { option in
                        Text(option.title).tag(option)
                    }
                } label: {
                    Label {
                        Text("Theme")
                    } icon: {
                        SettingsIcon(symbol: "circle.lefthalf.filled", tint: Color(nsColor: .systemIndigo))
                    }
                }
                .pickerStyle(.segmented)
                SettingsHint("Applies to the clipboard panel and every MemoryClip window. \"System\" follows your macOS Appearance setting.")
            }

            Section("Pasting") {
                Toggle(isOn: $autoPaste) {
                    Label {
                        Text("Paste automatically after selecting a clip")
                    } icon: {
                        SettingsIcon(symbol: "arrow.down.doc.fill", tint: Color(nsColor: .systemBlue))
                    }
                }
                SettingsHint("MemoryClip simulates ⌘V into the previous app. If macOS blocks the synthetic key event (Accessibility not granted), the clip is still on the clipboard — paste manually with ⌘V.")
            }
        }
        .formStyle(.grouped)
        // `@AppStorage` persists the choice but nothing acts on it; the app's
        // appearance is AppKit state that has to be pushed to `NSApp`.
        .onChange(of: appearance) { _, newValue in
            applyAppearanceSetting(newValue)
        }
    }

    /// Binds the toggle to SMAppService so registration errors surface in-UI.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    launchAtLoginError = nil
                } catch {
                    launchAtLoginError = launchAtLoginMessage(for: error)
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        )
    }

    /// Turns SMAppService's opaque failures into something a user can act on.
    ///
    /// The common one is `EINVAL` ("Invalid argument"), which launchd returns
    /// when the bundle lives outside `/Applications` — running the app straight
    /// out of `dist/` hits this every time. The raw message gives no hint of
    /// that, so name the actual requirement.
    private func launchAtLoginMessage(for error: Error) -> String {
        let bundlePath = Bundle.main.bundleURL.path
        let installed =
            bundlePath.hasPrefix("/Applications/")
            || bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
        if !installed {
            return "Launch at login needs MemoryClip in your Applications folder. Move MemoryClip.app there, reopen it, and try again."
        }
        return error.localizedDescription
    }
}

// MARK: - History

private struct HistorySettingsPane: View {
    @AppStorage(SettingsKeys.historyCap) private var historyCap = 200
    @AppStorage(SettingsKeys.retentionDays) private var retentionDays = 30

    var body: some View {
        Form {
            Section("Limits") {
                Stepper(value: $historyCap, in: 10...10_000, step: 50) {
                    Label {
                        Text("Keep up to \(historyCap) clips")
                    } icon: {
                        SettingsIcon(symbol: "tray.full.fill", tint: Color(nsColor: .systemTeal))
                    }
                }
                Picker(selection: $retentionDays) {
                    Text("Forever").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                } label: {
                    Label {
                        Text("Delete clips older than")
                    } icon: {
                        SettingsIcon(symbol: "clock.arrow.circlepath", tint: Color(nsColor: .systemOrange))
                    }
                }
                SettingsHint("Pinned clips are exempt from both limits and are never deleted automatically.")
            }

            Section("Storage") {
                SettingsHint("History lives in a local SwiftData file on this Mac. Clear it any time from the menu-bar menu (\"Clear All History…\") or the panel's nuke button.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Panel

private struct PanelSettingsPane: View {
    @AppStorage(SettingsKeys.vimMode) private var vimMode = false
    @AppStorage(OCRCoordinator.enabledKey) private var ocrEnabled = true

    var body: some View {
        Form {
            Section("Search") {
                Toggle(isOn: $ocrEnabled) {
                    Label {
                        Text("Extract text from images (OCR)")
                    } icon: {
                        SettingsIcon(symbol: "text.viewfinder", tint: Color(nsColor: .systemPurple))
                    }
                }
                SettingsHint("Runs on-device with the Vision framework, in the background, so image clips can be found by the text inside them.")
            }

            Section("Navigation") {
                Toggle(isOn: $vimMode) {
                    Label {
                        Text("Vim navigation keys")
                    } icon: {
                        SettingsIcon(symbol: "keyboard.fill", tint: Color(nsColor: .systemGray))
                    }
                }
                SettingsHint("Gives the panel vim modes: it opens in NORMAL mode where j/k-style keys navigate, and / or i switches to INSERT mode for searching (Esc returns). The current mode is shown in the search bar. See the Shortcuts pane for the full list.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy

private struct PrivacySettingsPane: View {
    var body: some View {
        Form {
            Section("Lock") {
                Toggle(isOn: appLockBinding) {
                    Label {
                        Text("Require Touch ID to open the panel")
                    } icon: {
                        SettingsIcon(symbol: "touchid", tint: Color(nsColor: .systemPink))
                    }
                }
                SettingsHint(AppLockService.shared.isAvailable
                     ? "Uses the system LocalAuthentication prompt, with a passcode fallback."
                     : "No biometric hardware or enrollment detected — the lock fails open, so the panel still opens.")
            }

            Section("Capture") {
                Toggle(isOn: sensitiveFilterBinding) {
                    Label {
                        Text("Skip capturing sensitive content")
                    } icon: {
                        SettingsIcon(symbol: "eye.slash.fill", tint: Color(nsColor: .systemRed))
                    }
                }
                SettingsHint("Skips likely card numbers (Luhn-validated) and anything copied in a known password manager. Pasteboard opt-out markers (transient, auto-generated, concealed) are always respected.")
            }

            Section("Permissions") {
                SettingsHint("Detection is based on the source app's identity — MemoryClip never reads window titles or the screen, so it needs no Screen Recording or Accessibility permission. Accessibility is optional and only affects the synthetic ⌘V used for auto-paste.")
            }
        }
        .formStyle(.grouped)
    }

    /// Manual binding to the @MainActor AppLockService singleton.
    private var appLockBinding: Binding<Bool> {
        Binding(
            get: { AppLockService.shared.isEnabled },
            set: { AppLockService.shared.isEnabled = $0 }
        )
    }

    /// Manual binding to the sensitive-content filter's UserDefaults key
    /// (default registered as `true` at launch).
    private var sensitiveFilterBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: SensitiveFilter.filteringEnabledKey) },
            set: { UserDefaults.standard.set($0, forKey: SensitiveFilter.filteringEnabledKey) }
        )
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettingsPane: View {
    var body: some View {
        Form {
            Section("Global") {
                KeyboardShortcuts.Recorder(for: .togglePanel) {
                    Text("Toggle panel:")
                }
                SettingsHint("Works system-wide. Click the field and press the keys you want.")
            }

            ForEach(ShortcutReference.groups) { group in
                Section(group.title) {
                    ForEach(group.entries) { entry in
                        LabeledContent {
                            Text(entry.detail)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            ShortcutCap(keys: entry.keys)
                        }
                    }
                    if let note = group.note {
                        SettingsHint(note)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutSettingsPane: View {
    /// The app icon's edge on the About screen.
    private static let iconSize: CGFloat = 72

    private let version = AppVersionInfo()

    var body: some View {
        ScrollView {
            VStack(spacing: Design.Space.normal) {
                // The shipped app icon when there is one — this is the
                // "who am I" screen, so it should show the same artwork the
                // user sees in Finder. `swift run` has no bundle icon, so a
                // tiled glyph stands in.
                Group {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: Self.iconSize, height: Self.iconSize)
                            .shadow(color: Design.Palette.cardShadow, radius: Design.Space.normal, y: Design.Space.tight)
                    } else {
                        IconTile(size: Self.iconSize, radius: Design.Space.wide) {
                            Image(systemName: "clipboard")
                                .font(.system(size: 34, weight: .regular))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .padding(.top, Design.Space.vast)
                .padding(.bottom, Design.Space.tight)
                .accessibilityHidden(true)

                Text(AppVersionInfo.appName)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.top, Design.Space.tight)

                Text(version.displayString)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .padding(.horizontal, Design.Space.roomy)
                    .padding(.vertical, Design.Space.tight)
                    .background(Capsule(style: .continuous).fill(Design.Palette.surface))

                Text("A keyboard-first clipboard history for macOS, living in the menu bar.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.top, Design.Space.tight)

                Text("Everything happens on this Mac: clips are stored in a local SwiftData file, and MemoryClip makes no network calls — no sync, no accounts, no analytics. It needs no Accessibility or Screen Recording permission to capture, search and copy clips; Accessibility is optional and only lets auto-paste send a synthetic ⌘V.")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .multilineTextAlignment(.center)
                    .padding(Design.Space.roomy)
                    .designPane(radius: Design.Radius.field, fill: Design.Palette.chrome)
                    .padding(.top, Design.Space.normal)

                Button {
                    OnboardingController.shared.show()
                } label: {
                    Label("Show Introduction Again", systemImage: "sparkles")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.top, Design.Space.roomy)

                Text("Re-opens the first-run tour of the panel, shortcuts and privacy model.")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .multilineTextAlignment(.center)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Design.Space.vast + Design.Space.loose)
            .padding(.bottom, Design.Space.vast)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Screenshots

/// Screenshot capture: the folder to watch, and what a captured screenshot
/// actually costs.
///
/// The folder is picked through `NSOpenPanel` rather than typed in, because
/// the folder that matters (`~/Desktop`, by default) is one macOS guards —
/// choosing it in a panel is what grants access. See `FolderBookmark`.
private struct ScreenshotSettingsPane: View {
    @AppStorage(NoteSettingsKeys.screenshotCaptureEnabled) private var captureEnabled = false
    @AppStorage(OCRCoordinator.enabledKey) private var ocrEnabled = true

    /// Resolved lazily in `onAppear`: the value depends on a bookmark and on
    /// another app's preferences, neither of which belongs in a property
    /// initialiser.
    @State private var folder: URL?

    var body: some View {
        Form {
            Section("Capture") {
                Toggle(isOn: $captureEnabled) {
                    Label {
                        Text("Keep screenshots in history")
                    } icon: {
                        SettingsIcon(symbol: "camera.viewfinder", tint: Color(nsColor: .systemGreen))
                    }
                }
                SettingsHint("⇧⌘3 and ⇧⌘4 save a file and never touch the clipboard, so MemoryClip cannot see them otherwise. With this on, each new screenshot appears in your history.")
            }

            Section("Folder") {
                LabeledContent {
                    Button("Choose…") { chooseFolder() }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: Design.Space.hair) {
                            Text("Watching")
                            Text(folderDisplayPath)
                                .font(.caption)
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } icon: {
                        SettingsIcon(symbol: "folder.fill", tint: Color(nsColor: .systemBlue))
                    }
                }
                SettingsHint("Defaults to wherever macOS saves screenshots. MemoryClip needs your permission to read that folder, which is what choosing it here grants.")
            }

            Section("What gets stored") {
                SettingsHint("A link, not a copy: the clip points at the screenshot where it already is, plus a small thumbnail. Deleting a clip — or letting it expire — never deletes your file.")
                Toggle(isOn: $ocrEnabled) {
                    Label {
                        Text("Extract text from images (OCR)")
                    } icon: {
                        SettingsIcon(symbol: "text.viewfinder", tint: Color(nsColor: .systemPurple))
                    }
                }
                SettingsHint("Reads the text in each screenshot on-device so you can search for it. The same setting as the one in the Panel pane; it is repeated here because it is what makes a screenshot findable.")
            }
        }
        .formStyle(.grouped)
        .onAppear { folder = ScreenshotWatcher.resolvedFolder() }
    }

    private var folderDisplayPath: String {
        (folder ?? ScreenshotWatcher.resolvedFolder()).path(percentEncoded: false)
    }

    private func chooseFolder() {
        let chosen = FolderBookmark.choose(
            key: NoteSettingsKeys.screenshotFolderBookmark,
            title: "Choose Screenshot Folder",
            message: "Pick the folder macOS saves your screenshots to. MemoryClip watches it for new files.",
            startingAt: folder ?? ScreenshotDetector.configuredLocation()
        )
        guard let chosen else { return }
        folder = chosen
        NotificationCenter.default.post(name: .memoryClipScreenshotFolderChanged, object: nil)
    }
}

// MARK: - Notes

/// The local model and where its output is written.
private struct NotesSettingsPane: View {
    @AppStorage(NoteSettingsKeys.refineEnabled) private var refineEnabled = true
    @AppStorage(NoteSettingsKeys.autoNoteEnabled) private var autoNoteEnabled = false
    @AppStorage(NoteSettingsKeys.autoNoteMinimumCharacters) private var minimumCharacters = 80
    @AppStorage(NoteSettingsKeys.destination) private var destinationRaw = NoteDestination.markdownVault.rawValue
    @AppStorage(NoteSettingsKeys.copyAttachments) private var copyAttachments = true
    @AppStorage(NoteSettingsKeys.vaultAttachmentFolder) private var attachmentFolder = "attachments"
    @AppStorage(NoteSettingsKeys.notesAppFolder) private var notesAppFolder = "MemoryClip"
    @AppStorage(NoteSettingsKeys.shortcutName) private var shortcutName = ""

    @State private var vault: URL?

    private var destination: NoteDestination {
        NoteDestination(rawValue: destinationRaw) ?? .markdownVault
    }

    var body: some View {
        Form {
            Section("Local model") {
                Toggle(isOn: $refineEnabled) {
                    Label {
                        Text("Clean up extracted text with the on-device model")
                    } icon: {
                        SettingsIcon(symbol: "wand.and.sparkles", tint: Color(nsColor: .systemIndigo))
                    }
                }
                if let unavailable = FoundationModelsRefiner.unavailabilityDescription() {
                    SettingsCallout(text: unavailable, symbol: "info.circle.fill", tint: Color(nsColor: .systemOrange))
                }
                SettingsHint("Apple's on-device model fixes OCR slips, rejoins wrapped lines and gives each note a title and summary. It runs on this Mac — nothing is uploaded. The raw extracted text is always kept alongside it, so nothing the model writes replaces what was actually on screen.")
            }

            Section("Destination") {
                Picker(selection: $destinationRaw) {
                    ForEach(NoteDestination.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                } label: {
                    Label {
                        Text("Write notes to")
                    } icon: {
                        SettingsIcon(symbol: "square.and.arrow.down.fill", tint: Color(nsColor: .systemTeal))
                    }
                }
                .pickerStyle(.segmented)

                switch destination {
                case .markdownVault:
                    markdownOptions
                case .notesApp:
                    notesAppOptions
                case .shortcut:
                    shortcutOptions
                }
            }

            Section("When") {
                Toggle(isOn: $autoNoteEnabled) {
                    Label {
                        Text("Write a note for every screenshot")
                    } icon: {
                        SettingsIcon(symbol: "bolt.fill", tint: Color(nsColor: .systemYellow))
                    }
                }
                if autoNoteEnabled {
                    Stepper(value: $minimumCharacters, in: 0...2000, step: 20) {
                        Text("…with at least \(minimumCharacters) characters of text")
                    }
                }
                SettingsHint(autoNoteEnabled
                    ? "Off by default for a reason: a busy day of screenshots is a busy day of notes. The character threshold skips the ones with nothing worth keeping."
                    : "Notes are written when you ask for one — select a clip in the panel and choose Save as Note. Turn this on to have every screenshot with enough text write itself.")
            }
        }
        .formStyle(.grouped)
        .onAppear { vault = FolderBookmark.resolve(key: NoteSettingsKeys.vaultBookmark) }
    }

    @ViewBuilder
    private var markdownOptions: some View {
        LabeledContent {
            Button("Choose…") { chooseVault() }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: Design.Space.hair) {
                    Text("Folder")
                    Text(vault?.path(percentEncoded: false) ?? "Not chosen yet")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } icon: {
                SettingsIcon(symbol: "folder.fill", tint: Color(nsColor: .systemBlue))
            }
        }
        Toggle("Copy the screenshot into the folder", isOn: $copyAttachments)
        if copyAttachments {
            TextField("Attachments subfolder", text: $attachmentFolder)
        }
        SettingsHint("Plain Markdown files with YAML front matter — an Obsidian vault, or anything else that reads .md off disk. Copying the screenshot in is what lets the note embed it, and means the note survives you clearing out your Desktop.")
    }

    @ViewBuilder
    private var notesAppOptions: some View {
        TextField("Notes folder", text: $notesAppFolder)
        SettingsCallout(
            text: "Notes is the one destination that needs a permission: macOS will ask to let MemoryClip control it the first time. The screenshot goes in as a link — Notes does not accept an image through automation.",
            symbol: "lock.fill",
            tint: Color(nsColor: .systemOrange)
        )
    }

    @ViewBuilder
    private var shortcutOptions: some View {
        TextField("Shortcut name", text: $shortcutName)
        SettingsHint("MemoryClip runs this Shortcut with the note as its input, so anything Shortcuts can reach — Bear, Things, DEVONthink, a folder in iCloud — can be the destination.")
    }

    private func chooseVault() {
        let chosen = FolderBookmark.choose(
            key: NoteSettingsKeys.vaultBookmark,
            title: "Choose Note Folder",
            message: "Pick the folder MemoryClip should write notes into — an Obsidian vault, or any folder of Markdown files.",
            startingAt: vault
        )
        guard let chosen else { return }
        vault = chosen
    }
}

extension Notification.Name {
    /// Posted when the user picks a different screenshot folder, so the
    /// watcher can re-point without a relaunch.
    static let memoryClipScreenshotFolderChanged = Notification.Name("memoryClipScreenshotFolderChanged")
}
