import AppKit
import XCTest

@testable import MemoryClip

/// A refiner with no model behind it, so the pipeline can be tested without
/// depending on whether this machine has Apple Intelligence enabled, has
/// finished downloading an asset, or is eligible at all.
private struct StubRefiner: NoteRefiner {
    let isAvailable = true
    let title: String
    let summary: String
    let tags: [String]
    /// Applied to the raw text to stand in for the model's cleanup.
    let clean: @Sendable (String) -> String

    init(
        title: String = "Deploy checklist",
        summary: String = "Steps for shipping.",
        tags: [String] = ["deploy"],
        clean: @escaping @Sendable (String) -> String = { $0.replacingOccurrences(of: "-\n", with: "") }
    ) {
        self.title = title
        self.summary = summary
        self.tags = tags
        self.clean = clean
    }

    func refine(_ input: RefinementInput) async -> RefinedNote {
        RefinedNote(
            title: title,
            summary: summary,
            tags: tags,
            cleanedText: clean(input.rawText),
            wasRefined: true
        )
    }
}

/// Recognised text → local model → note on disk.
@MainActor
final class NotePipelineTests: XCTestCase {
    /// An immutable `let` plus `nonisolated` accessors, rather than vars
    /// assigned in `setUp`: XCTest's overrides are nonisolated, so mutating
    /// main-actor state from them is a concurrency warning in Swift 6.
    private let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("NotePipelineTests-\(UUID().uuidString)", isDirectory: true)
    private nonisolated var vault: URL { root.appendingPathComponent("Vault", isDirectory: true) }
    private nonisolated var desktop: URL { root.appendingPathComponent("Desktop", isDirectory: true) }

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)

        UserDefaults.standard.set(1000, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(0, forKey: SettingsKeys.retentionDays)
        UserDefaults.standard.set(true, forKey: NoteSettingsKeys.refineEnabled)
        UserDefaults.standard.set(false, forKey: NoteSettingsKeys.autoNoteEnabled)
        UserDefaults.standard.set(
            NoteDestination.markdownVault.rawValue, forKey: NoteSettingsKeys.destination
        )
        UserDefaults.standard.set(true, forKey: NoteSettingsKeys.copyAttachments)
        UserDefaults.standard.set("attachments", forKey: NoteSettingsKeys.vaultAttachmentFolder)
        FolderBookmark.store(vault, key: NoteSettingsKeys.vaultBookmark)
    }

    override func tearDownWithError() throws {
        FolderBookmark.clear(key: NoteSettingsKeys.vaultBookmark)
        UserDefaults.standard.set(false, forKey: NoteSettingsKeys.autoNoteEnabled)
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func writeScreenshot(named name: String) throws -> URL {
        let size = NSSize(width: 200, height: 80)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw XCTSkip("Could not render a PNG in this environment") }
        let url = desktop.appendingPathComponent(name)
        try png.write(to: url)
        return url
    }

    private func noteFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: vault.path)
            .filter { $0.hasSuffix(".md") }
            .sorted()
    }

    // MARK: - End to end

    func testRecognisedTextBecomesARefinedNoteOnDisk() async throws {
        let screenshot = try writeScreenshot(named: "Screenshot 1.png")
        let store = try ClipStore(inMemory: true)
        let item = try XCTUnwrap(store.insertScreenshot(at: screenshot))
        store.applyOCR("Tag the re-\nlease and run the build for version two point one", toClipWith: item.uuid)

        let coordinator = NoteCoordinator(store: store, refiner: StubRefiner())
        let result = await coordinator.exportNote(for: item)

        guard case .success(let receipt) = result else {
            return XCTFail("export failed: \(result)")
        }

        // The clip remembers where the note went, which is what makes a
        // second export update rather than duplicate.
        let refreshed = try XCTUnwrap(store.item(withUUID: item.uuid))
        XCTAssertEqual(refreshed.notePath, receipt.location)
        XCTAssertNotNil(refreshed.noteExportedAt)
        XCTAssertEqual(refreshed.refinedTitle, "Deploy checklist")

        let markdown = try String(contentsOfFile: receipt.location, encoding: .utf8)
        XCTAssertTrue(markdown.contains("memoryclip-uuid: \(item.uuid.uuidString)"))
        // The model's cleanup is in the body…
        XCTAssertTrue(markdown.contains("Tag the release"))
        // …and the recognition it was derived from is kept underneath it.
        XCTAssertTrue(markdown.contains("## \(NoteComposer.rawTextHeading)"))
        XCTAssertTrue(markdown.contains("Tag the re-"))
    }

    func testTheScreenshotIsCopiedInAndEmbedded() async throws {
        let screenshot = try writeScreenshot(named: "Screenshot 2.png")
        let store = try ClipStore(inMemory: true)
        let item = try XCTUnwrap(store.insertScreenshot(at: screenshot))
        store.applyOCR("some recognised words worth keeping around", toClipWith: item.uuid)

        let coordinator = NoteCoordinator(store: store, refiner: StubRefiner())
        guard case .success(let receipt) = await coordinator.exportNote(for: item) else {
            return XCTFail("export failed")
        }

        let attachments = vault.appendingPathComponent("attachments", isDirectory: true)
        let copied = try FileManager.default.contentsOfDirectory(atPath: attachments.path)
        XCTAssertEqual(copied.count, 1, "the screenshot should be copied into the vault")

        let markdown = try String(contentsOfFile: receipt.location, encoding: .utf8)
        // An embed only resolves for a file inside the vault — hence the copy.
        XCTAssertTrue(markdown.contains("![[\(try XCTUnwrap(copied.first))]]"))
        // The original is untouched where the user left it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: screenshot.path))
    }

    func testExportingTwiceUpdatesTheSameNote() async throws {
        let screenshot = try writeScreenshot(named: "Screenshot 3.png")
        let store = try ClipStore(inMemory: true)
        let item = try XCTUnwrap(store.insertScreenshot(at: screenshot))
        store.applyOCR("the first recognition of this screenshot", toClipWith: item.uuid)

        let coordinator = NoteCoordinator(store: store, refiner: StubRefiner())
        guard case .success(let first) = await coordinator.exportNote(for: item) else {
            return XCTFail("first export failed")
        }
        guard case .success(let second) = await coordinator.exportNote(for: item) else {
            return XCTFail("second export failed")
        }

        XCTAssertEqual(first.location, second.location)
        XCTAssertEqual(try noteFiles().count, 1, "a re-export must not leave a second note behind")
    }

    func testAClipWithNothingToSayCannotBeNoted() async throws {
        let screenshot = try writeScreenshot(named: "Screenshot 4.png")
        let store = try ClipStore(inMemory: true)
        let item = try XCTUnwrap(store.insertScreenshot(at: screenshot))
        // Recognition found nothing legible.

        let coordinator = NoteCoordinator(store: store, refiner: StubRefiner())
        let result = await coordinator.exportNote(for: item)

        guard case .failure(let error) = result else {
            return XCTFail("an empty clip must not produce an empty note")
        }
        XCTAssertEqual(error, .nothingToWrite)
        XCTAssertTrue(try noteFiles().isEmpty)
    }

    func testAnUnconfiguredDestinationFailsWithSomethingActionable() async throws {
        FolderBookmark.clear(key: NoteSettingsKeys.vaultBookmark)
        let screenshot = try writeScreenshot(named: "Screenshot 5.png")
        let store = try ClipStore(inMemory: true)
        let item = try XCTUnwrap(store.insertScreenshot(at: screenshot))
        store.applyOCR("plenty of recognised text here to work with", toClipWith: item.uuid)

        let coordinator = NoteCoordinator(store: store, refiner: StubRefiner())
        let result = await coordinator.exportNote(for: item)

        guard case .failure(let error) = result else { return XCTFail("expected a failure") }
        XCTAssertEqual(error, .noDestinationConfigured(.markdownVault))
        // The message has to name the fix — this is the whole point of the
        // typed error.
        XCTAssertTrue(error.errorDescription?.contains("Settings") == true)
        XCTAssertNotNil(coordinator.lastError)
    }

    // MARK: - The refinement drain

    func testTheDrainRefinesEverythingRecognitionProduced() async throws {
        let store = try ClipStore(inMemory: true)
        for index in 1...3 {
            let url = try writeScreenshot(named: "Screenshot drain \(index).png")
            let item = try XCTUnwrap(store.insertScreenshot(at: url))
            store.applyOCR("recognised text number \(index) with enough length", toClipWith: item.uuid)
        }
        XCTAssertEqual(store.pendingRefinement(limit: 10).count, 3)

        let coordinator = NoteCoordinator(store: store, refiner: StubRefiner())
        coordinator.processPending()

        var attempts = 0
        while !store.pendingRefinement(limit: 1).isEmpty, attempts < 100 {
            try await Task.sleep(for: .milliseconds(50))
            attempts += 1
        }
        coordinator.stop()

        XCTAssertTrue(store.pendingRefinement(limit: 10).isEmpty)
        for item in store.recent(limit: 10) {
            XCTAssertTrue(item.refineAttempted)
            XCTAssertEqual(item.refinedTitle, "Deploy checklist")
        }
        // Nothing was written: notes are on request unless the user opted in.
        XCTAssertTrue(try noteFiles().isEmpty)
    }

    func testAutomaticNotesRespectTheLengthThreshold() async throws {
        UserDefaults.standard.set(true, forKey: NoteSettingsKeys.autoNoteEnabled)
        UserDefaults.standard.set(40, forKey: NoteSettingsKeys.autoNoteMinimumCharacters)
        defer { UserDefaults.standard.set(false, forKey: NoteSettingsKeys.autoNoteEnabled) }

        let store = try ClipStore(inMemory: true)
        let short = try XCTUnwrap(store.insertScreenshot(at: try writeScreenshot(named: "Short.png")))
        store.applyOCR("Cancel  OK", toClipWith: short.uuid)
        let long = try XCTUnwrap(store.insertScreenshot(at: try writeScreenshot(named: "Long.png")))
        store.applyOCR(
            "A screenshot with a real paragraph of text in it, well past the threshold.",
            toClipWith: long.uuid
        )

        let coordinator = NoteCoordinator(store: store, refiner: StubRefiner())
        coordinator.processPending()

        var attempts = 0
        while !store.pendingRefinement(limit: 1).isEmpty, attempts < 100 {
            try await Task.sleep(for: .milliseconds(50))
            attempts += 1
        }
        coordinator.stop()

        // A screenshot of a button pair is not a note.
        XCTAssertNil(try XCTUnwrap(store.item(withUUID: short.uuid)).notePath)
        XCTAssertNotNil(try XCTUnwrap(store.item(withUUID: long.uuid)).notePath)
        XCTAssertEqual(try noteFiles().count, 1)
    }

    // MARK: - Draft assembly

    func testDraftPrefersTheModelsTextAndKeepsTheRecognitionBeside() throws {
        let store = try ClipStore(inMemory: true)
        let item = try XCTUnwrap(store.insertScreenshot(at: try writeScreenshot(named: "Draft.png")))
        store.applyOCR("raw recognition", toClipWith: item.uuid)
        store.applyRefinement(
            title: "A title",
            summary: "A summary.",
            text: "cleaned recognition",
            tags: ["tag"],
            toClipWith: item.uuid
        )

        let draft = try XCTUnwrap(NoteCoordinator.draft(for: try XCTUnwrap(store.item(withUUID: item.uuid))))
        XCTAssertEqual(draft.body, "cleaned recognition")
        XCTAssertEqual(draft.rawText, "raw recognition")
        XCTAssertTrue(draft.wasRefined)
        XCTAssertEqual(draft.sourceFileURL?.lastPathComponent, "Draft.png")
    }

    func testDraftFallsBackToRawRecognitionWithoutDuplicatingIt() throws {
        let store = try ClipStore(inMemory: true)
        let item = try XCTUnwrap(store.insertScreenshot(at: try writeScreenshot(named: "Unrefined.png")))
        store.applyOCR("raw only", toClipWith: item.uuid)

        let draft = try XCTUnwrap(NoteCoordinator.draft(for: try XCTUnwrap(store.item(withUUID: item.uuid))))
        XCTAssertEqual(draft.body, "raw only")
        XCTAssertFalse(draft.wasRefined)
        // No "Original text" section: it would print the same paragraph twice.
        XCTAssertNil(draft.rawText)
    }
}
