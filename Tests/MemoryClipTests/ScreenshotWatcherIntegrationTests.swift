import AppKit
import XCTest

@testable import MemoryClip

/// The watcher against a real folder and real files: a screenshot appearing
/// on disk has to become a clip, and everything else in the folder has to be
/// left alone.
///
/// Separate from `ScreenshotWatcherTests` (which covers the pure decisions)
/// because this one depends on file-system events actually arriving, so it
/// polls with a timeout rather than asserting synchronously.
@MainActor
final class ScreenshotWatcherIntegrationTests: XCTestCase {
    private let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ScreenshotWatcherIntegration-\(UUID().uuidString)", isDirectory: true)
    private nonisolated var folder: URL { root }

    private var watcher: ScreenshotWatcher?

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        UserDefaults.standard.set(1000, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(0, forKey: SettingsKeys.retentionDays)
        UserDefaults.standard.set(true, forKey: NoteSettingsKeys.screenshotCaptureEnabled)
        // A fresh mark for every test, so one test's files are never another's
        // history.
        UserDefaults.standard.removeObject(forKey: NoteSettingsKeys.screenshotLastSeen)
        FolderBookmark.store(folder, key: NoteSettingsKeys.screenshotFolderBookmark)
    }

    override func tearDown() async throws {
        watcher?.stop()
        watcher = nil
        FolderBookmark.clear(key: NoteSettingsKeys.screenshotFolderBookmark)
        UserDefaults.standard.set(false, forKey: NoteSettingsKeys.screenshotCaptureEnabled)
        UserDefaults.standard.removeObject(forKey: NoteSettingsKeys.screenshotLastSeen)
        try? FileManager.default.removeItem(at: root)
    }

    /// A PNG named the way `screencapture` names them, so the detector's
    /// fallback path recognises it. (Spotlight will not have indexed a file
    /// in a temp folder, which is exactly the case the fallback exists for.)
    @discardableResult
    private func writeScreenshot(named name: String) throws -> URL {
        let size = NSSize(width: 240, height: 90)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw XCTSkip("Could not render a PNG in this environment") }
        let url = folder.appendingPathComponent(name)
        try png.write(to: url)
        return url
    }

    /// Poll until `condition` holds or the timeout expires. The watcher
    /// debounces and then re-measures file size, so a capture is not
    /// instantaneous by design.
    private func wait(
        upTo seconds: Double = 8,
        for condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(condition(), "timed out")
    }

    func testANewScreenshotBecomesAClip() async throws {
        let store = try ClipStore(inMemory: true)
        let watcher = ScreenshotWatcher(store: store)
        self.watcher = watcher
        watcher.start()

        // Created AFTER start, so it is unambiguously newer than the mark.
        try await Task.sleep(for: .milliseconds(200))
        let url = try writeScreenshot(named: "Screenshot 2026-08-13 at 14.22.01.png")

        try await wait { !store.recent(limit: 10).isEmpty }

        let item = try XCTUnwrap(store.recent(limit: 10).first)
        XCTAssertTrue(item.isScreenshot)
        // Compared through `resolvingSymlinksInPath` rather than as strings:
        // the folder bookmark resolves `/var/folders/…` to its real
        // `/private/var/folders/…` target, so the stored URL is the same file
        // by a different spelling.
        let stored = try XCTUnwrap(item.screenshotURL)
        XCTAssertEqual(
            stored.resolvingSymlinksInPath().standardizedFileURL,
            url.resolvingSymlinksInPath().standardizedFileURL
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
        XCTAssertTrue((item.imageData ?? Data()).isEmpty, "the bytes must stay on disk")
    }

    func testFilesThatAreNotScreenshotsAreIgnored() async throws {
        let store = try ClipStore(inMemory: true)
        let watcher = ScreenshotWatcher(store: store)
        self.watcher = watcher
        watcher.start()
        try await Task.sleep(for: .milliseconds(200))

        // A photo the user dragged in, and a document: neither matches the
        // screenshot name pattern, and neither is flagged by Spotlight.
        try writeScreenshot(named: "Holiday photo.png")
        try Data("notes".utf8).write(to: folder.appendingPathComponent("Screenshot notes.txt"))

        // Then a real screenshot, to prove the watcher was awake the whole
        // time rather than simply asleep.
        try await Task.sleep(for: .milliseconds(300))
        try writeScreenshot(named: "Screenshot 2026-08-13 at 15.00.00.png")

        try await wait { !store.recent(limit: 10).isEmpty }
        try await Task.sleep(for: .milliseconds(500))

        let items = store.recent(limit: 10)
        XCTAssertEqual(items.count, 1, "only the screenshot should have been captured")
        XCTAssertEqual(
            ClipDisplay.displayName(try XCTUnwrap(items.first?.fileURLStrings.first)),
            "Screenshot 2026-08-13 at 15.00.00.png"
        )
    }

    func testExistingFilesAreNotImportedWhenTheFeatureIsSwitchedOn() async throws {
        // The folder is full before the watcher ever runs — a Desktop with
        // three years of screenshots on it is the real version of this.
        try writeScreenshot(named: "Screenshot 2019-01-01 at 09.00.00.png")
        try writeScreenshot(named: "Screenshot 2020-02-02 at 10.00.00.png")

        let store = try ClipStore(inMemory: true)
        let watcher = ScreenshotWatcher(store: store)
        self.watcher = watcher
        watcher.start()

        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(store.recent(limit: 10).isEmpty, "enabling the feature must not sweep in history")
    }

    func testSwitchingTheSettingOffStopsCapture() async throws {
        let store = try ClipStore(inMemory: true)
        let watcher = ScreenshotWatcher(store: store)
        self.watcher = watcher
        watcher.start()
        try await Task.sleep(for: .milliseconds(200))

        UserDefaults.standard.set(false, forKey: NoteSettingsKeys.screenshotCaptureEnabled)
        // The watcher observes UserDefaults, so give the notification a beat.
        try await Task.sleep(for: .milliseconds(300))
        try writeScreenshot(named: "Screenshot 2026-08-13 at 16.00.00.png")

        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }
}
