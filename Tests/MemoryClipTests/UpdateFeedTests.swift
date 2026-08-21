import XCTest

@testable import MemoryClip

/// Version ordering, feed reading and the daily schedule — everything the
/// update check decides before it is allowed to tell a user to install
/// something.
final class UpdateFeedTests: XCTestCase {
    // MARK: Versions

    func testAVersionParsesWithAndWithoutTheTagPrefix() throws {
        let plain = try XCTUnwrap(ReleaseVersion("0.5.1"))
        XCTAssertEqual([plain.major, plain.minor, plain.patch], [0, 5, 1])
        XCTAssertEqual(ReleaseVersion("v0.5.1"), plain)
        XCTAssertEqual(ReleaseVersion(" v0.5.1 "), plain)
    }

    /// Nil rather than a lenient fallback: 0.0.0 for an unreadable string
    /// would make every release look newer than the one running.
    func testAnythingThatIsNotXYZIsRejected() {
        for text in ["", "1.0", "1.0.0.0", "1.0.x", "1..0", "one.two.three", "1.0.0-beta", "v", "1.-2.0", "1.+2.0"] {
            XCTAssertNil(ReleaseVersion(text), "\(text) parsed")
        }
    }

    func testVersionsOrderByComponent() {
        XCTAssertLessThan(ReleaseVersion("0.5.0")!, ReleaseVersion("0.5.1")!)
        XCTAssertLessThan(ReleaseVersion("0.5.9")!, ReleaseVersion("0.6.0")!)
        XCTAssertLessThan(ReleaseVersion("0.9.9")!, ReleaseVersion("1.0.0")!)
        // Not a string comparison: "0.10.0" sorts below "0.9.0" as text.
        XCTAssertLessThan(ReleaseVersion("0.9.0")!, ReleaseVersion("0.10.0")!)
        XCTAssertEqual(ReleaseVersion("1.2.3"), ReleaseVersion("v1.2.3"))
    }

    // MARK: The schedule

    func testACheckThatNeverRanIsDue() {
        XCTAssertTrue(UpdateFeed.isDue(last: nil, now: Date()))
    }

    func testACheckIsDueOnlyAfterTheIntervalHasPassed() {
        let last = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertFalse(UpdateFeed.isDue(last: last, now: last.addingTimeInterval(UpdateFeed.interval - 1)))
        XCTAssertTrue(UpdateFeed.isDue(last: last, now: last.addingTimeInterval(UpdateFeed.interval)))
    }

    /// A clock that moved backwards — a correction, a restored backup — must
    /// not lock the check out until the date it wrongly recorded comes round.
    func testALastCheckInTheFutureIsDueImmediately() {
        let last = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertTrue(UpdateFeed.isDue(last: last, now: last.addingTimeInterval(-60)))
    }

    // MARK: Reading the feed

    func testANewerReleaseIsOfferedWithItsDiskImage() throws {
        let update = try XCTUnwrap(
            UpdateFeed.update(fromLatestRelease: Self.release(tag: "v0.6.0"), running: Self.running)
        )
        XCTAssertEqual(update.version, ReleaseVersion("0.6.0"))
        XCTAssertEqual(
            update.diskImage.absoluteString,
            "https://github.com/YamineRL/MemoryClip/releases/download/v0.6.0/MemoryClip-0.6.0.dmg"
        )
        XCTAssertEqual(update.page?.absoluteString, "https://github.com/YamineRL/MemoryClip/releases/tag/v0.6.0")
    }

    func testTheRunningVersionAndAnOlderOneAreNotOffered() throws {
        XCTAssertNil(try UpdateFeed.update(fromLatestRelease: Self.release(tag: "v0.5.0"), running: Self.running))
        XCTAssertNil(try UpdateFeed.update(fromLatestRelease: Self.release(tag: "v0.4.9"), running: Self.running))
    }

    /// `/releases/latest` already excludes both, but this is the one place
    /// that decides what a user is told to install and it should not depend
    /// on a server-side filter staying as documented.
    func testDraftsAndPreReleasesAreNeverOffered() throws {
        XCTAssertNil(
            try UpdateFeed.update(fromLatestRelease: Self.release(tag: "v9.0.0", draft: true), running: Self.running)
        )
        XCTAssertNil(
            try UpdateFeed.update(
                fromLatestRelease: Self.release(tag: "v9.0.0", prerelease: true),
                running: Self.running
            )
        )
    }

    /// The zip is published beside the DMG for Homebrew, and the DMG is the
    /// one with the `/Applications` symlink that makes the install a drag.
    func testTheDiskImageIsPickedOutOfTheOtherAssets() throws {
        let json = """
        {
          "tag_name": "v0.6.0", "draft": false, "prerelease": false, "html_url": null,
          "assets": [
            {"name": "MemoryClip-0.6.0.zip", "browser_download_url": "https://example.invalid/a.zip"},
            {"name": "MemoryClip-0.6.0.dmg", "browser_download_url": "https://example.invalid/a.dmg"}
          ]
        }
        """
        let update = try XCTUnwrap(
            UpdateFeed.update(fromLatestRelease: Data(json.utf8), running: Self.running)
        )
        XCTAssertEqual(update.diskImage.absoluteString, "https://example.invalid/a.dmg")
        XCTAssertNil(update.page)
    }

    func testAReleaseWithNoDiskImageIsAnError() {
        let json = """
        {"tag_name": "v0.6.0", "draft": false, "prerelease": false, "assets": []}
        """
        XCTAssertThrowsError(try UpdateFeed.update(fromLatestRelease: Data(json.utf8), running: Self.running)) {
            XCTAssertEqual($0 as? UpdateCheckError, .noDiskImage("v0.6.0"))
        }
    }

    func testAnUnreadableTagIsAnErrorRatherThanAnUpdate() {
        let json = """
        {"tag_name": "nightly", "draft": false, "prerelease": false, "assets": []}
        """
        XCTAssertThrowsError(try UpdateFeed.update(fromLatestRelease: Data(json.utf8), running: Self.running)) {
            XCTAssertEqual($0 as? UpdateCheckError, .unreadableVersion("nightly"))
        }
    }

    func testSomethingThatIsNotTheDocumentedJSONIsAnError() {
        for body in ["", "not json", "{}", "[]"] {
            XCTAssertThrowsError(
                try UpdateFeed.update(fromLatestRelease: Data(body.utf8), running: Self.running),
                body
            ) {
                XCTAssertEqual($0 as? UpdateCheckError, .malformedFeed, body)
            }
        }
    }

    /// A field added upstream must not break the check.
    func testUnknownFieldsAreIgnored() throws {
        let json = """
        {
          "tag_name": "v0.6.0", "draft": false, "prerelease": false,
          "html_url": "https://example.invalid/r", "something_new": {"nested": [1, 2]},
          "assets": [{"name": "x.dmg", "browser_download_url": "https://example.invalid/x.dmg", "size": 42}]
        }
        """
        XCTAssertNotNil(try UpdateFeed.update(fromLatestRelease: Data(json.utf8), running: Self.running))
    }

    // MARK: The banner

    func testTheBannerNamesTheVersionAndWhatTheButtonWillDo() {
        let message = UpdateNotifier.message(version: ReleaseVersion("0.6.0")!)
        XCTAssertTrue(message.title.contains("0.6.0"), message.title)
        XCTAssertTrue(
            message.body.contains(loc("Download it and MemoryClip will open the disk image for you to drag across.")),
            "the banner must say the install ends in a disk image, not an install: \(message.body)"
        )
    }

    // MARK: Fixtures

    private static let running = ReleaseVersion("0.5.0")!

    private static func release(tag: String, draft: Bool = false, prerelease: Bool = false) -> Data {
        let json = """
        {
          "tag_name": "\(tag)",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "html_url": "https://github.com/YamineRL/MemoryClip/releases/tag/\(tag)",
          "assets": [
            {
              "name": "MemoryClip-\(tag.dropFirst()).dmg",
              "browser_download_url": "https://github.com/YamineRL/MemoryClip/releases/download/\(tag)/MemoryClip-\(tag.dropFirst()).dmg"
            }
          ]
        }
        """
        return Data(json.utf8)
    }
}
