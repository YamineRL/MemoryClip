import SwiftUI

/// The window that asks for the permissions MemoryClip's features need.
///
/// One row per permission, each with the one button that can grant it: the
/// permission's own prompt where macOS still raises one, and the System
/// Settings pane holding the switch where it does not. A row answers in place
/// — it turns into a tick, or into a link to the pane — so the window never
/// has to be closed and re-opened to see whether it worked.
///
/// Nothing here is a gate. Closing the window leaves every feature exactly as
/// it was, and Permissions… in the menu bar opens it again; this exists so
/// that the user is *told*, not so that they are stopped.
struct PermissionRecoveryView: View {
    /// Why the window is on screen, which is all that separates the two
    /// headers: an update took something away, or the user came looking.
    enum Reason {
        /// Opened by `showIfNeeded` after an update dropped grants.
        case update
        /// Opened from the menu bar.
        case review
        /// Opened because a feature the user switched on cannot run without a
        /// permission macOS has not given.
        case blocked
    }

    let reason: Reason
    /// The permissions to show, in `RecoverablePermission`'s own order.
    let permissions: [RecoverablePermission]
    /// What each one is worth as the window opens, so a permission that is
    /// already granted opens as a tick rather than as a button that asks for
    /// something the user has given.
    let states: [RecoverablePermission: PermissionState]
    /// Called when a permission is granted, so the ledger can record it under
    /// the running build and stop offering it.
    let onGranted: (RecoverablePermission) -> Void
    /// Called when a system prompt has been answered, so the window can be
    /// brought back in front of whatever the prompt activated.
    let onPromptFinished: () -> Void
    let onFinish: () -> Void

    /// What each row is worth now. Seeded from `states`, then updated in place
    /// by the buttons.
    @State private var outcomes: [RecoverablePermission: PermissionState] = [:]
    /// Permissions granted while this window has been open, which are worth
    /// saying more about than the ones that were already fine.
    @State private var restored: Set<RecoverablePermission> = []
    /// The row waiting on a system prompt, if any. Its button spins and the
    /// others are disabled — two TCC dialogs at once is a stack of windows
    /// nobody can attribute to anything.
    @State private var asking: RecoverablePermission?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.loose) {
            header
            VStack(spacing: Design.Space.normal) {
                ForEach(permissions) { permission in
                    row(permission)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(loc("Done")) { onFinish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Space.loose * 2)
        .frame(width: Design.Size.sheetWidth)
        .onAppear { outcomes = states }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Design.Space.roomy) {
            SettingsIcon(
                symbol: "lock.rotation",
                tint: Color(nsColor: .systemOrange),
                size: Design.Size.settingsIcon * 2,
                radius: Design.Radius.pane
            )
            VStack(alignment: .leading, spacing: Design.Space.snug) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: String {
        switch reason {
        case .update: return loc("MemoryClip needs your permission again")
        case .review: return loc("MemoryClip's permissions")
        case .blocked: return loc("A feature you have switched on is blocked")
        }
    }

    private var subtitle: String {
        switch reason {
        case .update:
            return loc("macOS treats an updated app as a new one, so the permissions you gave the last version were dropped. Nothing else changed — your clips, notes and settings are where you left them.")
        case .review:
            return loc("Each one is used by a single feature, and nothing else in MemoryClip needs it. You can change any of them later in System Settings → Privacy & Security.")
        case .blocked:
            return loc("macOS has not given MemoryClip the permission it needs, so the feature is switched on and quietly doing nothing. Allowing it here is all that is missing.")
        }
    }

    private func row(_ permission: RecoverablePermission) -> some View {
        HStack(spacing: Design.Space.roomy) {
            SettingsIcon(symbol: permission.symbol, tint: Color(nsColor: .systemBlue))
            VStack(alignment: .leading, spacing: Design.Space.tight) {
                Text(permission.title)
                Text(permission.detail)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Design.Space.normal)
            action(permission)
        }
        .padding(Design.Space.roomy)
        .designPane()
    }

    @ViewBuilder
    private func action(_ permission: RecoverablePermission) -> some View {
        if outcomes[permission] == .granted {
            Label(
                restored.contains(permission) ? loc("Restored") : loc("Allowed"),
                systemImage: "checkmark.circle.fill"
            )
            .font(.callout)
            .foregroundStyle(Color(nsColor: .systemGreen))
            .labelStyle(.titleAndIcon)
        } else if asking == permission {
            ProgressView()
                .controlSize(.small)
        } else {
            Button(buttonTitle(permission)) {
                Task { await ask(permission) }
            }
            .disabled(asking != nil)
        }
    }

    /// What the button promises, which has to be what it does: a permission
    /// macOS will prompt for says so, and one that can only be switched on by
    /// hand says that instead of pretending to ask.
    private func buttonTitle(_ permission: RecoverablePermission) -> String {
        if outcomes[permission] == .denied || !permission.canPromptInPlace {
            return loc("Open Settings…")
        }
        return loc("Allow…")
    }

    private func ask(_ permission: RecoverablePermission) async {
        asking = permission
        let state = await PermissionProbe.request(permission)
        asking = nil
        outcomes[permission] = state
        if state == .granted {
            restored.insert(permission)
            onGranted(permission)
        }
        // Answering a TCC dialog hands activation to whichever regular app had
        // it before, and this window belongs to an agent with no Dock tile to
        // click: without winning it back, granting the first permission is
        // what makes the second one unreachable.
        onPromptFinished()
        // The other rows may have changed with it — allowing Automation is one
        // grant covering every Apple Events target — so they are re-read
        // rather than left showing what they were worth when the window
        // opened. The row just answered keeps the state its own request
        // returned, which is the more direct answer.
        for other in permissions where other != permission {
            outcomes[other] = PermissionProbe.state(of: other)
        }
    }
}
