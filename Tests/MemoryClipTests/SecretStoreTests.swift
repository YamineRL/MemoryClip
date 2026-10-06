import XCTest
@testable import MemoryClip

/// A `SecretSealer` whose "encryption" is a tagged copy: tests exercise the
/// round-trip contract and count the opens — each `open` stands in for the
/// user-presence prompt the real sealer would show — without a Secure
/// Enclave.
final class SoftwareSecretSealer: SecretSealer, @unchecked Sendable {
    private(set) var openCount = 0
    private(set) var sealCount = 0

    func seal(_ plaintext: Data) throws -> Data {
        sealCount += 1
        return Data("SEALED:".utf8) + plaintext
    }

    func open(_ sealed: Data) throws -> Data {
        openCount += 1
        let marker = Data("SEALED:".utf8)
        guard sealed.starts(with: marker) else {
            throw SecretSealerError.malformedSealedData
        }
        return sealed.dropFirst(marker.count)
    }
}

/// The store-facing half of PRD 02: what lands on a row, dedup, expiry,
/// demotion, the allow-list, and the watcher's routing of the three modes.
@MainActor
final class SecretStoreTests: XCTestCase {
    private var vault: SecretVault!
    private var sealer: SoftwareSecretSealer!
    private var store: ClipStore!
    private var vaultDirectory: URL!

    private let awsKey = "AKIAIOSFODNN7EXAMPLE"
    private let otpCode = "482731"

    override func setUp() async throws {
        vaultDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memoryclip-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vaultDirectory, withIntermediateDirectories: true
        )
        sealer = SoftwareSecretSealer()
        vault = SecretVault(directory: vaultDirectory, sealer: sealer)
        store = try ClipStore(inMemory: true, secrets: vault)
        // Tests start from the factory settings regardless of whatever the
        // developer machine has picked.
        SecretSettings.registerDefaults()
        UserDefaults.standard.removeObject(forKey: SecretSettingsKeys.mode)
        UserDefaults.standard.removeObject(forKey: SecretSettingsKeys.genericTokens)
        UserDefaults.standard.removeObject(forKey: SecretSettingsKeys.forgetCodes)
        UserDefaults.standard.removeObject(forKey: SecretSettingsKeys.clearClipboard)
    }

    override func tearDown() async throws {
        if let vaultDirectory {
            try? FileManager.default.removeItem(at: vaultDirectory)
        }
        store = nil
        vault = nil
        sealer = nil
        vaultDirectory = nil
    }

    private func setMode(_ mode: SecretMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: SecretSettingsKeys.mode)
    }

    /// Drive the REAL capture path on a private pasteboard.
    @discardableResult
    private func capture(_ string: String, sourceBundleID: String? = nil) -> Bool {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("memoryclip-secrets-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        let watcher = PasteboardWatcher(store: store, pasteboard: pasteboard)
        return watcher.capture(from: pasteboard, sourceBundleID: sourceBundleID, sourceAppName: nil)
    }

    // MARK: - What lands on a row

    func testSecretInsertStoresCiphertextOnly() throws {
        let item = try XCTUnwrap(
            store.insertSecret(kind: .awsAccessKey, plaintext: awsKey, sourceBundleID: "com.apple.Terminal", sourceAppName: "Terminal")
        )

        XCTAssertTrue(item.isSecret)
        XCTAssertEqual(item.kind, .text)
        XCTAssertNil(item.text)
        XCTAssertNil(item.richTextData)
        XCTAssertNil(item.ocrText)
        XCTAssertNil(item.originalText)
        XCTAssertNil(item.refinedTitle)
        XCTAssertNil(item.refinedSummary)
        XCTAssertNil(item.refinedText)
        XCTAssertTrue(item.refinedTags.isEmpty)
        XCTAssertNil(item.translatedText)
        XCTAssertNil(item.clipTranslationText)
        XCTAssertNil(item.notePath)
        XCTAssertNil(item.calendarEventID)
        XCTAssertTrue(item.fileURLStrings.isEmpty)
        XCTAssertNil(item.colorHex)
        XCTAssertEqual(item.secretLabel, "AWS access key")
        XCTAssertEqual(item.secretMasked, "AKIA••••••••••••MPLE")

        // The cipher is the only place the value lives. (The software
        // sealer's "cipher" is a tagged copy, so whether the bytes appear
        // inside it is not meaningful here — what matters is that no string
        // or data property of the ROW is the plaintext, which the nils
        // above assert.)
        XCTAssertFalse(try XCTUnwrap(item.secretCipher).isEmpty)

        // The dedup identity is keyed, not the plain text hash ordinary
        // clips get.
        XCTAssertEqual(item.contentHash, vault.hash(awsKey, for: .dedup))
        XCTAssertNotEqual(item.contentHash, ContentParser.hashText("text:\(awsKey)"))
    }

    func testRoundTripOpensThroughTheVault() throws {
        let item = try XCTUnwrap(
            store.insertSecret(kind: .apiKey, plaintext: "sk-proj-AbCdEf0123456789GhIjKlMnOpQr", sourceBundleID: nil, sourceAppName: nil)
        )
        let opened = try vault.open(try XCTUnwrap(item.secretCipher))
        XCTAssertEqual(String(data: opened, encoding: .utf8), "sk-proj-AbCdEf0123456789GhIjKlMnOpQr")
        XCTAssertEqual(sealer.openCount, 1)
    }

    func testDashedModeDropsTheCapture() {
        setMode(.drop)
        XCTAssertFalse(capture(awsKey))
        XCTAssertEqual(store.recent(limit: 10).count, 0)
        XCTAssertEqual(sealer.sealCount, 0)
    }

    func testPlainModeStoresOrdinarily() {
        setMode(.keepPlain)
        XCTAssertTrue(capture(awsKey))
        let item = store.recent(limit: 10).first
        XCTAssertEqual(item?.isSecret, false)
        XCTAssertEqual(item?.text, awsKey)
        XCTAssertNil(item?.secretCipher)
    }

    func testEncryptedModeCapturesThroughTheWatcher() {
        XCTAssertTrue(capture(awsKey))
        let item = store.recent(limit: 10).first
        XCTAssertEqual(item?.isSecret, true)
        XCTAssertNil(item?.text)
    }

    func testAllowlistedSecretIsOrdinary() {
        vault.allow(awsKey)
        XCTAssertTrue(capture(awsKey))
        let item = store.recent(limit: 10).first
        XCTAssertEqual(item?.isSecret, false)
        XCTAssertEqual(item?.text, awsKey)
    }

    // MARK: - Dedup

    func testReCopiedSecretFloatsTheExistingRow() throws {
        let first = try XCTUnwrap(store.insertSecret(kind: .awsAccessKey, plaintext: awsKey, sourceBundleID: nil, sourceAppName: nil))
        let firstCreatedAt = first.createdAt
        Thread.sleep(forTimeInterval: 0.01)
        let second = try XCTUnwrap(store.insertSecret(kind: .awsAccessKey, plaintext: awsKey, sourceBundleID: "com.apple.Terminal", sourceAppName: "Terminal"))
        XCTAssertEqual(store.recent(limit: 10).count, 1)
        XCTAssertEqual(second.uuid, first.uuid)
        XCTAssertGreaterThan(second.createdAt, firstCreatedAt)
        XCTAssertEqual(second.sourceAppName, "Terminal")
    }

    func testDistinctSecretsStayDistinct() throws {
        _ = try XCTUnwrap(store.insertSecret(kind: .awsAccessKey, plaintext: awsKey, sourceBundleID: nil, sourceAppName: nil))
        _ = try XCTUnwrap(store.insertSecret(kind: .awsAccessKey, plaintext: "AKIAZZZZZZZZZZZZZZZZ", sourceBundleID: nil, sourceAppName: nil))
        XCTAssertEqual(store.recent(limit: 10).count, 2)
    }

    func testOneTimeCodesAreNeverDeduplicated() throws {
        let first = try XCTUnwrap(store.insertSecret(kind: .oneTimeCode, plaintext: otpCode, sourceBundleID: "com.apple.MobileSMS", sourceAppName: "Messages"))
        let second = try XCTUnwrap(store.insertSecret(kind: .oneTimeCode, plaintext: otpCode, sourceBundleID: "com.apple.MobileSMS", sourceAppName: "Messages"))
        XCTAssertEqual(store.recent(limit: 10).count, 2)
        XCTAssertNotEqual(first.uuid, second.uuid)
        XCTAssertNotEqual(first.contentHash, second.contentHash)
    }

    // MARK: - Expiry

    func testOneTimeCodeExpiresByDefault() throws {
        let item = try XCTUnwrap(store.insertSecret(kind: .oneTimeCode, plaintext: otpCode, sourceBundleID: "com.apple.MobileSMS", sourceAppName: "Messages"))
        XCTAssertNotNil(item.expiresAt)
        item.expiresAt = Date(timeIntervalSinceNow: -1)
        store.save()
        store.expireSecrets()
        XCTAssertEqual(store.recent(limit: 10).count, 0)
    }

    func testPinningACodeKeepsIt() throws {
        let item = try XCTUnwrap(store.insertSecret(kind: .oneTimeCode, plaintext: otpCode, sourceBundleID: "com.apple.MobileSMS", sourceAppName: "Messages"))
        store.togglePinned(item)
        XCTAssertTrue(item.isPinned)
        // The pin cleared the expiry, so nothing now schedules it for death.
        XCTAssertNil(item.expiresAt)
        item.expiresAt = Date(timeIntervalSinceNow: -1) // even a stale value cannot kill a pinned row
        store.save()
        store.expireSecrets()
        XCTAssertEqual(store.recent(limit: 10).count, 1)
    }

    func testForgetCodesSwitchOffLeavesNoExpiry() throws {
        UserDefaults.standard.set(false, forKey: SecretSettingsKeys.forgetCodes)
        let item = try XCTUnwrap(store.insertSecret(kind: .oneTimeCode, plaintext: otpCode, sourceBundleID: "com.apple.MobileSMS", sourceAppName: "Messages"))
        XCTAssertNil(item.expiresAt)
    }

    // MARK: - Mark as Secret / Not a Secret

    func testMarkAsSecretWipesEveryPlaintextField() throws {
        let clip = CapturedClip(
            kind: .text,
            text: "ordinary note, not a credential",
            hash: ContentParser.hashText("text:ordinary note, not a credential")
        )
        store.insert(clip, sourceBundleID: nil, sourceAppName: nil)
        let item = try XCTUnwrap(store.recent(limit: 1).first)
        item.refinedTitle = "A note"
        item.notePath = "/tmp/note.md"
        store.save()

        XCTAssertTrue(store.markAsSecret(item))
        XCTAssertTrue(item.isSecret)
        XCTAssertNil(item.text)
        XCTAssertNil(item.refinedTitle)
        XCTAssertNil(item.notePath)
        XCTAssertNotNil(item.secretCipher)
        XCTAssertEqual(
            String(data: try vault.open(item.secretCipher!), encoding: .utf8),
            "ordinary note, not a credential"
        )
        // Marked rows dedup like captured ones.
        XCTAssertEqual(item.contentHash, vault.hash("ordinary note, not a credential", for: .dedup))
    }

    func testMarkAsSecretRefusesNonTextPayloads() throws {
        let clip = CapturedClip(kind: .image, imageData: Data([1, 2, 3]), hash: "img")
        store.insert(clip, sourceBundleID: nil, sourceAppName: nil)
        let item = try XCTUnwrap(store.recent(limit: 1).first)
        XCTAssertFalse(store.markAsSecret(item))
        XCTAssertFalse(item.isSecret)
    }

    /// The imported/inconsistent shape from the audit: a row that carries a
    /// text payload AND file references (or screenshot state, or pixels)
    /// cannot be half-sealed — the cipher covers only the text. Refused, not
    /// silently stripped.
    func testMarkAsSecretRefusesAMixedPayloadRow() throws {
        let clip = CapturedClip(
            kind: .text,
            text: "ordinary note, not a credential",
            richTextData: nil,
            imageData: nil,
            fileURLStrings: [],
            colorHex: nil,
            hash: ContentParser.hashText("text:ordinary note, not a credential")
        )
        store.insert(clip, sourceBundleID: nil, sourceAppName: nil)
        let item = try XCTUnwrap(store.recent(limit: 1).first)
        // An inconsistent/imported row: text AND a file reference.
        item.fileURLStrings = ["file:///tmp/attachment.png"]
        store.save()

        XCTAssertFalse(store.markAsSecret(item))
        XCTAssertFalse(item.isSecret)
        XCTAssertEqual(item.text, "ordinary note, not a credential",
                       "a refused conversion leaves the row exactly as it was")
    }

    /// A manually converted one-time code lives under the same expiry policy
    /// as a captured one: the classifier sees it the same way, so the clock
    /// starts at sealing.
    func testMarkAsSecretAppliesTheOneTimeCodeExpiry() throws {
        let clip = CapturedClip(
            kind: .text,
            text: otpCode,
            richTextData: nil,
            imageData: nil,
            fileURLStrings: [],
            colorHex: nil,
            hash: ContentParser.hashText("text:\(otpCode)")
        )
        store.insert(
            clip,
            sourceBundleID: "com.apple.MobileSMS",
            sourceAppName: "Messages"
        )
        let item = try XCTUnwrap(store.recent(limit: 1).first)

        XCTAssertTrue(store.markAsSecret(item))
        XCTAssertNotNil(
            item.expiresAt,
            "a manually sealed OTP must forget itself on the same clock as a captured one"
        )
    }

    /// The pinned escape hatch applies to manual conversion too: a code the
    /// user pinned BEFORE sealing must never get an expiry — the capture
    /// path produces exactly that state (pinning clears `expiresAt`, and
    /// unpinning does not re-stamp it).
    func testMarkAsSecretOnAPinnedCodeStampsNoExpiry() throws {
        let clip = CapturedClip(
            kind: .text,
            text: otpCode,
            richTextData: nil,
            imageData: nil,
            fileURLStrings: [],
            colorHex: nil,
            hash: ContentParser.hashText("text:\(otpCode)")
        )
        store.insert(
            clip,
            sourceBundleID: "com.apple.MobileSMS",
            sourceAppName: "Messages"
        )
        let item = try XCTUnwrap(store.recent(limit: 1).first)
        item.isPinned = true
        store.save()

        XCTAssertTrue(store.markAsSecret(item))
        XCTAssertNil(item.expiresAt, "a pinned code must not be scheduled for deletion")
    }

    func testMarkNotSecretRestoresAndAllowlists() throws {
        let item = try XCTUnwrap(store.insertSecret(kind: .genericToken, plaintext: "X9k2Vb7mPqRt4wYz8nJc5Hd6Fs3Ga0Lm1CvBxW", sourceBundleID: nil, sourceAppName: nil))
        store.markNotSecret(item, plaintext: "X9k2Vb7mPqRt4wYz8nJc5Hd6Fs3Ga0Lm1CvBxW")
        XCTAssertFalse(item.isSecret)
        XCTAssertNil(item.secretCipher)
        XCTAssertNil(item.secretLabel)
        XCTAssertEqual(item.text, "X9k2Vb7mPqRt4wYz8nJc5Hd6Fs3Ga0Lm1CvBxW")
        XCTAssertEqual(item.contentHash, ContentParser.hashText("text:X9k2Vb7mPqRt4wYz8nJc5Hd6Fs3Ga0Lm1CvBxW"))
        // The allow-list got the hash, so recapturing the same text is an
        // ordinary clip now.
        XCTAssertTrue(vault.allows("X9k2Vb7mPqRt4wYz8nJc5Hd6Fs3Ga0Lm1CvBxW"))
        XCTAssertTrue(capture("X9k2Vb7mPqRt4wYz8nJc5Hd6Fs3Ga0Lm1CvBxW"))
        XCTAssertEqual(store.recent(limit: 10).first?.isSecret, false)
    }

    // MARK: - Counts the Settings pane and export sheet read

    func testCountsSeeTheRightRows() throws {
        store.insertSecret(kind: .awsAccessKey, plaintext: awsKey, sourceBundleID: nil, sourceAppName: nil)
        let clip = CapturedClip(
            kind: .text,
            text: "just a note",
            hash: ContentParser.hashText("text:just a note")
        )
        store.insert(clip, sourceBundleID: nil, sourceAppName: nil)
        let token = CapturedClip(
            kind: .text,
            text: "sk_live_" + "4eC39HqLyjWDarjtT1zdp7dc",
            hash: ContentParser.hashText("text:sk_live_" + "4eC39HqLyjWDarjtT1zdp7dc")
        )
        store.insert(token, sourceBundleID: nil, sourceAppName: nil)

        XCTAssertEqual(store.secretCount(), 1)
        // One stored plaintext clip looks like a secret; the note does not.
        XCTAssertEqual(store.plaintextSecretCandidateCount(), 1)
    }
}
