import AppKit
import XCTest

@testable import MemoryClip

/// End-to-end tests of the *capture path* — parser and sensitive filter
/// wired together as `PasteboardWatcher` actually runs them.
///
/// The unit tests for `SensitiveFilter.isLikelyCardNumber` all passed while
/// the filter was, in practice, bypassed for every clip carrying `public.rtf`
/// (Safari, Notes, Mail, Pages, Word, Excel — i.e. most real copies). Testing
/// the predicate is not testing the defence.
@MainActor
final class CaptureWiringTests: XCTestCase {
    private var pasteboards: [NSPasteboard] = []

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: SensitiveFilter.filteringEnabledKey)
        UserDefaults.standard.set(0, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(0, forKey: SettingsKeys.retentionDays)
    }

    override func tearDown() {
        for pasteboard in pasteboards { pasteboard.releaseGlobally() }
        pasteboards = []
        UserDefaults.standard.removeObject(forKey: SensitiveFilter.filteringEnabledKey)
        super.tearDown()
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("memoryclip-wiring-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboards.append(pasteboard)
        return pasteboard
    }

    /// Put `text` on the pasteboard as BOTH plain string and RTF, the way a
    /// copy out of Safari or Notes arrives.
    private func writeRichText(_ text: String, to pasteboard: NSPasteboard) {
        let attributed = NSAttributedString(string: text)
        let rtf = attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )!
        pasteboard.declareTypes([.string, .rtf], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(rtf, forType: .rtf)
    }

    private func capture(
        _ pasteboard: NSPasteboard,
        into store: ClipStore,
        bundleID: String? = nil,
        appName: String? = nil
    ) -> Bool {
        let watcher = PasteboardWatcher(store: store, pasteboard: pasteboard)
        return watcher.capture(from: pasteboard, sourceBundleID: bundleID, sourceAppName: appName)
    }

    // MARK: - The regression this suite exists for

    func testCardNumberInRichTextIsNotCaptured() throws {
        let store = try ClipStore(inMemory: true)
        let pasteboard = makePasteboard()
        writeRichText("Pay with 4242 4242 4242 4242 exp 03/29", to: pasteboard)

        // Precondition: this really is the RTF branch, not .text/.link.
        XCTAssertEqual(ContentParser.parse(pasteboard)?.kind, .richText)

        XCTAssertFalse(capture(pasteboard, into: store), "A card in RTF must not be stored")
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }

    func testCardNumberInPlainTextIsNotCaptured() throws {
        let store = try ClipStore(inMemory: true)
        let pasteboard = makePasteboard()
        pasteboard.setString("4242 4242 4242 4242", forType: .string)

        XCTAssertFalse(capture(pasteboard, into: store))
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }

    func testCardNumberInLinkIsNotCaptured() throws {
        let store = try ClipStore(inMemory: true)
        let pasteboard = makePasteboard()
        pasteboard.setString("https://shop.example.com/pay?pan=4242424242424242", forType: .string)

        XCTAssertEqual(ContentParser.parse(pasteboard)?.kind, .link)
        XCTAssertFalse(capture(pasteboard, into: store))
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }

    func testBenignRichTextIsStillCaptured() throws {
        let store = try ClipStore(inMemory: true)
        let pasteboard = makePasteboard()
        writeRichText("just some styled prose", to: pasteboard)

        XCTAssertTrue(capture(pasteboard, into: store))
        XCTAssertEqual(store.recent(limit: 10).first?.kind, .richText)
    }

    func testFilterOffLetsTheCardThrough() throws {
        UserDefaults.standard.set(false, forKey: SensitiveFilter.filteringEnabledKey)
        let store = try ClipStore(inMemory: true)
        let pasteboard = makePasteboard()
        writeRichText("4242 4242 4242 4242", to: pasteboard)

        XCTAssertTrue(capture(pasteboard, into: store), "User opted out of filtering")
        XCTAssertEqual(store.recent(limit: 10).count, 1)
    }

    // MARK: - Credential-app guard, through the same path

    func testCopyFromCredentialAppIsNotCaptured() throws {
        let store = try ClipStore(inMemory: true)
        let pasteboard = makePasteboard()
        pasteboard.setString("hunter2", forType: .string)

        XCTAssertFalse(
            capture(pasteboard, into: store, bundleID: "com.1password.1password", appName: "1Password")
        )
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }

    func testCopyFromOrdinaryAppIsCaptured() throws {
        let store = try ClipStore(inMemory: true)
        let pasteboard = makePasteboard()
        pasteboard.setString("hello", forType: .string)

        XCTAssertTrue(
            capture(pasteboard, into: store, bundleID: "com.apple.Safari", appName: "Safari")
        )
        XCTAssertEqual(store.recent(limit: 10).first?.text, "hello")
    }

    // MARK: - Opt-out markers, through the same path

    func testEveryExcludedTypeBlocksCaptureEndToEnd() throws {
        for type in ContentParser.excludedTypes {
            let store = try ClipStore(inMemory: true)
            let pasteboard = makePasteboard()
            pasteboard.declareTypes([.string, type], owner: nil)
            pasteboard.setString("secret", forType: .string)

            XCTAssertFalse(
                capture(pasteboard, into: store),
                "\(type.rawValue) must suppress capture"
            )
            XCTAssertTrue(store.recent(limit: 10).isEmpty)
        }
    }
}
