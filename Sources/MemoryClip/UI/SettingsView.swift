import SwiftUI
import ServiceManagement
import KeyboardShortcuts

/// Settings window content, split into macOS-style preference tabs.
struct SettingsView: View {
    /// Fixed tab size — settings windows should not resize per tab.
    private static let tabWidth: CGFloat = Design.Size.sheetWidth
    private static let tabHeight: CGFloat = Design.Size.sheetHeight

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            HistorySettingsTab()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            PanelSettingsTab()
                .tabItem { Label("Panel", systemImage: "rectangle.on.rectangle") }
            PrivacySettingsTab()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
            ShortcutsSettingsTab()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: Self.tabWidth, height: Self.tabHeight)
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

    var body: some View {
        RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
            .fill(tint.gradient)
            .frame(width: Design.Size.settingsIcon, height: Design.Size.settingsIcon)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
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

/// One key combination in the Shortcuts tab, drawn as a cap.
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

private struct GeneralSettingsTab: View {
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

private struct HistorySettingsTab: View {
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

private struct PanelSettingsTab: View {
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
                SettingsHint("Gives the panel vim modes: it opens in NORMAL mode where j/k-style keys navigate, and / or i switches to INSERT mode for searching (Esc returns). The current mode is shown in the search bar. See the Shortcuts tab for the full list.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy

private struct PrivacySettingsTab: View {
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

private struct ShortcutsSettingsTab: View {
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

private struct AboutSettingsTab: View {
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
