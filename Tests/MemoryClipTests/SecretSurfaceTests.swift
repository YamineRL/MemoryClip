import AppKit
import Foundation
import LocalAuthentication
import XCTest

@testable import MemoryClip

/// The panel-facing halves of secrets that are not the store: what a secret
/// row writes or refuses to, what search may match, what the dropdown and
/// VoiceOver say, and what an export leaves out. `SecretStoreTests` owns the
/// schema and capture side; this one owns the surfaces.
@MainActor
final class SecretSurfaceTests: XCTestCase {
    private var store: ClipStore!

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.set(1000, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(0, forKey: SettingsKeys.retentionDays)
        store = try ClipStore(inMemory: true)
    }

    /// A secret row, the way `insertSecret` would have made one: no
    /// plaintext anywhere, just the cipher, the label and the mask.
    @discardableResult
    private func insertSecret(
        label: String = "AWS access key",
        masked: String = "AKIA••••••••••••7Q2X"
    ) -> ClipItem {
        let item = ClipItem(kind: .text, text: nil, contentHash: "secret:\(UUID().uuidString)")
        item.isSecret = true
        item.secretCipher = Data("sealed".utf8)
        item.secretLabel = label
        item.secretMasked = masked
        store.context.insert(item)
        store.save()
        return item
    }

    // MARK: Pasteboard

    /// The payload builder is the last place a secret could reach the
    /// pasteboard by accident: its plaintext is not on the row, so there is
    /// no payload to build — for a copy, a paste or a drag alike.
    func testSecretHasNoPayload() {
        let secret = insertSecret()
        XCTAssertNil(PasteService.payload(for: secret, plainOnly: false))
        XCTAssertNil(PasteService.payload(for: secret, plainOnly: true))
    }

    /// A concealed write puts the plaintext on the board under
    /// `org.nspasteboard.ConcealedType` — the marker credential managers and
    /// this app's own watcher honour — and never any other readable form.
    func testConcealedWriteCarriesTheMarker() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("memoryclip-secret-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let pasteService = PasteService(
            store: store,
            watcher: PasteboardWatcher(store: store),
            pasteboard: pasteboard
        )

        XCTAssertTrue(pasteService.writeConcealed("sekrit-value"))

        XCTAssertEqual(pasteboard.string(forType: .string), "sekrit-value")
        XCTAssertNotNil(pasteboard.string(forType: PasteService.concealedType))
    }

    /// An empty concealed write must not clear the board — the same rule
    /// `write` already follows for clips with nothing to give.
    func testConcealedWriteOfEmptyTextIsANoOp() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("memoryclip-secret-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("untouched", forType: .string)
        let pasteService = PasteService(
            store: store,
            watcher: PasteboardWatcher(store: store),
            pasteboard: pasteboard
        )

        XCTAssertFalse(pasteService.writeConcealed(""))
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
    }

    // MARK: Export

    /// Secret rows never reach an export, and `secretCount()` is the number
    /// the confirmation dialog puts next to the omission.
    func testExportOmitsSecretsAndCountsThem() throws {
        _ = insertSecret()
        store.context.insert(ClipItem(kind: .text, text: "ordinary clip", contentHash: "o:1"))
        store.save()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoryclip-export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let written = try HistoryExportController.writeExport(to: url, asCSV: false, store: store)

        XCTAssertEqual(written, 1, "the secret row was left out")
        XCTAssertEqual(store.secretCount(), 1, "the count the dialog reports")
        let exported = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(exported.contains("ordinary clip"))
        XCTAssertFalse(exported.contains("AWS access key"), "not even the label is exported")
        XCTAssertFalse(exported.contains("AKIA"), "and not the mask")
    }

    // MARK: Search

    /// A secret is findable by what it shows — the label and the mask — and
    /// by nothing else: there is no content on the row to match.
    func testSearchFindsASecretByLabelAndMask() {
        let secret = insertSecret()

        XCTAssertTrue(ClipFilter(search: "aws").matchesSearch(secret))
        XCTAssertTrue(ClipFilter(search: "7Q2X").matchesSearch(secret))
        XCTAssertFalse(ClipFilter(search: "hunter2").matchesSearch(secret))
    }

    /// The label's case is the catalogue's; the search's need not be.
    func testSearchLabelIsCaseInsensitive() {
        XCTAssertTrue(ClipFilter(search: "AWS").matchesSearch(insertSecret()))
        XCTAssertTrue(ClipFilter(search: "github token").matchesSearch(
            insertSecret(label: "GitHub token", masked: "ghp_••••••••abcd")
        ))
    }

    /// Multi-term search goes through `refine`, which must keep treating the
    /// secret as searchable even though its `text` is nil.
    func testRefineSiftsSecretsByLabel() {
        let aws = insertSecret()
        let slack = insertSecret(label: "Slack token", masked: "xoxb-••••••••1234")

        XCTAssertEqual(
            ClipFilter(search: "aws key").refine([aws, slack]).map(\.uuid),
            [aws.uuid]
        )
    }

    /// A multi-clip ⌘C is a joined string of plaintext — a secret has none
    /// to contribute, so it is silently absent rather than written as its
    /// mask or its label.
    func testMixedCopyContributesNothingForASecret() {
        let secret = insertSecret()
        let ordinary = ClipItem(kind: .text, text: "plain", contentHash: "p:1")
        XCTAssertEqual(ClipSelection.copyText(for: [ordinary, secret]), "plain")
    }

    // MARK: Presentation

    /// The dropdown shows the label and mask in BOTH states: there is no
    /// plaintext to hide, so locking changes nothing about a secret row.
    func testMenuTitleIsLabelAndMaskEitherWay() {
        let secret = insertSecret()
        XCTAssertEqual(
            StatusController.menuTitle(for: secret),
            "AWS access key · AKIA••••••••••••7Q2X"
        )
        XCTAssertEqual(
            StatusController.menuTitle(for: secret, redacted: true),
            "AWS access key · AKIA••••••••••••7Q2X"
        )
    }

    /// The VoiceOver label composes what the row is — never what it holds.
    func testSecretRowLabelSpeaksTheLabelNotTheMask() {
        let label = ClipDisplay.secretRowLabel(
            label: "AWS access key",
            appName: "Terminal",
            relativeTime: "2 minutes ago"
        )
        XCTAssertEqual(label, "Secret, AWS access key, from Terminal, 2 minutes ago, Locked")
    }

    /// A one-time code says when it will delete itself. Not on a minute
    /// boundary: `expiresAt` is measured from the label's own clock, so an
    /// exact 420 s truncates to 6 the moment a second slips by.
    func testSecretRowLabelAnnouncesExpiry() {
        let label = ClipDisplay.secretRowLabel(
            label: "One-time code",
            appName: "Messages",
            relativeTime: "now",
            expiresAt: Date(timeIntervalSinceNow: 450)
        )
        XCTAssertTrue(label.contains("forgets in 7 min"))
    }

    func testAnnouncementSummaryNamesTheKind() {
        let secret = insertSecret(label: "GitHub token")
        XCTAssertEqual(secret.announcementSummary, "Secret, GitHub token")
    }

    // MARK: Auth outcome

    /// A refused prompt — whichever of the two frameworks reports it — is the
    /// "Not authenticated." case, not an error to describe.
    func testAuthCancelClassifiesBothSpellings() {
        XCTAssertTrue(SecretsService.isAuthCancel(LAError(.userCancel)))
        XCTAssertTrue(SecretsService.isAuthCancel(LAError(.appCancel)))
        XCTAssertTrue(SecretsService.isAuthCancel(
            NSError(domain: NSOSStatusErrorDomain, code: Int(errSecUserCanceled))
        ))
        XCTAssertFalse(SecretsService.isAuthCancel(LAError(.authenticationFailed)))
        XCTAssertFalse(SecretsService.isAuthCancel(SecretSealerError.malformedSealedData))
    }
}
