import AppKit

/// Remembering a folder the user picked, across relaunches.
///
/// MemoryClip needs two of these — the screenshot folder to watch and the
/// vault to write notes into — and both are outside its own container, in
/// exactly the places macOS guards (`~/Desktop`, `~/Documents`). Two things
/// follow from that:
///
/// - **The folder is chosen through `NSOpenPanel`.** Reaching into `~/Desktop`
///   uninvited earns a cold TCC denial the user never sees a reason for;
///   picking it in an open panel grants access as part of an action the user
///   took, which is the difference between "it works" and "it silently reads
///   nothing".
/// - **The grant is stored as a security-scoped bookmark**, not a path. A path
///   would survive the relaunch and the access would not. This costs nothing
///   today (MemoryClip is unsandboxed) and is what makes sandboxing later a
///   configuration change rather than a redesign.
enum FolderBookmark {
    /// Ask the user for a folder, and remember it under `key`.
    /// - Returns: the chosen folder, or nil when the panel was cancelled.
    @MainActor
    static func choose(
        key: String,
        title: String,
        message: String,
        startingAt suggestion: URL? = nil
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = loc("Choose")
        panel.title = title
        panel.message = message
        if let suggestion { panel.directoryURL = suggestion }

        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        store(url, key: key)
        return url
    }

    /// Persist a bookmark for `url` under `key`.
    @discardableResult
    static func store(_ url: URL, key: String) -> Bool {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: key)
            return true
        } catch {
            log.error("Could not bookmark folder: \(error.localizedDescription)")
            return false
        }
    }

    /// The folder remembered under `key`, or nil when none was chosen (or the
    /// bookmark no longer resolves — the folder was deleted or the volume is
    /// gone).
    ///
    /// A stale-but-resolvable bookmark is rewritten in place, so a folder the
    /// user moved keeps working instead of quietly going dead.
    static func resolve(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale { store(url, key: key) }
            return url
        } catch {
            log.error("Could not resolve folder bookmark: \(error.localizedDescription)")
            return nil
        }
    }

    /// Forget the folder remembered under `key`.
    static func clear(key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Run `body` with the security scope of `url` held open.
    ///
    /// `startAccessingSecurityScopedResource` returns false for a URL that
    /// never needed a scope (the common unsandboxed case), which is not a
    /// failure — only a matching `stop` must be skipped, which is what the
    /// flag here tracks.
    static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}
