import Foundation
import XCTest

@testable import MemoryClip

/// Telling a folder that is gone apart from one macOS will not open.
///
/// The distinction is the whole point of `FolderAccess`: `fileExists` answers
/// false for both, which is how a dropped Files and Folders grant used to
/// reach the user as "MemoryClip can no longer reach ~/Documents/Vault" — a
/// sentence that sends them looking for a folder that is sitting right there.
///
/// TCC cannot be driven from a test, but it refuses through `errno` — `EPERM`
/// where POSIX gives `EACCES` — and the code branches on both from the same
/// two calls, so a mode-000 directory exercises the path a revoked grant takes.
final class FolderAccessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FolderAccessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Restore the mode first: an unreadable directory cannot be removed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testAFolderThatOpensIsReadable() {
        XCTAssertEqual(FolderAccess.read(root), .readable)
    }

    func testAFolderThatIsNotThereIsMissing() {
        XCTAssertEqual(FolderAccess.read(root.appendingPathComponent("gone")), .missing)
    }

    func testAFolderThatCannotBeOpenedIsRefused() throws {
        try XCTSkipIf(getuid() == 0, "root reads a 000 directory regardless")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        XCTAssertEqual(FolderAccess.read(root), .refused, "a refusal must not read as a missing folder")
    }

    func testAFolderThatCannotBeEnteredIsRefused() throws {
        try XCTSkipIf(getuid() == 0, "root enters a directory without the execute bit")
        // Readable but not traversable: the vault's own files cannot be
        // reached, so listing the folder is not enough to call it readable.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: root.path)
        XCTAssertEqual(FolderAccess.read(root), .refused)
    }

    // MARK: Which folders macOS gates

    func testTheGuardedHomeFoldersAreRecognised() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for name in ["Desktop", "Documents", "Downloads"] {
            XCTAssertTrue(FolderAccess.isGuarded(home.appendingPathComponent(name)), name)
            XCTAssertTrue(
                FolderAccess.isGuarded(home.appendingPathComponent(name).appendingPathComponent("Vault")),
                "\(name) subfolder"
            )
        }
        XCTAssertTrue(FolderAccess.isGuarded(URL(fileURLWithPath: "/Volumes/Backup/Notes")))
    }

    func testAnUnguardedFolderIsNotHeldBack() {
        // The distinction earns its keep here: a folder macOS never gates must
        // not wait on a grant it will never be asked for.
        XCTAssertFalse(FolderAccess.isGuarded(root))
        XCTAssertFalse(FolderAccess.isGuarded(
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Notes")
        ))
    }

    func testAFolderMerelyNamedLikeAGuardedOneIsNotGuarded() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertFalse(FolderAccess.isGuarded(home.appendingPathComponent("DocumentsArchive")))
    }

    func testAFileWhereAFolderWasExpectedIsMissing() throws {
        // Not a permission problem, and not a folder either: the note has to
        // fail, and "pick the folder again" is the repair.
        let file = root.appendingPathComponent("notes.md")
        try Data("#".utf8).write(to: file)
        XCTAssertEqual(FolderAccess.read(file), .missing)
    }
}
