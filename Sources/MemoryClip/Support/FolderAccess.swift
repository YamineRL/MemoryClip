import Foundation

/// Whether a folder the user picked can be read right now, and when it cannot,
/// which of the two reasons it is.
///
/// `FileManager.fileExists` answers false for both of them — the folder is
/// gone, and macOS will not let this build look at it — and the two need
/// opposite repairs: one is "pick the folder again", the other is "give the
/// app access to it". Telling them apart is all this type does, and it is
/// worth a type because the second reason is invisible from the inside: a
/// refused folder reads exactly like an empty one.
enum FolderAccess {
    /// What reading the folder just told us.
    enum Reading: Equatable {
        /// Readable. The folder is there and this build is allowed into it.
        case readable
        /// macOS refused. The folder sits somewhere it guards (`~/Documents`,
        /// `~/Desktop`, `~/Downloads`, an external volume) and the grant that
        /// covered it does not cover this build — which is what replacing the
        /// bundle costs, every single update.
        case refused
        /// Nothing there to read: deleted, renamed, or on a volume that is not
        /// mounted.
        case missing
    }

    /// Find out whether this build can actually read `url`.
    ///
    /// **This can put a permission dialog on screen, so call it only from
    /// something the user pressed.** That is not an oversight to be tidied
    /// away later: macOS answers "may I read this folder" by asking the user.
    /// Undecided raises the prompt; refused returns `EPERM` silently. There is
    /// no third call that returns the answer quietly — `stat` and `access` do
    /// not consult TCC at all (they answer from the POSIX bits, and a home
    /// folder is mode 700 whatever TCC thinks), so a check written with them
    /// reports a folder as readable that the app cannot open.
    ///
    /// What the launch path uses instead is `PermissionLedger`: what worked,
    /// and under which build. The disk is touched when the user asks for it to
    /// be, and never before.
    static func read(_ url: URL) -> Reading {
        FolderBookmark.withAccess(to: url) {
            let path = url.path(percentEncoded: false)
            // `stat` first, and only to sort out the cases TCC has no opinion
            // on: it is not gated, so a folder that is simply gone is settled
            // here without an access that could prompt.
            var status = stat()
            guard stat(path, &status) == 0 else { return outcome(of: errno) }
            guard status.st_mode & S_IFMT == S_IFDIR else { return .missing }
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: path)
                return .readable
            } catch let error as NSError {
                return reading(of: error)
            }
        }
    }

    /// Cocoa's spelling of "you may not" against everything else, which is
    /// treated as the folder being gone.
    private static func reading(of error: NSError) -> Reading {
        guard error.domain == NSCocoaErrorDomain else { return .missing }
        return error.code == NSFileReadNoPermissionError ? .refused : .missing
    }

    /// Whether macOS gates this folder behind a consent prompt.
    ///
    /// A judgement, not a lookup: there is no API that answers it. The three
    /// home folders TCC guards by name cover where screenshots and vaults
    /// actually live, plus iCloud Drive and anything on another volume, which
    /// are gated the same way.
    ///
    /// Wrong in one direction on purpose. A guarded location this does not
    /// recognise gets opened at launch and may raise a prompt — which is
    /// exactly what happens today, so nothing is made worse — while an
    /// unguarded folder is never held back waiting for a grant macOS was never
    /// going to ask for.
    static func isGuarded(_ url: URL) -> Bool {
        let path = Self.comparablePath(url)
        if path.hasPrefix("/Volumes/") { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"].contains { name in
            let folder = Self.comparablePath(home.appending(path: name))
            return path == folder || path.hasPrefix(folder + "/")
        }
    }

    /// A path two URLs can be compared on.
    ///
    /// The trailing slash is the point: `path(percentEncoded:)` keeps one for
    /// a URL that knows it names a directory and drops it for one that does
    /// not, so `~/Desktop/` and `~/Desktop/Vault` fail every prefix test
    /// between them until both ends are spelled the same way.
    private static func comparablePath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// What `errno` from `stat` or `access` means for the folder.
    ///
    /// `EPERM` is TCC's answer and `EACCES` is the POSIX one; both mean the
    /// folder is there and closed to this process, which is a grant to ask
    /// for. Everything else — `ENOENT`, `ENOTDIR`, a volume that went away —
    /// means there is nothing there to be let into.
    private static func outcome(of code: Int32) -> Reading {
        switch code {
        case EPERM, EACCES: return .refused
        default: return .missing
        }
    }
}
