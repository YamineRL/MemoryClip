import SwiftUI
import KeyboardShortcuts
#if canImport(Translation)
import Translation
#endif

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

// MARK: - Pane furniture

// `SettingsHint`, `SettingsIcon`, `SettingsCallout`, the launch-at-login
// switch and the note-destination picker used to live here as private types.
// They moved to `SettingsControls.swift` when the first-run tour started
// offering the same setup, so both windows render one implementation instead
// of two that can drift. What is left below is used by this window only.

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

    var body: some View {
        Form {
            Section("Startup") {
                LaunchAtLoginToggle()
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

            // Export sits in History rather than Privacy because it acts on
            // the same thing the rest of this pane governs — the whole stored
            // history, all of it at once — while Privacy's switches are
            // capture policy, deciding what is allowed into that history in
            // the first place. It was in the menu-bar dropdown until this
            // pane existed to hold it; a dropdown of the last five clips is
            // no place for an action that hands over every clip ever taken.
            Section("Export") {
                // A row per format, each the same `LabeledContent` shape the
                // Screenshots pane's folder row uses, rather than one row with
                // a pair of "JSON…"/"CSV…" buttons beside it. Two buttons in a
                // row is what the AX tree cannot describe: a `LabeledContent`
                // hands its label to whatever it contains, so both buttons
                // came back named "Export every clip", and moving them out to
                // a hand-built HStack left them named nothing at all (a bare
                // SwiftUI Button here exposes neither its title nor an
                // `.accessibilityLabel` — checked against the running app).
                // One button per labelled row is the shape that is announced
                // correctly, and it reads no worse.
                LabeledContent {
                    Button("Export…") { HistoryExportController.shared.exportHistory(asCSV: false) }
                } label: {
                    Label {
                        Text("Every clip as JSON")
                    } icon: {
                        SettingsIcon(symbol: "curlybraces", tint: Color(nsColor: .systemBlue))
                    }
                }
                LabeledContent {
                    Button("Export…") { HistoryExportController.shared.exportHistory(asCSV: true) }
                } label: {
                    Label {
                        Text("Every clip as CSV")
                    } icon: {
                        SettingsIcon(symbol: "tablecells", tint: Color(nsColor: .systemGreen))
                    }
                }
                SettingsHint("Writes every clip to one unencrypted file, readable by your user account only. JSON carries images and rich text as Base64; CSV is text, source app and timestamps only. MemoryClip spells out what the file will contain before writing it, and — with the Touch ID lock on — asks you to authenticate every time, even if you unlocked it a moment ago.")
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

                Text("Re-opens the first-run tour of the panel, shortcuts and privacy model, where the note destination and launch-at-login can also be set.")
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

// MARK: - Translation downloads

/// The language list and its per-language readiness, held outside any view.
///
/// Both are properties of the Mac, not of a pane: the same answer serves
/// every instance of the picker, and asking for it costs 22 IPC round trips.
/// Holding it here rather than in `@State` also survives the pane being
/// rebuilt — a view that is discarded takes its state box with it, and the
/// async load that was filling it then lands in a box nothing renders from.
/// That is not hypothetical: rendering the pane to an image showed the
/// language rows with a permanently blank readiness column, because the load
/// completed into a discarded copy of the view.
///
/// `@Observable`, so a body that reads `menu` or `readiness` re-runs when the
/// load finishes, whichever instance of the picker happens to be on screen.
@MainActor
@Observable
final class TranslationLanguageStore {
    static let shared = TranslationLanguageStore()

    private(set) var menu: [TranslationLanguage] = []
    /// The same list with nothing dropped, for the preview pane's target
    /// picker: English is not a source the note pipeline can be asked about,
    /// but it is a perfectly good language to read a clip in.
    private(set) var targets: [TranslationLanguage] = []
    private(set) var readiness: [String: TranslationReadiness] = [:]
    /// The in-flight load, so several pickers appearing at once (or a pane
    /// rebuilt mid-load) share one pass instead of racing.
    private var loading: Task<Void, Never>?

    private init() {}

    /// Load once. Cheap and idempotent afterwards, which is what lets the
    /// view call it from `.task` without guarding.
    func loadIfNeeded(using translator: any NoteTranslator) async {
        if !menu.isEmpty { return }
        if let loading { return await loading.value }
        let task = Task { @MainActor [weak self] in
            // One trip to the framework, two menus: the sources the note
            // pipeline can translate, and every language a clip can be read in.
            let languages = await translator.supportedLanguages()
            let rows = TranslationCatalog.menu(from: languages, excluding: NoteTranslation.target)
            self?.menu = rows
            self?.targets = TranslationCatalog.menu(from: languages)
            self?.readiness = await Self.readinessMap(for: rows, using: translator)
        }
        loading = task
        await task.value
        loading = nil
    }

    /// Re-read one language, after a download claims to have finished.
    func refresh(_ language: TranslationLanguage, using translator: any NoteTranslator) async {
        readiness[language.id] = await translator.readiness(for: language.language)
    }

    /// Readiness for every row, gathered concurrently — 38 serial status
    /// calls measured 316 ms against 125 ms in parallel, and this runs while
    /// the pane is being looked at.
    private static func readinessMap(
        for rows: [TranslationLanguage],
        using translator: any NoteTranslator
    ) async -> [String: TranslationReadiness] {
        await withTaskGroup(of: (String, TranslationReadiness).self) { group in
            for row in rows {
                group.addTask { (row.id, await translator.readiness(for: row.language)) }
            }
            var out: [String: TranslationReadiness] = [:]
            for await (id, value) in group { out[id] = value }
            return out
        }
    }
}

/// The languages to detect and translate, and the downloads that only a view
/// can start.
///
/// This exists because of a hard split in the Translation framework: a
/// session built outside SwiftUI reports `canRequestDownloads == false` and
/// can never fetch a language asset, while one created by the
/// `.translationTask` modifier can — it puts up the system's own download
/// prompt, and macOS then fetches the pack into its shared asset store, where
/// every app that translates can use it.
///
/// The note pipeline necessarily has the first kind (it runs in the
/// background, off any view), so it records what was missing in
/// `NoteTranslation.pendingDownloads` — but waiting to be told is a poor way
/// to find out. Every language Apple can translate into English is listed
/// here, each with a checkbox: ticking one both opts it into the pipeline and
/// fetches its assets if they are absent. Several can be ticked at once; the
/// downloads queue, because a session can only prepare one pair at a time.
private struct TranslationLanguagePicker: View {
    /// The catalog lives outside the view — see `TranslationLanguageStore`.
    private var store: TranslationLanguageStore { .shared }

    @State private var selected: Set<String> = Set(NoteTranslation.enabledLanguages)
    @State private var pending: [String] = NoteTranslation.pendingDownloads
    @State private var expanded = false
    #if canImport(Translation)
    @State private var configuration: TranslationSession.Configuration?
    #endif
    /// Ticked languages whose assets are missing, oldest first. The head is
    /// the one being fetched.
    @State private var queue: [TranslationLanguage] = []
    @State private var failure: String?

    private let translator = AppleTranslator()

    var body: some View {
        Group {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(store.menu) { language in
                    row(for: language)
                }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: Design.Space.hair) {
                        Text("Languages")
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                } icon: {
                    SettingsIcon(symbol: "globe", tint: Color(nsColor: .systemBlue))
                }
            }
            // Both attached HERE rather than to the Group: a Group is
            // transparent, so a modifier on it is applied to every child
            // individually — three copies of the same work, two of them on
            // callouts that come and go and take their copy with them. The
            // disclosure is the child that is always present.
            .task {
                await store.loadIfNeeded(using: translator)
                // Drop anything the pipeline recorded as missing that is not
                // missing any more. macOS installs language assets on its own
                // schedule as well as on ours, so a record written last week
                // is a claim worth rechecking rather than a fact.
                for code in pending
                where TranslationCatalog.row(matching: code, in: store.menu)
                    .map({ store.readiness[$0.id] == .ready }) == true {
                    NoteTranslation.clearPendingDownload(code)
                }
                pending = NoteTranslation.pendingDownloads
                // Open on a language that needs attention, so the one case
                // where something is wrong does not also need a disclosure
                // triangle found first.
                if pendingDescription != nil { expanded = true }
            }
            .modifier(TranslationDownloadTask(configuration: $configuration, onFinish: finish))

            if let failure {
                SettingsCallout(text: failure, symbol: "exclamationmark.triangle.fill", tint: Color(nsColor: .systemOrange))
            }
            if let waiting = pendingDescription {
                SettingsCallout(text: waiting, symbol: "questionmark.circle.fill", tint: Color(nsColor: .systemOrange))
            }
        }
    }

    private func row(for language: TranslationLanguage) -> some View {
        // The status sits OUTSIDE the toggle rather than in its label: a
        // checkbox sizes its label to the text, so a Spacer inside it gets no
        // width and the status has nowhere to land.
        HStack {
            Toggle(language.name, isOn: binding(for: language))
                .toggleStyle(.checkbox)
            Spacer(minLength: Design.Space.snug)
            Text(status(of: language))
                .font(.caption)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
    }

    private func binding(for language: TranslationLanguage) -> Binding<Bool> {
        Binding(
            get: { selected.contains(language.id) },
            set: { isOn in
                if isOn {
                    selected.insert(language.id)
                    // Ticking a language that has no assets is a request for
                    // them: nobody picks a language in order to have it not
                    // work.
                    if store.readiness[language.id] == .needsDownload, !queue.contains(language) {
                        queue.append(language)
                        startNextDownload()
                    }
                } else {
                    selected.remove(language.id)
                    queue.removeAll { $0.id == language.id }
                }
                NoteTranslation.enabledLanguages = store.menu.map(\.id).filter(selected.contains)
            }
        )
    }

    /// What the collapsed row says, so the list does not have to be opened to
    /// know what it holds.
    private var summary: String {
        let names = store.menu.filter { selected.contains($0.id) }.map(\.name)
        guard !names.isEmpty else { return "Any language this Mac can translate" }
        if names.count <= 3 { return ListFormatter.localizedString(byJoining: names) }
        return "\(names.count) languages"
    }

    private func status(of language: TranslationLanguage) -> String {
        if queue.first?.id == language.id { return "Downloading…" }
        if queue.contains(language) { return "Waiting…" }
        switch store.readiness[language.id] {
        case .ready: return "Downloaded"
        case .needsDownload: return "Downloads when ticked"
        case .unsupported: return "Unavailable"
        case nil: return ""
        }
    }

    /// The languages MemoryClip has actually met and could not translate.
    /// Worth calling out separately from the list: it is the difference
    /// between "you could pick this" and "you already needed this".
    private var pendingDescription: String? {
        let names = pending
            .map { TranslationCatalog.row(matching: $0, in: store.menu)?.name ?? LanguageDetector.displayName(forIdentifier: $0) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        let list = ListFormatter.localizedString(byJoining: names)
        return "MemoryClip has already read a screenshot in \(list) and saved the note untranslated. Tick the language above to download it, then capture the screenshot again."
    }

    private func startNextDownload() {
        guard queue.first != nil else { return }
        failure = nil
        #if canImport(Translation)
        configuration = TranslationSession.Configuration(
            source: queue[0].language,
            target: NoteTranslation.target
        )
        #else
        finish("", false)
        #endif
    }

    /// - Parameter succeeded: false covers both a thrown error and a build
    ///   without the framework; either way the user needs the manual route.
    private func finish(_ identifier: String, _ succeeded: Bool) {
        let finished = queue.first
        if !queue.isEmpty { queue.removeFirst() }
        #if canImport(Translation)
        configuration = nil
        #endif

        if succeeded, let finished {
            Task { await store.refresh(finished, using: translator) }
            for code in pending where TranslationCatalog.matches(selection: finished.id, detected: code) {
                NoteTranslation.clearPendingDownload(code)
            }
            pending = NoteTranslation.pendingDownloads
        } else if !succeeded {
            // Deliberately not the framework's own description: it is written
            // for a translation UI ("Unable to translate") and says nothing
            // about a download. The user needs the route that always works.
            failure = "The download did not finish. You can also add languages in System Settings → General → Language & Region → Translation Languages."
        }

        // Whatever happened to that one, the rest of the queue still wants
        // fetching — one failure is not a reason to abandon four.
        startNextDownload()
    }
}

/// The language a copied clip is translated into for the preview pane.
///
/// A single choice, not the note picker's checklist, and for a reason: the
/// note pipeline picks which languages it will *read*, of which there are
/// many, while this picks the one language the user reads *in*. No readiness
/// column either — the pair is not known until a clip turns up in some
/// language, and a missing pack is recorded then, in
/// `NoteTranslation.pendingDownloads`, exactly as the note pipeline records
/// it.
private struct ClipTranslationTargetPicker: View {
    /// The catalog lives outside the view — see `TranslationLanguageStore`.
    private var store: TranslationLanguageStore { .shared }

    @AppStorage(NoteSettingsKeys.clipTranslationTarget) private var target = ClipTranslation.defaultTargetIdentifier

    private let translator = AppleTranslator()

    var body: some View {
        Picker(selection: selection) {
            ForEach(rows) { language in
                Text(language.name).tag(language.id)
            }
        } label: {
            Label {
                Text("Into")
            } icon: {
                SettingsIcon(symbol: "globe", tint: Color(nsColor: .systemTeal))
            }
        }
        .task { await store.loadIfNeeded(using: translator) }
    }

    /// The menu, with the language currently chosen guaranteed to be in it.
    ///
    /// Until the framework's list arrives — and on a Mac that cannot
    /// translate at all — a picker whose selection matches no row renders
    /// blank, which is the one row that must never be blank.
    private var rows: [TranslationLanguage] {
        let known = store.targets
        if TranslationCatalog.row(matching: target, in: known) != nil { return known }
        let chosen = TranslationLanguage(
            id: target,
            name: LanguageDetector.displayName(forIdentifier: target),
            language: Locale.Language(identifier: target)
        )
        return [chosen] + known
    }

    /// The framework spells a language one way and the setting may have been
    /// written another ("fr" against the list's "fr-Latn"), so the selection
    /// is resolved to the row that means the same language rather than
    /// compared as a string.
    private var selection: Binding<String> {
        Binding(
            get: { TranslationCatalog.row(matching: target, in: rows)?.id ?? target },
            set: { target = $0 }
        )
    }
}

/// The `.translationTask` attachment, behind a modifier so the view above
/// compiles unchanged on an SDK without the framework.
///
/// `prepareTranslation()` is the call that asks macOS for the assets — it is
/// what puts up the system's download prompt — and it only has that power on
/// a session the modifier created.
private struct TranslationDownloadTask: ViewModifier {
    #if canImport(Translation)
    @Binding var configuration: TranslationSession.Configuration?
    #endif
    /// `@MainActor` so it can touch the view's state, `@Sendable` so the
    /// action closure below can be nonisolated — which is what lets the
    /// session's own (nonisolated) methods be called on it without the
    /// compiler having to send a main-actor value across domains.
    let onFinish: @MainActor @Sendable (String, Bool) -> Void

    func body(content: Content) -> some View {
        #if canImport(Translation)
        content.translationTask(configuration) { @Sendable session in
            let identifier = session.sourceLanguage.map(LanguageDetector.identifier(for:)) ?? ""
            do {
                try await session.prepareTranslation()
                await onFinish(identifier, true)
            } catch {
                log.error("Translation download failed for \(identifier, privacy: .public)")
                await onFinish(identifier, false)
            }
        }
        #else
        content
        #endif
    }
}

// MARK: - Notes

/// The local model and where its output is written.
private struct NotesSettingsPane: View {
    @AppStorage(NoteSettingsKeys.refineEnabled) private var refineEnabled = true
    @AppStorage(NoteSettingsKeys.translateEnabled) private var translateEnabled = true
    @AppStorage(NoteSettingsKeys.clipTranslateEnabled) private var clipTranslateEnabled = false
    @AppStorage(NoteSettingsKeys.autoNoteEnabled) private var autoNoteEnabled = false
    @AppStorage(NoteSettingsKeys.autoNoteMinimumCharacters) private var minimumCharacters = 80

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

            Section("Translation") {
                Toggle(isOn: $translateEnabled) {
                    Label {
                        Text("Translate other languages into English")
                    } icon: {
                        SettingsIcon(symbol: "character.bubble.fill", tint: Color(nsColor: .systemPink))
                    }
                }
                if translateEnabled {
                    TranslationLanguagePicker()
                }
                SettingsHint("A screenshot in Arabic, Japanese or Russian is read in its own language and the note carries both: the text exactly as it was on screen, and an English translation underneath it. Translation runs on this Mac. The title, summary and tags are written from the English, so the note is findable in a vault you search in English.\n\nTick as many languages as you like — those are the ones MemoryClip will translate, and ticking one downloads its assets if macOS does not have them yet. With none ticked it translates any language this Mac can already handle. The packs go into the store the whole system shares, so a language you fetch here is the one Translate and Safari use.")

                Toggle(isOn: $clipTranslateEnabled) {
                    Label {
                        Text("Translate copied text in the preview")
                    } icon: {
                        SettingsIcon(symbol: "text.bubble.fill", tint: Color(nsColor: .systemTeal))
                    }
                }
                if clipTranslateEnabled {
                    ClipTranslationTargetPicker()
                }
                SettingsHint("Copy something in a language you do not read and the preview shows it in yours, above the text as it was copied. It happens when you open the preview, not when you copy — a clipboard is mostly things nobody reads twice — and each clip is translated once and remembered.")
            }

            // The same view the first-run tour renders, so the folder a user
            // picked during the tour is the folder this pane shows.
            Section("Destination") {
                NoteDestinationSetup()
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
    }
}

extension Notification.Name {
    /// Posted when the user picks a different screenshot folder, so the
    /// watcher can re-point without a relaunch.
    static let memoryClipScreenshotFolderChanged = Notification.Name("memoryClipScreenshotFolderChanged")
}
