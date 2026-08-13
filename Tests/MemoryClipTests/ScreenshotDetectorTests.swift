import XCTest

@testable import MemoryClip

/// The rules that decide whether a file on disk is a screenshot worth
/// keeping. Every one of these runs without taking a screenshot: the
/// Spotlight probe is injected, and the folder rules read an injected
/// defaults suite.
final class ScreenshotDetectorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ScreenshotDetectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFile(named name: String, bytes: Int = 16) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    // MARK: - Name matching

    func testNameMatchingRequiresPrefixAndSeparator() {
        XCTAssertTrue(ScreenshotDetector.looksLikeScreenshotName(
            "Screenshot 2026-08-13 at 14.22.01.png", prefix: "Screenshot"
        ))
        XCTAssertTrue(ScreenshotDetector.looksLikeScreenshotName(
            "Screenshot-2026-08-13.png", prefix: "Screenshot"
        ))
        // A separator is required, so a user's own file that merely starts
        // with the same letters is not adopted.
        XCTAssertFalse(ScreenshotDetector.looksLikeScreenshotName(
            "Screenshots-of-2019.png", prefix: "Screenshot"
        ))
        XCTAssertFalse(ScreenshotDetector.looksLikeScreenshotName(
            "Holiday photo.png", prefix: "Screenshot"
        ))
    }

    func testNameMatchingHonoursACustomPrefix() {
        // `defaults write com.apple.screencapture name Grab` is a thing
        // people do, and localised macOS ships its own prefix.
        XCTAssertTrue(ScreenshotDetector.looksLikeScreenshotName("Grab 1.png", prefix: "Grab"))
        XCTAssertTrue(ScreenshotDetector.looksLikeScreenshotName(
            "Bildschirmfoto 2026-08-13.png", prefix: "Bildschirmfoto"
        ))
        XCTAssertFalse(ScreenshotDetector.looksLikeScreenshotName("Grab 1.png", prefix: "Screenshot"))
    }

    func testEmptyPrefixMatchesNothing() {
        // Otherwise a blank `name` default would adopt every image in the
        // folder.
        XCTAssertFalse(ScreenshotDetector.looksLikeScreenshotName("anything.png", prefix: ""))
        XCTAssertFalse(ScreenshotDetector.looksLikeScreenshotName("anything.png", prefix: "   "))
    }

    // MARK: - The composite decision

    func testSpotlightVerdictWins() throws {
        let url = try makeFile(named: "not-obviously-a-screenshot.png")
        XCTAssertTrue(ScreenshotDetector.isScreenshot(
            at: url, namePrefix: "Screenshot", metadataProbe: { _ in true }
        ))
        // …in both directions: a file that matches the name pattern but that
        // Spotlight says is NOT a screen capture is rejected.
        let named = try makeFile(named: "Screenshot 2026-08-13 at 14.22.01.png")
        XCTAssertFalse(ScreenshotDetector.isScreenshot(
            at: named, namePrefix: "Screenshot", metadataProbe: { _ in false }
        ))
    }

    func testFallbackAcceptsARecentlyNamedFileWhenSpotlightHasNoRecord() throws {
        let url = try makeFile(named: "Screenshot 2026-08-13 at 14.22.01.png")
        XCTAssertTrue(ScreenshotDetector.isScreenshot(
            at: url, namePrefix: "Screenshot", metadataProbe: { _ in nil }
        ))
    }

    func testFallbackRejectsAnOldFile() throws {
        let url = try makeFile(named: "Screenshot 2019-01-01 at 09.00.00.png")
        // The file was created now, so age is measured from a "now" far in
        // the future instead — same arithmetic, no sleeping in a test.
        let later = Date().addingTimeInterval(ScreenshotDetector.fallbackRecencyWindow + 60)
        XCTAssertFalse(ScreenshotDetector.isScreenshot(
            at: url, namePrefix: "Screenshot", now: later, metadataProbe: { _ in nil }
        ))
    }

    func testNonImagesAreNeverScreenshots() throws {
        let url = try makeFile(named: "Screenshot 2026-08-13 at 14.22.01.txt")
        // Even with Spotlight insisting, a text file has no pixels to
        // thumbnail or recognise.
        XCTAssertFalse(ScreenshotDetector.isScreenshot(
            at: url, namePrefix: "Screenshot", metadataProbe: { _ in true }
        ))
    }

    func testImageTypesAreRecognisedByUniformTypeNotExtensionList() throws {
        for ext in ["png", "jpg", "jpeg", "heic", "tiff", "gif"] {
            let url = try makeFile(named: "shot.\(ext)")
            XCTAssertTrue(ScreenshotDetector.isImage(at: url), "\(ext) should be an image")
        }
        for ext in ["txt", "pdf", "mov", "zip"] {
            let url = try makeFile(named: "file.\(ext)")
            XCTAssertFalse(ScreenshotDetector.isImage(at: url), "\(ext) should not be an image")
        }
    }

    // MARK: - Folder resolution

    private func makeSuite() throws -> (UserDefaults, String) {
        let name = "ScreenshotDetectorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (defaults, name)
    }

    func testConfiguredLocationFallsBackToDesktopWhenUnset() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(
            ScreenshotDetector.configuredLocation(defaults: defaults),
            ScreenshotDetector.desktopLocation
        )
    }

    func testConfiguredLocationExpandsATilde() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        // Any folder that certainly exists; the point is the expansion.
        defaults.set("~", forKey: "location")
        XCTAssertEqual(
            ScreenshotDetector.configuredLocation(defaults: defaults).path,
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).path
        )
    }

    func testConfiguredLocationFallsBackWhenTheFolderIsGone() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        // macOS itself reverts to the Desktop when the configured folder no
        // longer exists, so a watcher pointed at a deleted folder would be
        // watching the wrong place.
        defaults.set(directory.appendingPathComponent("gone").path, forKey: "location")
        XCTAssertEqual(
            ScreenshotDetector.configuredLocation(defaults: defaults),
            ScreenshotDetector.desktopLocation
        )
    }

    func testConfiguredLocationRejectsAFileMasqueradingAsAFolder() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let file = try makeFile(named: "not-a-folder.png")
        defaults.set(file.path, forKey: "location")
        XCTAssertEqual(
            ScreenshotDetector.configuredLocation(defaults: defaults),
            ScreenshotDetector.desktopLocation
        )
    }

    func testNamePrefixDefaultsAndOverrides() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(ScreenshotDetector.namePrefix(defaults: defaults), "Screenshot")
        defaults.set("Grab", forKey: "name")
        XCTAssertEqual(ScreenshotDetector.namePrefix(defaults: defaults), "Grab")
        // Whitespace-only is treated as unset rather than as a prefix that
        // matches everything.
        defaults.set("   ", forKey: "name")
        XCTAssertEqual(ScreenshotDetector.namePrefix(defaults: defaults), "Screenshot")
    }
}
