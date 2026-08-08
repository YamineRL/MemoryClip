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
        try write("main", to: legacy)
        try write("wal", to: URL(fileURLWithPath: legacy.path + "-wal"))
        try write("shm", to: URL(fileURLWithPath: legacy.path + "-shm"))

        let migrated = try ClipStore.migrateLegacyStore(from: legacy, to: destination)

        XCTAssertTrue(migrated)
        XCTAssertEqual(try read(destination), "main")
        XCTAssertEqual(try read(URL(fileURLWithPath: destination.path + "-wal")), "wal")
        XCTAssertEqual(try read(URL(fileURLWithPath: destination.path + "-shm")), "shm")
        XCTAssertFalse(exists(legacy), "The old store must not be left behind")
        XCTAssertFalse(exists(URL(fileURLWithPath: legacy.path + "-wal")))
        XCTAssertFalse(exists(URL(fileURLWithPath: legacy.path + "-shm")))
    }

    func testMigratesStoreWithoutSidecars() throws {
        let legacy = legacyURL()
        let destination = try destinationURL()
        try write("main", to: legacy)

        XCTAssertTrue(try ClipStore.migrateLegacyStore(from: legacy, to: destination))
        XCTAssertEqual(try read(destination), "main")
        XCTAssertFalse(exists(URL(fileURLWithPath: destination.path + "-wal")))
    }

    func testNoLegacyStoreIsANoOp() throws {
        let destination = try destinationURL()
        XCTAssertFalse(try ClipStore.migrateLegacyStore(from: legacyURL(), to: destination))
        XCTAssertFalse(exists(destination))
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

    func testMigrationIsIdempotent() throws {
        let legacy = legacyURL()
        let destination = try destinationURL()
        try write("main", to: legacy)

        XCTAssertTrue(try ClipStore.migrateLegacyStore(from: legacy, to: destination))
        XCTAssertFalse(try ClipStore.migrateLegacyStore(from: legacy, to: destination))
        XCTAssertEqual(try read(destination), "main")
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

    /// Core Data keeps large image blobs in a `.NAME_SUPPORT` directory keyed by
    /// the store's file name, so it has to travel with the store — otherwise a
    /// migration silently loses every externally-stored image clip.
    func testMigrationCarriesExternalImageBlobs() throws {
        let legacy = legacyURL()
        let destination = try destinationURL()

        try write("main", to: legacy)
        let legacySupport = ClipStore.externalStorageDirectory(forStoreAt: legacy)
        try FileManager.default.createDirectory(at: legacySupport, withIntermediateDirectories: true)
        try write("png-bytes", to: legacySupport.appendingPathComponent("blob"))

        XCTAssertTrue(try ClipStore.migrateLegacyStore(from: legacy, to: destination))

        let movedSupport = ClipStore.externalStorageDirectory(forStoreAt: destination)
        XCTAssertEqual(movedSupport.lastPathComponent, ".MemoryClip_SUPPORT")
        XCTAssertEqual(try read(movedSupport.appendingPathComponent("blob")), "png-bytes")
        XCTAssertFalse(exists(legacySupport), "The old blob directory must not be left behind")
    }
}
