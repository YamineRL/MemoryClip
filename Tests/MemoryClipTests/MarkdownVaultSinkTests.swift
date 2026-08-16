import XCTest

@testable import MemoryClip

/// Where a note lands in the vault, and — the part with the teeth in it — how
/// a second export finds the file the first one wrote.
///
/// The four steps of the idempotency contract on `MarkdownVaultSink.write` get
/// a test each. Getting one of them wrong does not fail loudly: it leaves a
/// user with two copies of the same note, or with an update that went to a
/// file they are not looking at.
final class MarkdownVaultSinkTests: XCTestCase {
    private let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("MarkdownVaultSinkTests-\(UUID().uuidString)", isDirectory: true)
    private var vault: URL { root.appendingPathComponent("Vault", isDirectory: true) }

    private let clipUUID = UUID(uuidString: "8B7F0C1E-0000-4000-8000-00000000ABCD")!
    /// 16 March 2026, 14:20 UTC.
    private let created = Date(timeIntervalSince1970: 1_773_670_800)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func draft(
        title: String = "Deploy checklist",
        uuid: UUID? = nil,
        sourceFileURL: URL? = nil
    ) -> NoteDraft {
        NoteDraft(
            clipUUID: uuid ?? clipUUID,
            title: title,
            body: "1. Tag the release",
            createdAt: created,
            sourceFileURL: sourceFileURL
        )
    }

    private func sink(useDateFolders: Bool = true, copyAttachments: Bool = false) -> MarkdownVaultSink {
        MarkdownVaultSink(
            vaultURL: vault,
            useDateFolders: useDateFolders,
            copyAttachments: copyAttachments
        )
    }

    /// The dated path the sink should choose, built from the same two pure
    /// functions the sink builds it from.
    ///
    /// Deliberately not a hardcoded string: the sink files a note in the
    /// MACHINE's zone, so a literal would be right in London and wrong in
    /// Tokyo. That the components spell `26-03 March` and `16` is asserted
    /// once, against fixed input, in `NoteComposerTests`; what is being
    /// checked here is that the sink puts the file where those say.
    private func datedFolder(for draft: NoteDraft) -> URL {
        NoteComposer.dateFolderComponents(for: draft).reduce(vault) { $0.appending(path: $1) }
    }

    private func datedURL(for draft: NoteDraft, suffix: String = "") -> URL {
        datedFolder(for: draft)
            .appending(path: "\(NoteComposer.fileNameStem(for: draft))\(suffix).md")
    }

    private func flatURL(for draft: NoteDraft) -> URL {
        vault.appending(path: "\(NoteComposer.fileNameStem(for: draft)).md")
    }

    /// Every `.md` file anywhere under the vault, as vault-relative paths.
    private func notes() throws -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: vault.path(percentEncoded: false))
        let found = try XCTUnwrap(enumerator)
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".md") }
        return found.sorted()
    }

    @discardableResult
    private func writeExisting(_ draft: NoteDraft, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(NoteComposer.markdown(for: draft).utf8).write(to: url)
        return url
    }

    // MARK: - Layout

    func testANoteIsFiledUnderItsMonthAndItsDay() async throws {
        let draft = draft()
        let receipt = try await sink().write(draft)

        XCTAssertEqual(receipt.location, datedURL(for: draft).path(percentEncoded: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.location))

        // Two folders between the vault and the file, and no more: a month
        // and a day, not a year/month/day tree.
        let relative = try XCTUnwrap(notes().first)
        let components = relative.split(separator: "/").map(String.init)
        XCTAssertEqual(components.count, 3, "expected <month>/<day>/<file>, got \(relative)")
        XCTAssertEqual(
            components.dropLast(),
            ArraySlice(NoteComposer.dateFolderComponents(for: draft))
        )
    }

    func testTheFileNameStillCarriesItsOwnDate() async throws {
        // The date is in the path now, and stays in the name anyway: the stem
        // is the dedupe key the contract turns on, and a note dragged out of
        // its folder has to still say when it is from.
        let draft = draft()
        let receipt = try await sink().write(draft)
        XCTAssertEqual(
            URL(filePath: receipt.location).deletingPathExtension().lastPathComponent,
            NoteComposer.fileNameStem(for: draft)
        )
    }

    func testTheToggleOffWritesStraightIntoTheVaultRoot() async throws {
        let draft = draft()
        let receipt = try await sink(useDateFolders: false).write(draft)

        XCTAssertEqual(receipt.location, flatURL(for: draft).path(percentEncoded: false))
        // Nothing was created beside it: off has to be byte-for-byte the
        // behaviour that shipped before dated folders existed.
        XCTAssertEqual(try notes(), [flatURL(for: draft).lastPathComponent])
    }

    // MARK: - Idempotency, step 1: the recorded path wins

    func testANoteTheUserMovedInsideTheVaultKeepsBeingUpdated() async throws {
        let draft = draft()
        let moved = vault.appending(path: "Reading/Renamed by hand.md")
        try writeExisting(draft, to: moved)

        let receipt = try await sink().write(draft, replacing: moved.path(percentEncoded: false))

        XCTAssertEqual(receipt.location, moved.path(percentEncoded: false))
        // No second copy appeared in the dated folder.
        XCTAssertEqual(try notes(), ["Reading/Renamed by hand.md"])
    }

    func testARecordedPathOutsideTheVaultIsIgnored() async throws {
        // The user switched vaults. Writing into the old folder is wrong even
        // when we could — and usually we no longer hold a grant for it.
        let elsewhere = root.appending(path: "Old vault/Deploy checklist.md")
        try writeExisting(draft(), to: elsewhere)

        let draft = draft()
        let receipt = try await sink().write(draft, replacing: elsewhere.path(percentEncoded: false))
        XCTAssertEqual(receipt.location, datedURL(for: draft).path(percentEncoded: false))
    }

    // MARK: - Idempotency, step 2: the deterministic dated path

    func testASecondExportOverwritesTheNoteInTheDatedFolder() async throws {
        let draft = draft()
        let first = try await sink().write(draft)
        let second = try await sink().write(draft)

        XCTAssertEqual(first.location, second.location)
        XCTAssertEqual(try notes().count, 1, "a re-export must not leave a ` 2` beside the first")
    }

    // MARK: - Idempotency, step 3: the flat vault root

    func testANoteAnOlderBuildLeftInTheRootIsUpdatedWhereItIs() async throws {
        // No `notePath` — the history was cleared, or the note predates dated
        // folders. Without this step, turning the folders on would re-create
        // every note the user already had.
        let draft = draft()
        let legacy = try writeExisting(draft, to: flatURL(for: draft))

        let receipt = try await sink().write(draft, replacing: nil)

        XCTAssertEqual(receipt.location, legacy.path(percentEncoded: false))
        XCTAssertEqual(try notes(), [legacy.lastPathComponent])
        // Nothing is moved: the folder for that day was never even created.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: datedFolder(for: draft).path(percentEncoded: false))
        )
    }

    func testAStrangersNoteInTheRootIsNotMistakenForOurs() async throws {
        // Same name, different clip. The root check is a `stat` plus a uuid
        // read for exactly this reason — a vault where somebody already has a
        // note called this must not have it overwritten.
        let draft = draft()
        let stranger = try writeExisting(
            self.draft(uuid: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!),
            to: flatURL(for: draft)
        )

        let receipt = try await sink().write(draft)

        XCTAssertEqual(receipt.location, datedURL(for: draft).path(percentEncoded: false))
        let untouched = try String(contentsOf: stranger, encoding: .utf8)
        XCTAssertTrue(untouched.contains("11111111-2222-4333-8444-555555555555"))
    }

    func testTheDatedNoteWinsWhenBothExist() async throws {
        // A vault that has been through both layouts converges on the dated
        // one rather than ping-ponging between two files.
        let draft = draft()
        try writeExisting(draft, to: flatURL(for: draft))
        try writeExisting(draft, to: datedURL(for: draft))

        let receipt = try await sink().write(draft)
        XCTAssertEqual(receipt.location, datedURL(for: draft).path(percentEncoded: false))
    }

    // MARK: - Idempotency, step 4: a free name

    func testACollidingNoteThatIsNotOursGetsASuffix() async throws {
        let draft = draft()
        let stranger = try writeExisting(
            self.draft(uuid: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!),
            to: datedURL(for: draft)
        )

        let receipt = try await sink().write(draft)

        XCTAssertEqual(receipt.location, datedURL(for: draft, suffix: " 2").path(percentEncoded: false))
        // Suffixing is the whole point: the other note is still there.
        let untouched = try String(contentsOf: stranger, encoding: .utf8)
        XCTAssertTrue(untouched.contains("11111111-2222-4333-8444-555555555555"))
    }

    // MARK: - Attachments

    func testTheScreenshotStaysInTheOneFolderAtTheVaultRoot() async throws {
        // An `![[name.png]]` embed resolves by searching the whole vault, so
        // mirroring the date structure under `attachments` would buy nothing —
        // and a flat attachments folder is what Obsidian's own setting makes.
        let screenshot = root.appending(path: "Screenshot.png")
        try Data("not really a png".utf8).write(to: screenshot)

        let draft = draft(sourceFileURL: screenshot)
        let receipt = try await sink(copyAttachments: true).write(draft)

        let copied = vault
            .appending(path: MarkdownVaultSink.defaultAttachmentFolderName)
            .appending(path: "\(NoteComposer.fileNameStem(for: draft)).png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path(percentEncoded: false)))
        // …while the note itself is still filed by date.
        XCTAssertEqual(receipt.location, datedURL(for: draft).path(percentEncoded: false))
    }
}
