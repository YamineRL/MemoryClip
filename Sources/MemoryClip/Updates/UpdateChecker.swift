import AppKit
import Combine

/// Where a check got to, for the Settings pane to show.
enum UpdateStatus: Equatable {
    /// Nothing has been asked yet this launch.
    case idle
    case checking
    /// The newest release is the one running. The date is when that was
    /// established, so the pane can say when it last looked.
    case upToDate(Date)
    case available(AvailableUpdate)
    case downloading
    /// The disk image is open in Finder; the drag across is the user's.
    case opened(ReleaseVersion)
    /// Something went wrong, worded for a human.
    case failed(String)
}

/// The daily "is there a newer MemoryClip?" check — off unless the user asks
/// for it.
///
/// # Why this is opt-in, and stays opt-in
///
/// Every other line MemoryClip runs is local, and both the About pane and the
/// first-run tour say so. This is the one thing in the app that opens a
/// socket, so it is off by default, it is a switch the user sets themselves,
/// and it asks exactly one host — `api.github.com`, the repository the app is
/// released from. It sends no identifier of any kind: it is an unauthenticated
/// GET of a public endpoint, and the only thing GitHub learns is that some IP
/// asked what the latest release is.
///
/// # What it does not do
///
/// It does not install anything. There is no Developer ID and no notarisation
/// behind this app, so a silent self-replacing updater would be asking the
/// user to trust an unsigned binary swap they never saw. What it does instead
/// is the manual install, minus the hunting: find the release, tell the user,
/// and — once they click — download the disk image and open it, which puts
/// MemoryClip.app next to the `/Applications` symlink `Scripts/make_dmg.sh`
/// puts there. The drag across is theirs, and so is the choice.
@MainActor
final class UpdateChecker: ObservableObject {
    /// How often the timer wakes to ask whether a check is due. Deliberately
    /// far shorter than the interval itself: a Mac that was asleep at the
    /// moment a day elapsed would otherwise wait a further day.
    static let pollInterval: TimeInterval = 60 * 60

    /// The instance the whole app talks to.
    ///
    /// A shared one for the same reason `OnboardingController` has one: the
    /// Settings pane, the tour and the notification delegate are each built
    /// by a different window controller that takes no dependencies, and a
    /// checker per window would mean three timers and three answers to the
    /// same question.
    static let shared = UpdateChecker()

    @Published private(set) var status: UpdateStatus = .idle

    private let defaults: UserDefaults
    private let session: URLSession
    private let running: ReleaseVersion?
    private let now: () -> Date
    private var timer: Timer?
    /// The check in flight, so a second Check Now does not start a third.
    private var work: Task<Void, Never>?

    /// - Parameters:
    ///   - running: The version this build reports, or nil when there is no
    ///     bundle to read one from (`swift run`, the test suite). With no
    ///     version to compare against there is nothing this can honestly say,
    ///     so every check turns into a no-op.
    ///   - now: The clock, injected so the daily arithmetic is testable.
    init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        running: ReleaseVersion? = ReleaseVersion(AppVersionInfo().shortVersion),
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.session = session
        self.running = running
        self.now = now
    }

    /// Isolated so it may touch `timer`, which is not `Sendable`: without
    /// the keyword Swift 6 hands `deinit` to no actor at all, and a repeating
    /// timer nothing invalidates outlives the object holding it.
    isolated deinit {
        timer?.invalidate()
    }

    // MARK: Stored state

    /// Whether the user switched the daily check on. The one gate every
    /// automatic path below reads.
    var isEnabled: Bool {
        defaults.bool(forKey: SettingsKeys.automaticUpdates)
    }

    /// When the last check completed, or nil if none ever has.
    var lastChecked: Date? {
        let stored = defaults.double(forKey: SettingsKeys.lastUpdateCheck)
        guard stored > 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: stored)
    }

    // MARK: Running

    /// Start the daily cycle. Called once at launch, whatever the setting
    /// says: the timer only ever *asks* whether a check is due, and `isEnabled`
    /// is what answers.
    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        // The panel and its menus run the main run loop in `.common` modes;
        // a timer left in `.default` stops while either is up.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        checkIfDue()
    }

    /// Check, but only if the user asked for checks and one is owed.
    func checkIfDue() {
        guard isEnabled, UpdateFeed.isDue(last: lastChecked, now: now()) else { return }
        check(userInitiated: false)
    }

    /// Check now, whatever the schedule says — the Check Now button.
    ///
    /// `userInitiated` decides who is told. A user standing in front of the
    /// Settings pane is watching `status` and does not need a banner as well;
    /// the daily check has no window open and the banner is the whole point.
    func check(userInitiated: Bool) {
        guard work == nil else { return }
        guard let running else {
            status = .failed(loc("This build does not report a version to compare."))
            return
        }
        status = .checking
        work = Task { [weak self] in
            defer { self?.work = nil }
            await self?.perform(running: running, userInitiated: userInitiated)
        }
    }

    private func perform(running: ReleaseVersion, userInitiated: Bool) async {
        do {
            let update = try await fetch(running: running)
            // Recorded whatever the answer was: a check that ran and found
            // nothing is still a check, and repeating it hourly would be the
            // opposite of "once a day".
            defaults.set(now().timeIntervalSinceReferenceDate, forKey: SettingsKeys.lastUpdateCheck)
            guard let update else {
                status = .upToDate(now())
                return
            }
            status = .available(update)
            guard !userInitiated else { return }
            await announce(update)
        } catch {
            status = .failed(Self.describe(error))
            log.error("Update check failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func fetch(running: ReleaseVersion) async throws -> AvailableUpdate? {
        var request = URLRequest(url: UpdateFeed.endpoint)
        // The version GitHub documents, so a future default cannot reshape
        // the JSON `UpdateFeed` decodes.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(AppVersionInfo.appName, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateCheckError.badStatus(http.statusCode)
        }
        return try UpdateFeed.update(fromLatestRelease: data, running: running)
    }

    /// Post the banner, once per version.
    ///
    /// Without the guard a user who leaves an update un-taken is told about
    /// the same release every day until they give in, which is the behaviour
    /// people switch update checks off to escape.
    private func announce(_ update: AvailableUpdate) async {
        let key = SettingsKeys.lastOfferedUpdate
        guard defaults.string(forKey: key) != update.version.description else { return }
        defaults.set(update.version.description, forKey: key)
        await UpdateNotifier.post(version: update.version)
    }

    // MARK: Taking it

    /// Download the disk image and open it, which is where MemoryClip's part
    /// ends: what Finder then shows is the app and the `/Applications`
    /// symlink beside it.
    func download(_ update: AvailableUpdate) {
        guard work == nil else { return }
        status = .downloading
        work = Task { [weak self] in
            defer { self?.work = nil }
            await self?.fetchAndOpen(update)
        }
    }

    /// Whatever the last check found, if it is still the thing to act on.
    var pendingUpdate: AvailableUpdate? {
        guard case let .available(update) = status else { return nil }
        return update
    }

    private func fetchAndOpen(_ update: AvailableUpdate) async {
        do {
            let (temporary, _) = try await session.download(from: update.diskImage)
            // Moved out of the URL loader's own scratch file, which it
            // deletes the moment this call returns, and named after the
            // release so the mounted volume is not called `CFNetworkDownload`.
            let destination = try Self.stage(temporary, version: update.version)
            status = .opened(update.version)
            NSWorkspace.shared.open(destination)
        } catch {
            status = .failed(Self.describe(error))
            log.error("Update download failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Move a finished download somewhere it will survive being opened.
    ///
    /// A directory of MemoryClip's own under the system temporary area rather
    /// than `~/Downloads`: writing there is a TCC prompt on a modern macOS,
    /// and a permission dialog raised by an update check is a poor trade for
    /// tidiness the user did not ask for.
    private static func stage(_ downloaded: URL, version: ReleaseVersion) throws -> URL {
        let folder = URL(filePath: NSTemporaryDirectory())
            .appending(path: "MemoryClipUpdates", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: "MemoryClip-\(version).dmg")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloaded, to: destination)
        return destination
    }

    /// What the Settings pane says went wrong.
    ///
    /// Worded for someone who did not write this: the distinction that
    /// matters to them is "the release is wrong" versus "the network is", not
    /// which enum case was thrown.
    static func describe(_ error: any Error) -> String {
        switch error {
        case UpdateCheckError.malformedFeed:
            return loc("The release information could not be read.")
        case let UpdateCheckError.unreadableVersion(tag):
            return loc("The latest release is tagged “%@”, which is not a version.", tag)
        case let UpdateCheckError.noDiskImage(tag):
            return loc("Release %@ has no disk image to download.", tag)
        case let UpdateCheckError.badStatus(code):
            return loc("GitHub answered %d.", code)
        default:
            return (error as NSError).localizedDescription
        }
    }
}
