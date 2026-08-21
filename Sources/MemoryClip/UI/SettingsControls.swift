import SwiftUI
import ServiceManagement

/// The controls MemoryClip has to offer in more than one window.
///
/// Everything here started life inside `SettingsView` as a private type. It
/// moved when the first-run tour stopped merely *describing* configuration and
/// started carrying it: a user is asked where notes should go while they are
/// being told notes exist, not sent to a pane to hunt for the same three-way
/// picker afterwards. That only works if there is one picker — a second copy in
/// the tour would be free to drift from the pane, and, worse, free to grow its
/// own folder-bookmark handling, which is the one piece of this that macOS
/// punishes getting wrong (see `FolderBookmark`).
///
/// So the rule for this file: a control lands here the moment a second window
/// needs it, and both windows then render the same struct with the same
/// settings keys behind it. The tour never writes a key the Settings window
/// cannot see, and never invents one of its own.

// MARK: - Form furniture

/// The explanatory line that sits under a settings control.
///
/// Was repeated ten times as `Text(...).font(.caption).foregroundStyle(.secondary)`;
/// naming it keeps every hint on the same size, colour and wrapping rule, and
/// gives one place to adjust the contrast of the whole settings window.
struct SettingsHint: View {
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
struct SettingsIcon: View {
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

/// An inline message that has to be noticed — a launch-at-login failure, the
/// Automation permission Apple Notes needs, a translation download that did
/// not finish.
///
/// A bare red caption disappears into a grouped form; a tinted, outlined
/// block with its own glyph reads as "something went wrong here" without
/// resorting to an alert.
struct SettingsCallout: View {
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

// MARK: - Launch at login

/// The launch-at-login switch, and the failure `SMAppService` only reports at
/// the moment you ask it to register.
///
/// Shared with the tour because the first launch is when the question is
/// actually live: MemoryClip has no Dock icon to be relaunched from, so a user
/// who does not turn this on meets it again only by remembering it exists. One
/// switch, reversible, needing no permission and no picker — which is the whole
/// bar for something appearing on a page of the tour.
///
/// - Parameter showsHint: the tour's welcome page already says MemoryClip is a
///   menu-bar app with no Dock icon, so it turns the line off rather than
///   printing the same sentence twice on one page.
struct LaunchAtLoginToggle: View {
    var showsHint: Bool = true

    /// Read from the service rather than stored: the login item is launchd's
    /// state, not MemoryClip's, and it can be revoked in System Settings →
    /// General → Login Items while the app is running.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Group {
            // An explicit HStack rather than a labelled `Toggle` (or a
            // `LabeledContent`): both of those lean on the enclosing `Form` to
            // put the switch on the trailing edge, and the tour has no Form —
            // there the labelled Toggle drew as "[switch] Launch at login" and
            // the LabeledContent drew the pair centred. A Spacer is read the
            // same way by both windows.
            HStack(spacing: Design.Space.normal) {
                Label {
                    Text(loc("Launch at login"))
                } icon: {
                    SettingsIcon(symbol: "power", tint: Color(nsColor: .systemGreen))
                }
                Spacer(minLength: Design.Space.normal)
                Toggle(loc("Launch at login"), isOn: launchAtLoginBinding)
                    .labelsHidden()
            }
            if let launchAtLoginError {
                SettingsCallout(text: launchAtLoginError)
            }
            if showsHint {
                SettingsHint(loc("MemoryClip runs as a menu-bar app: no Dock icon, no window until you open the panel."))
            }
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
            return loc("Launch at login needs MemoryClip in your Applications folder. Move MemoryClip.app there, reopen it, and try again.")
        }
        return error.localizedDescription
    }
}

// MARK: - Automatic paste

/// The auto-paste switch.
///
/// Shared with the tour because this is the one part of MemoryClip a macOS
/// permission can defeat without saying so: the clip reaches the clipboard
/// either way, so a synthetic ⌘V that Accessibility blocked looks exactly like
/// nothing having happened. The page that explains pasting is the only place
/// where that sentence lands before it is needed rather than after.
///
/// - Parameter showsHint: the tour spends a whole bullet on the Accessibility
///   caveat, so it turns the line off rather than printing it twice on one
///   page.
struct AutoPasteToggle: View {
    var showsHint: Bool = true

    @AppStorage(SettingsKeys.autoPaste) private var autoPaste = true

    var body: some View {
        Group {
            // Laid out like `LaunchAtLoginToggle`, and for the reason written
            // there: the tour has no `Form` for a labelled Toggle to lean on.
            HStack(spacing: Design.Space.normal) {
                Label {
                    Text(loc("Paste automatically after selecting a clip"))
                } icon: {
                    SettingsIcon(symbol: "arrow.down.doc.fill", tint: Color(nsColor: .systemBlue))
                }
                Spacer(minLength: Design.Space.normal)
                Toggle(loc("Paste automatically after selecting a clip"), isOn: $autoPaste)
                    .labelsHidden()
            }
            if showsHint {
                SettingsHint(loc("MemoryClip simulates ⌘V into the previous app. If macOS blocks the synthetic key event (Accessibility not granted), the clip is still on the clipboard — paste manually with ⌘V."))
            }
        }
    }
}

// MARK: - Note destination

/// Where notes are written, and whatever the chosen destination still needs
/// before it can be written to.
///
/// The three destinations are not equally ready out of the box, and that is
/// what this view exists to close: Apple Notes has a folder name registered
/// ("MemoryClip") and works as soon as macOS grants Automation, a Shortcut is
/// unusable until one is named, and the Markdown folder — the default — has no
/// folder at all until someone picks one in an `NSOpenPanel`. That last case is
/// the reason the picker is offered during the tour: `NoteSinkFactory` throws
/// `noDestinationConfigured` for it, so a user who never visits Settings meets
/// the feature as an error message.
///
/// - Parameter showsDetail: Settings shows everything the destination can be
///   tuned with — the attachment switches and the guide to which apps read
///   these files. The tour shows only the fields a destination cannot work
///   without, because a page of the tour that grows into the Notes pane is a
///   worse page than the one it replaced.
struct NoteDestinationSetup: View {
    var showsDetail: Bool = true

    @AppStorage(NoteSettingsKeys.destination) private var destinationRaw = NoteDestination.markdownVault.rawValue
    @AppStorage(NoteSettingsKeys.copyAttachments) private var copyAttachments = true
    @AppStorage(NoteSettingsKeys.vaultAttachmentFolder) private var attachmentFolder = "attachments"
    @AppStorage(NoteSettingsKeys.vaultDateFolders) private var dateFolders = true
    @AppStorage(NoteSettingsKeys.notesAppFolder) private var notesAppFolder = "MemoryClip"
    @AppStorage(NoteSettingsKeys.shortcutName) private var shortcutName = ""

    /// The folder the stored bookmark currently resolves to, so both windows
    /// open showing what is already configured rather than "Not chosen yet" —
    /// re-running the tour must not read as though the vault were gone.
    /// Resolved in `onAppear` because resolving a security-scoped bookmark is
    /// filesystem work, not something to do in a property initialiser that
    /// SwiftUI may run on every body evaluation.
    @State private var vault: URL?

    private var destination: NoteDestination {
        NoteDestination(rawValue: destinationRaw) ?? .markdownVault
    }

    var body: some View {
        // A `Group`, not a `VStack`: inside a `Form` these have to arrive as
        // separate rows (which is what gives each its own inset and divider),
        // and inside the tour's plain stack they simply stack. A container
        // would fix one of those two and break the other.
        Group {
            Picker(selection: $destinationRaw) {
                ForEach(NoteDestination.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            } label: {
                Label {
                    Text(loc("Write notes to"))
                } icon: {
                    SettingsIcon(symbol: "square.and.arrow.down.fill", tint: Color(nsColor: .systemTeal))
                }
            }
            .pickerStyle(.segmented)
            // Attached to the picker rather than to the Group above: a Group is
            // transparent, so a modifier on it runs once per child — three
            // bookmark resolutions, two of them on rows that come and go with
            // the selection. The picker is the child that is always present.
            .onAppear { vault = FolderBookmark.resolve(key: NoteSettingsKeys.vaultBookmark) }

            switch destination {
            case .markdownVault:
                markdownOptions
            case .notesApp:
                notesAppOptions
            case .shortcut:
                shortcutOptions
            }
        }
    }

    @ViewBuilder
    private var markdownOptions: some View {
        HStack(spacing: Design.Space.normal) {
            Label {
                VStack(alignment: .leading, spacing: Design.Space.hair) {
                    Text(loc("Folder"))
                    Text(vault?.path(percentEncoded: false) ?? loc("Not chosen yet"))
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } icon: {
                SettingsIcon(symbol: "folder.fill", tint: Color(nsColor: .systemBlue))
            }
            // The label takes the width rather than a Spacer taking what is
            // left of it: a chosen folder's path is far wider than "Not chosen
            // yet", and letting the label size to its content walked the
            // button several hundred points left the moment one was picked.
            // Pinned this way the button holds still and the path truncates.
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(loc("Choose…")) { chooseVault() }
        }
        if showsDetail {
            Toggle(loc("Sort notes into folders by date"), isOn: $dateFolders)
            Toggle(loc("Copy the screenshot into the folder"), isOn: $copyAttachments)
            if copyAttachments {
                HStack(spacing: Design.Space.normal) {
                    Text(loc("Attachments subfolder"))
                    TextField(loc("Attachments subfolder"), text: $attachmentFolder)
                        .labelsHidden()
                        // Fills the rest of the row, the way a field labelled
                        // by an enclosing Form does.
                        .frame(maxWidth: .infinity)
                }
            }
            MarkdownCompatibilityGuide(copiesAttachments: copyAttachments)
            SettingsHint(loc("Plain Markdown files with YAML front matter — an Obsidian vault, or anything else that reads .md off disk. Copying the screenshot in is what lets the note embed it, and means the note survives you clearing out your Desktop.\n\nSorting by date files each note under a folder like 26-03 March/16, so a folder you have kept for years is still something you can walk through. The file name keeps its own timestamp either way, and notes you have already saved stay where they are — turning this on or off never moves anything. Screenshots always go to the one attachments folder, since an embed finds them anywhere in the vault."))
        } else {
            SettingsHint(loc("Plain Markdown files with YAML front matter — an Obsidian vault, or anything else that reads .md off disk. Choosing the folder here is also what grants MemoryClip access to it."))
        }
    }

    @ViewBuilder
    private var notesAppOptions: some View {
        // The label is spelled out rather than left to the field's own title:
        // a `TextField`'s title is drawn as a leading label inside a `Form`
        // and dropped everywhere else, so in the tour — a plain stack — the
        // field arrived with nothing saying what it was.
        HStack(spacing: Design.Space.normal) {
            Text(loc("Notes folder"))
            TextField(loc("Notes folder"), text: $notesAppFolder)
                .labelsHidden()
                .frame(maxWidth: .infinity)
        }
        SettingsCallout(
            text: loc("Notes is the one destination that needs a permission: macOS will ask to let MemoryClip control it the first time. The screenshot goes in as a link — Notes does not accept an image through automation."),
            symbol: "lock.fill",
            tint: Color(nsColor: .systemOrange)
        )
    }

    @ViewBuilder
    private var shortcutOptions: some View {
        HStack(spacing: Design.Space.normal) {
            Text(loc("Shortcut name"))
            TextField(loc("Shortcut name"), text: $shortcutName)
                .labelsHidden()
                .frame(maxWidth: .infinity)
        }
        SettingsHint(loc("MemoryClip runs this Shortcut with the note as its input, so anything Shortcuts can reach — Bear, Things, DEVONthink, a folder in iCloud — can be the destination."))
    }

    private func chooseVault() {
        let chosen = FolderBookmark.choose(
            key: NoteSettingsKeys.vaultBookmark,
            title: loc("Choose Note Folder"),
            message: loc("Pick the folder MemoryClip should write notes into — an Obsidian vault, or any folder of Markdown files."),
            startingAt: vault
        )
        guard let chosen else { return }
        vault = chosen
        // Picking a folder in an open panel is how the grant is given, so this
        // is one of the few places the app learns it has one.
        PermissionLedger().noteGranted(.filesAndFolders)
    }
}

// MARK: - Markdown compatibility

/// "Which app can open these notes, and what do I set?"
///
/// A folder of Markdown files is the most portable destination MemoryClip
/// has and the least self-explanatory: the folder picker asks for a folder
/// without saying what a good one would be, and the two switches under it
/// (copy the screenshot in, and where) are the difference between a note that
/// renders and one that shows a broken embed. That question is answered here
/// rather than in a README nobody has open while they are choosing a folder.
///
/// Collapsed by default — it is reference material, not a step — and the
/// advice tracks the attachment switch, because which link style the note
/// gets is exactly what the switch decides.
private struct MarkdownCompatibilityGuide: View {
    let copiesAttachments: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: Design.Space.snug) {
                Text(preamble)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                ForEach(Self.apps) { app in
                    VStack(alignment: .leading, spacing: Design.Space.hair) {
                        Text(app.name).fontWeight(.medium)
                        Text(app.advice)
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                }
                Text(Self.elsewhere)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            .font(.callout)
            .padding(.top, Design.Space.hair)
        } label: {
            Label {
                Text(loc("Which apps can open these notes?"))
            } icon: {
                SettingsIcon(symbol: "questionmark.circle.fill", tint: Color(nsColor: .systemGray))
            }
        }
    }

    /// The two things apps actually differ on, said once so each entry below
    /// can be a sentence rather than a paragraph.
    private var preamble: String {
        let embed = copiesAttachments
            ? loc("The screenshot is copied in and embedded as ![[name.png]] — a wiki-style embed that Obsidian and Logseq resolve and most other editors show as plain text.")
            : loc("The screenshot is not copied, so the note links to it where it sits with an ordinary [Screenshot](file://…) link, which every Markdown editor renders.")
        return loc("Every note is a plain .md file named \"2026-08-13 1422 Title.md\", with YAML front matter (title, created, source, tags, lang) above the text. Anything that reads Markdown off disk can open one; apps differ on two things only — whether they understand front matter, and whether they resolve wiki-style embeds.\n\n%@", embed)
    }

    private struct App: Identifiable {
        let name: String
        let advice: String
        var id: String { name }
    }

    private static let apps: [App] = [
        App(
            name: "Obsidian",
            advice: loc("Pick your vault folder, or any folder inside it. Keep \"Copy the screenshot into the folder\" on — that is what makes the embed resolve. Front matter shows up as note properties, so tags work as tags and you can query lang, source and created from Dataview.")
        ),
        App(
            name: "Logseq",
            advice: loc("Pick the \"pages\" folder inside your graph, and set the attachments subfolder to \"assets\" — the folder Logseq keeps its files in. It reads front matter, and re-indexes new files when the graph is reopened.")
        ),
        App(
            name: "iA Writer, Typora, Zettlr, VS Code",
            advice: loc("Pick any folder these already watch. They render standard Markdown, so turn \"Copy the screenshot into the folder\" off and the note links to the screenshot instead of embedding it — an embed they cannot resolve shows up as literal ![[…]] text.")
        ),
        App(
            name: "DEVONthink",
            advice: loc("Pick any folder, then index it (File → Index Files and Folders). Indexed notes stay files on disk, so MemoryClip can still update one in place.")
        ),
        App(
            name: "iCloud Drive, Dropbox, Syncthing",
            advice: loc("A synced folder works like any other. Notes are written whole, so a half-written file is never what syncs.")
        ),
    ]

    private static let elsewhere = loc("Bear, Craft, Notion and Things do not keep notes as files. Use the Shortcut destination for those — MemoryClip hands the note to a Shortcut, which can put it anywhere Shortcuts reaches. For Apple Notes, use the Notes destination.")
}

// MARK: - Automatic calendar events

/// The automatic-events switch, the permission it needs, and the notification
/// that keeps it honest.
///
/// Shared with the tour for a reason the other controls do not have: this is
/// the only switch in MemoryClip whose own permission prompt may not be raised
/// from the code path that uses it. `CalendarCoordinator` refuses to prompt
/// from a background capture — a TCC dialog with nothing on screen to explain
/// it is a dialog people deny — so the grant has to be asked for wherever the
/// switch is, and there are now two such places.
///
/// Hence `prime()` on both the change and the appearance. The change covers
/// someone turning it on; the appearance covers someone who turned it on in an
/// earlier run and was never asked, for whom there is no transition left to
/// fire on. When neither has produced a grant the callout says so, because the
/// alternative is a switch that is on and a calendar that silently stays empty.
///
/// - Parameter showsDetail: the Settings pane shows the explanation of what
///   qualifies and the notification sub-switch; the tour shows the switch and
///   the callout only, because a page of the tour that grows into the Calendar
///   pane is a worse page than the one it replaced.
struct CalendarAutoCreateSetup: View {
    var showsDetail: Bool = true

    @AppStorage(CalendarSettingsKeys.autoCreate) private var autoCreate = false
    @AppStorage(CalendarSettingsKeys.notifyOnAutoCreate) private var notifyOnAutoCreate = true

    /// Starts optimistic so the warning does not flash on every open before
    /// the first `prime()` has read the real grant.
    @State private var access: CalendarAccess = .granted

    var body: some View {
        Group {
            HStack(spacing: Design.Space.normal) {
                Label {
                    Text(loc("Add events automatically"))
                } icon: {
                    SettingsIcon(symbol: "calendar.badge.plus", tint: Color(nsColor: .systemRed))
                }
                Spacer(minLength: Design.Space.normal)
                Toggle(loc("Add events automatically"), isOn: $autoCreate)
                    .labelsHidden()
            }

            if showsDetail {
                SettingsHint(loc("An event is created on its own only when the clip names a time of day and either a meeting link or an address. A bare date — a deadline in a paragraph, an expiry notice, a headline — is left alone. Anything MemoryClip passes over you can still add yourself: select the clip in the panel and choose Add to Calendar."))
            }

            if autoCreate, !access.canCreateEvents {
                SettingsCallout(text: accessWarning, symbol: "calendar.badge.exclamationmark")
            }

            if showsDetail, autoCreate {
                HStack(spacing: Design.Space.normal) {
                    Label {
                        Text(loc("Tell me when an event is added"))
                    } icon: {
                        SettingsIcon(symbol: "bell.badge.fill", tint: Color(nsColor: .systemBlue))
                    }
                    Spacer(minLength: Design.Space.normal)
                    Toggle(loc("Tell me when an event is added"), isOn: $notifyOnAutoCreate)
                        .labelsHidden()
                }
                SettingsHint(loc("The notification names the event and when it starts, and carries an Undo button that takes it straight back out of your calendar. Undo works while MemoryClip is running; after a quit, remove the event in Calendar like any other."))
            }
        }
        .onChange(of: autoCreate) { _, isOn in
            guard isOn else { return }
            Task { await prime() }
        }
        .onAppear {
            Task { await prime() }
        }
    }

    /// Refresh the known grant, asking for it first when the feature is on and
    /// nobody has been asked yet.
    ///
    /// The window has to be won back whenever a dialog was actually raised:
    /// answering a TCC prompt returns activation to whatever regular app held
    /// it, and this switch lives in two windows an `.accessory` agent gives
    /// the user no way to find again. See `WindowFocus`.
    private func prime() async {
        if autoCreate, await EventKitSink.primeAccess() {
            WindowFocus.restoreAfterSystemPrompt()
        }
        access = EventKitSink.access
    }

    /// Why automatic events are not happening, and what to do about it.
    private var accessWarning: String {
        switch access {
        case .denied:
            return loc("Automatic events are on, but permission to add them was refused. Allow MemoryClip in System Settings → Privacy & Security → Calendars; macOS will not ask a second time on its own.")
        case .restricted:
            return loc("Calendar access is turned off on this Mac by a profile or by Screen Time, so no event can be added.")
        case .notAsked, .granted:
            return loc("Automatic events are on, but MemoryClip has not been given calendar access yet, so nothing will be added. Switch this off and on again to be asked.")
        }
    }
}

// MARK: - Update checks

/// The daily update check: the switch, what it last found, and a way to ask
/// now.
///
/// Shared with the tour because this is the one decision in MemoryClip that
/// changes what the app does on the network, and a user who never opens
/// Settings should still get to make it. It earns a page by the same bar as
/// the others: one switch, reversible, and something the app may not answer
/// on the user's behalf.
///
/// The line under it names the host and says what is sent, on both windows.
/// An update check is the kind of feature that quietly becomes telemetry, and
/// the defence against that is a sentence the user can hold the code to.
///
/// - Parameter showsHint: the tour page says the same thing in its own
///   bullets, so it turns the line off rather than printing it twice.
struct UpdateCheckToggle: View {
    var showsHint: Bool = true

    /// The checker this reads. Defaulted to the shared one — which is what
    /// both windows want — and injectable so the control can be put in front
    /// of a stubbed one and looked at in each of its states.
    @ObservedObject var checker: UpdateChecker = .shared

    @AppStorage(SettingsKeys.automaticUpdates) private var automaticUpdates = false

    var body: some View {
        Group {
            // The same explicit HStack the launch-at-login switch documents:
            // a labelled Toggle leans on an enclosing Form, and the tour has
            // no Form to lean on.
            HStack(spacing: Design.Space.normal) {
                Label {
                    Text(loc("Check for updates daily"))
                } icon: {
                    SettingsIcon(symbol: "arrow.down.circle", tint: Color(nsColor: .systemBlue))
                }
                Spacer(minLength: Design.Space.normal)
                Toggle(loc("Check for updates daily"), isOn: $automaticUpdates)
                    .labelsHidden()
            }

            if automaticUpdates {
                HStack(spacing: Design.Space.normal) {
                    status
                    Spacer(minLength: Design.Space.normal)
                    action
                }
            }

            if showsHint {
                SettingsHint(loc("Off by default. When on, MemoryClip asks github.com once a day what the newest release is and tells you if it is newer than this one — nothing is sent about you, and nothing is downloaded or installed until you choose it."))
            }
        }
    }

    /// What the last check came back with, in one line.
    @ViewBuilder
    private var status: some View {
        switch checker.status {
        case .idle:
            Text(lastCheckedText)
                .font(.caption)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        case .checking:
            Text(loc("Checking…"))
                .font(.caption)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        case .upToDate:
            Label(loc("MemoryClip is up to date"), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color(nsColor: .systemGreen))
        case let .available(update):
            Text(loc("MemoryClip %@ is available", update.version.description))
                .font(.caption)
                .foregroundStyle(Color(nsColor: .labelColor))
        case .downloading:
            Text(loc("Downloading…"))
                .font(.caption)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        case .opened:
            // The disk image is in Finder now, so the next move is a drag and
            // not another button here.
            Text(loc("Drag MemoryClip to Applications in the window that opened, then relaunch."))
                .font(.caption)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
        case let .failed(reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(Color(nsColor: .systemRed))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Check Now, or — once there is something to take — Download.
    @ViewBuilder
    private var action: some View {
        switch checker.status {
        case let .available(update):
            Button(loc("Download")) { checker.download(update) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .checking, .downloading:
            ProgressView().controlSize(.small)
        default:
            Button(loc("Check Now")) { checker.check(userInitiated: true) }
                .controlSize(.small)
        }
    }

    /// When it last looked, or that it has not yet.
    private var lastCheckedText: String {
        guard let last = checker.lastChecked else { return loc("Not checked yet") }
        let when = last.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)
        )
        return loc("Last checked %@", when)
    }
}
