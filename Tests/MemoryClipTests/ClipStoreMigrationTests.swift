import SQLite3
import SwiftData
import XCTest

@testable import MemoryClip

/// Tests for the move off SwiftData's generic `default.store` path onto a
/// namespaced, owner-only one. These run entirely against temp directories —
/// they never touch the real store.
@MainActor
final class ClipStoreMigrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memoryclip-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func legacyURL() -> URL { root.appendingPathComponent("default.store") }

    private func destinationURL() throws -> URL {
        let dir = root.appendingPathComponent("app.memoryclip", isDirectory: true)
        try ClipStore.createStoreDirectory(at: dir)
        return dir.appendingPathComponent("MemoryClip.store")
    }

    /// A real SQLite file carrying a `ZCLIPITEM` table — the shape the
    /// ownership probe requires before a generic `default.store` may be
    /// adopted. Sidecars stay plain text: they are only ever copied.
    private func writeStore(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw NSError(domain: "fixture", code: 1)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(
            db,
            "CREATE TABLE ZCLIPITEM (Z_PK INTEGER PRIMARY KEY)",
            nil, nil, nil
        ) == SQLITE_OK else {
            throw NSError(domain: "fixture", code: 2)
        }
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Migration

    func testMigratesStoreAndBothSidecars() throws {
        let legacy = legacyURL()
        let destination = try destinationURL()
        try writeStore(at: legacy)
        try write("wal", to: URL(fileURLWithPath: legacy.path + "-wal"))
        try write("shm", to: URL(fileURLWithPath: legacy.path + "-shm"))

        let migrated = try ClipStore.migrateLegacyStore(from: legacy, to: destination)

        XCTAssertTrue(migrated)
        XCTAssertTrue(ClipStore.looksLikeClipStore(destination))
        XCTAssertEqual(try read(URL(fileURLWithPath: destination.path + "-wal")), "wal")
        // The ownership probe opens the staged store, and SQLite rebuilds
        // the -shm on any open — so the shm that lands at the destination is
        // a regenerated wal-index, not the copied bytes. What matters is
        // that a sidecar lands there at all.
        XCTAssertTrue(exists(URL(fileURLWithPath: destination.path + "-shm")))

        // The source is preserved until the destination has opened — here,
        // until the test finalizes it the way `init` does.
        ClipStore.finalizeLegacyMigration(legacy: legacy)
        XCTAssertFalse(exists(legacy), "The old store must not be left behind")
        XCTAssertFalse(exists(URL(fileURLWithPath: legacy.path + "-wal")))
        XCTAssertFalse(exists(URL(fileURLWithPath: legacy.path + "-shm")))
    }

    func testMigratesStoreWithoutSidecars() throws {
        let legacy = legacyURL()
        let destination = try destinationURL()
        try writeStore(at: legacy)

        XCTAssertTrue(try ClipStore.migrateLegacyStore(from: legacy, to: destination))
        XCTAssertTrue(ClipStore.looksLikeClipStore(destination))
        XCTAssertFalse(exists(URL(fileURLWithPath: destination.path + "-wal")))
    }

    func testNoLegacyStoreIsANoOp() throws {
        let destination = try destinationURL()
        XCTAssertFalse(try ClipStore.migrateLegacyStore(from: legacyURL(), to: destination))
        XCTAssertFalse(exists(destination))
    }

    /// `default.store` is the name every unsandboxed SwiftData app takes when
    /// it does not pick one: a file there that is not a MemoryClip store is
    /// somebody else's, and must be neither adopted nor deleted.
    func testAStoreThatIsNotOursIsNotAdopted() throws {
        let legacy = legacyURL()
        let destination = try destinationURL()
        try write("some other app's data", to: legacy)

        XCTAssertFalse(try ClipStore.migrateLegacyStore(from: legacy, to: destination))
        XCTAssertFalse(exists(destination), "A foreign default.store must not be adopted")
        XCTAssertEqual(try read(legacy), "some other app's data", "…or touched")
    }

    func testExistingDestinationIsNeverClobbered() throws {
        let legacy = legacyURL()
        let destination = try destinationURL()
        try write("old history", to: legacy)
        try write("live history", to: destination)

        XCTAssertFalse(try ClipStore.migrateLegacyStore(from: legacy, to: destination))
        XCTAssertEqual(try read(destination), "live history")
        XCTAssertTrue(exists(legacy), "A skipped migration must leave the legacy file alone")
    }

    /// An interrupted first attempt leaves the staging directory standing —
    /// which is what tells the next launch the destination was never
    /// committed. The relaunch quarantines the partial destination and
    /// stages the whole store again rather than trusting the half-copy.
    func testAnInterruptedMigrationIsStagedAgain() throws {
        let legacy = legacyURL()
        let destination = try destinationURL()
        try writeStore(at: legacy)

        // Simulate a crash mid-commit: a staged file, a PARTIAL destination
        // and the staging directory all still standing.
        let staging = ClipStore.migrationStagingDirectory(forStoreAt: destination)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try write("half", to: destination)

        XCTAssertTrue(try ClipStore.migrateLegacyStore(from: legacy, to: destination))
        XCTAssertTrue(
            ClipStore.looksLikeClipStore(destination),
            "the destination is the whole staged store, not the partial copy"
        )
        XCTAssertFalse(exists(staging))
    }

    func testMigrationIsIdempotent() throws {
        let legacy = legacyURL()
        let destination = try destinationURL()
        try writeStore(at: legacy)

        XCTAssertTrue(try ClipStore.migrateLegacyStore(from: legacy, to: destination))
        XCTAssertFalse(try ClipStore.migrateLegacyStore(from: legacy, to: destination))
        XCTAssertTrue(ClipStore.looksLikeClipStore(destination))
    }

    // MARK: - Permissions

    func testStoreDirectoryIsOwnerOnly() throws {
        let dir = root.appendingPathComponent("app.memoryclip", isDirectory: true)
        try ClipStore.createStoreDirectory(at: dir)

        let mode = try FileManager.default
            .attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o700)
    }

    func testCreateStoreDirectoryTightensAnExistingLooseDirectory() throws {
        let dir = root.appendingPathComponent("app.memoryclip", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        try ClipStore.createStoreDirectory(at: dir)

        let mode = try FileManager.default
            .attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o700)
    }

    func testRestrictPermissionsMakesStoreFilesOwnerOnly() throws {
        let store = root.appendingPathComponent("MemoryClip.store")
        try write("main", to: store)
        try write("wal", to: URL(fileURLWithPath: store.path + "-wal"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: store.path + "-wal"
        )

        ClipStore.restrictPermissions(forStoreAt: store)

        for path in [store.path, store.path + "-wal"] {
            let mode = try FileManager.default
                .attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.int16Value, 0o600, path)
        }
    }

    func testExternalStorageDirectoryIsMadeOwnerOnly() throws {
        let store = root.appendingPathComponent("MemoryClip.store")
        try write("main", to: store)
        let support = ClipStore.externalStorageDirectory(forStoreAt: store)
        XCTAssertEqual(support.lastPathComponent, ".MemoryClip_SUPPORT")
        let blobs = support.appendingPathComponent("_EXTERNAL_DATA", isDirectory: true)
        try FileManager.default.createDirectory(
            at: blobs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]
        )
        let blob = blobs.appendingPathComponent("ABCDEF")
        try write("image bytes", to: blob)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: blob.path)

        ClipStore.restrictPermissions(forStoreAt: store)

        func mode(_ path: String) throws -> Int16? {
            (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?
                .int16Value
        }
        XCTAssertEqual(try mode(support.path), 0o700)
        XCTAssertEqual(try mode(blobs.path), 0o700)
        XCTAssertEqual(try mode(blob.path), 0o600, "Clip bytes must not be world-readable")
    }

    func testRestrictPermissionsWithoutExternalStorageIsANoOp() throws {
        let store = root.appendingPathComponent("MemoryClip.store")
        try write("main", to: store)
        ClipStore.restrictPermissions(forStoreAt: store)
        XCTAssertFalse(exists(ClipStore.externalStorageDirectory(forStoreAt: store)))
    }

    // MARK: - Path shape

    func testStoreURLIsNamespacedAndNotTheGenericDefault() {
        XCTAssertEqual(ClipStore.storeURL.lastPathComponent, "MemoryClip.store")
        XCTAssertEqual(ClipStore.storeDirectory.lastPathComponent, "app.memoryclip")
        XCTAssertNotEqual(ClipStore.storeURL, ClipStore.legacyStoreURL)
        XCTAssertEqual(ClipStore.legacyStoreURL.lastPathComponent, "default.store")
    }

    // MARK: - External image storage

    // MARK: - Schema migration

    /// The 0.7 schema adds `Pinboard` and the secret fields to a store that
    /// shipped with ClipItem alone. SwiftData's lightweight migration adds
    /// the table and the nullable columns in place: an existing file must
    /// open, keep its rows and accept the new entity.
    func testStoreWrittenWithoutPinboardsOpensUnderTheCombinedSchema() throws {
        let store = root.appendingPathComponent("MemoryClip.store")

        // Write a row under the ClipItem-only schema every version before
        // 0.7 had: the pinboard entity and the secret columns do not exist
        // in this file yet.
        let narrow = try ModelContainer(
            for: Schema([ClipItem.self]),
            configurations: [ModelConfiguration(url: store)]
        )
        let writing = ModelContext(narrow)
        writing.insert(ClipItem(kind: .text, text: "kept across the upgrade", contentHash: "a1"))
        try writing.save()

        // Reopen under the combined schema `ClipStore` ships in 0.7.
        let wide = try ModelContainer(
            for: Schema([ClipItem.self, Pinboard.self]),
            configurations: [ModelConfiguration(url: store)]
        )
        let reading = ModelContext(wide)
        let clips = try reading.fetch(FetchDescriptor<ClipItem>())
        XCTAssertEqual(clips.map(\.text), ["kept across the upgrade"],
                       "the old row survives the added table and columns")
        XCTAssertNil(clips[0].pinboard)
        XCTAssertNil(clips[0].pinboardOrder)
        XCTAssertFalse(clips[0].isSecret)
        XCTAssertNil(clips[0].secretCipher)

        // The new entity works on the migrated store: file the old row.
        let board = try XCTUnwrap(Pinboard.create(named: "Work", in: reading))
        clips[0].file(into: board)
        try reading.save()

        let members = try XCTUnwrap(
            reading.fetch(FetchDescriptor<Pinboard>()).first
        ).orderedClips
        XCTAssertEqual(members.map(\.uuid), [clips[0].uuid])
        XCTAssertEqual(clips[0].pinboardUUID, board.uuid)
    }

    /// Core Data keeps large image blobs in a `.NAME_SUPPORT` directory keyed by
    /// the store's file name, so it has to travel with the store — otherwise a
    /// migration silently loses every externally-stored image clip.
    func testMigrationCarriesExternalImageBlobs() throws {
        let legacy = legacyURL()
        let destination = try destinationURL()

        try writeStore(at: legacy)
        let legacySupport = ClipStore.externalStorageDirectory(forStoreAt: legacy)
        try FileManager.default.createDirectory(at: legacySupport, withIntermediateDirectories: true)
        try write("png-bytes", to: legacySupport.appendingPathComponent("blob"))

        XCTAssertTrue(try ClipStore.migrateLegacyStore(from: legacy, to: destination))

        let movedSupport = ClipStore.externalStorageDirectory(forStoreAt: destination)
        XCTAssertEqual(movedSupport.lastPathComponent, ".MemoryClip_SUPPORT")
        XCTAssertEqual(try read(movedSupport.appendingPathComponent("blob")), "png-bytes")

        ClipStore.finalizeLegacyMigration(legacy: legacy)
        XCTAssertFalse(exists(legacySupport), "The old blob directory must not be left behind")
    }
}
