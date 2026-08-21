import Foundation

/// A release newer than the one running, and where its disk image is.
struct AvailableUpdate: Equatable, Sendable {
    let version: ReleaseVersion
    /// The disk image `Scripts/make_dmg.sh` built: MemoryClip.app beside an
    /// `/Applications` symlink, which is what makes "open it and drag it
    /// across" the whole of the install.
    let diskImage: URL
    /// The release's own page, for a user who would rather read the notes
    /// than take the download.
    let page: URL?
}

/// Why a check could not answer.
///
/// Spelled out rather than folded into one case because two of them are the
/// user's problem and the rest are not: a release with no disk image attached
/// and an unreadable tag are both something only a new release can fix, while
/// a transport error is worth retrying tomorrow.
enum UpdateCheckError: Error, Equatable {
    /// The endpoint answered with something that is not the JSON documented.
    case malformedFeed
    /// The tag is not an `X.Y.Z` version this app can order itself against.
    case unreadableVersion(String)
    /// The newest release carries no `.dmg` asset.
    case noDiskImage(String)
    /// A non-200 answer, which for this endpoint is rate limiting far more
    /// often than it is anything else.
    case badStatus(Int)
}

/// Reading GitHub's "latest release" answer, and deciding when to ask again.
///
/// Pure, and separate from `UpdateChecker`, for the reason `EventNotifier`
/// splits `message(...)` from `post(...)`: the decisions are the part worth
/// testing, and no test should need a network to reach them.
enum UpdateFeed {
    /// The repository the releases come from — the same one `Casks/memoryclip.rb`
    /// points its download URL at.
    static let endpoint = URL(string: "https://api.github.com/repos/YamineRL/MemoryClip/releases/latest")!

    /// Once a day, as the setting promises.
    static let interval: TimeInterval = 24 * 60 * 60

    /// Whether enough time has passed to ask again.
    ///
    /// A check that has never run is due immediately. A `last` in the future
    /// is due too: the clock moving backwards (a correction, a restored
    /// backup) must not lock the check out until the date it wrongly recorded
    /// comes round again.
    static func isDue(last: Date?, now: Date, interval: TimeInterval = interval) -> Bool {
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed >= interval || elapsed < 0
    }

    /// The update worth offering, or nil when the newest release is the one
    /// already running.
    ///
    /// Drafts and pre-releases are dropped even though `/releases/latest`
    /// already excludes both: this is the one place that decides what the app
    /// tells a user to install, and it should not depend on a server-side
    /// filter staying as documented.
    static func update(fromLatestRelease data: Data, running: ReleaseVersion) throws -> AvailableUpdate? {
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            throw UpdateCheckError.malformedFeed
        }
        guard !release.draft, !release.prerelease else { return nil }
        guard let version = ReleaseVersion(release.tagName) else {
            throw UpdateCheckError.unreadableVersion(release.tagName)
        }
        guard version > running else { return nil }
        guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
              let diskImage = URL(string: asset.downloadURL)
        else {
            throw UpdateCheckError.noDiskImage(release.tagName)
        }
        return AvailableUpdate(
            version: version,
            diskImage: diskImage,
            page: release.htmlURL.flatMap(URL.init(string:))
        )
    }

    /// The slice of GitHub's release JSON this reads. Everything else in that
    /// object is ignored, and `Decodable` on a subset is what keeps a field
    /// added upstream from breaking the check.
    private struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let htmlURL: String?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft
            case prerelease
            case htmlURL = "html_url"
            case assets
        }

        struct Asset: Decodable {
            let name: String
            let downloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
            }
        }
    }
}
