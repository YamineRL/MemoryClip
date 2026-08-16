import Foundation
import XCTest

@testable import MemoryClip

/// A translator with no engine behind it, so the preview's rules can be
/// tested without depending on which language pairs happen to be downloaded
/// on the machine running the suite.
private struct StubTranslator: NoteTranslator {
    /// Applied to the text, and given the target, to stand in for the engine.
    let body: @Sendable (String, Locale.Language) -> String?

    init(body: @escaping @Sendable (String, Locale.Language) -> String? = { text, _ in "Translation of: \(text)" }) {
        self.body = body
    }

    func supportedLanguages() async -> [Locale.Language] {
        [Locale.Language(identifier: "fr"), Locale.Language(identifier: "en")]
    }

    func readiness(for language: Locale.Language) async -> TranslationReadiness { .ready }

    func translate(_ text: String, from language: Locale.Language) async -> TranslatedText? {
        await translate(text, from: language, to: NoteTranslation.target)
    }

    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async -> TranslatedText? {
        guard let translated = body(text, target) else { return nil }
        return TranslatedText(text: translated, sourceLanguage: LanguageDetector.identifier(for: source))
    }
}

private let french = """
Bonjour à tous, ceci est un essai de traduction automatique du presse-papiers.
La réunion aura lieu mardi à quinze heures dans la salle du conseil.
"""

private let english = "The quick brown fox jumps over the lazy dog and keeps running."

private let englishTarget = Locale.Language(identifier: "en")
private let germanTarget = Locale.Language(identifier: "de")

/// Which of a clip's several texts is the one to translate.
final class ClipTranslationSourceTextTests: XCTestCase {
    private func sourceText(
        kind: ClipKind = .text,
        isScreenshot: Bool = false,
        text: String? = nil,
        ocrText: String? = nil,
        refinedText: String? = nil
    ) -> String? {
        ClipTranslation.sourceText(
            kind: kind,
            isScreenshot: isScreenshot,
            text: text,
            ocrText: ocrText,
            refinedText: refinedText
        )
    }

    func testTextClipsCarryTheirOwnText() {
        for kind in [ClipKind.text, .richText, .link] {
            XCTAssertEqual(sourceText(kind: kind, text: french), french, "expected \(kind) to read its own text")
        }
        // The recognition fields belong to pictures; a text clip never has
        // them, and would not read them if it did.
        XCTAssertNil(sourceText(kind: .text, ocrText: french))
    }

    func testAPictureIsReadFromWhatWasRecognisedInIt() {
        XCTAssertEqual(sourceText(kind: .image, ocrText: french), french)
        // A screenshot is a `.file` clip that references its picture on disk,
        // and is read exactly like a pasted one.
        XCTAssertEqual(sourceText(kind: .file, isScreenshot: true, ocrText: french), french)
    }

    /// The model's cleanup is what the translator should see: rejoined lines
    /// and corrected slips are the difference between a sentence and three
    /// fragments of one.
    func testTheCleanedUpRecognitionIsPreferred() {
        let cleaned = "La réunion aura lieu mardi à quinze heures."
        XCTAssertEqual(sourceText(kind: .image, ocrText: french, refinedText: cleaned), cleaned)
        XCTAssertEqual(
            sourceText(kind: .file, isScreenshot: true, ocrText: french, refinedText: cleaned),
            cleaned
        )
        // Refinement that produced nothing is not a reason to ignore the
        // recognition it was cleaning.
        XCTAssertEqual(sourceText(kind: .image, ocrText: french, refinedText: "   "), french)
    }

    func testAClipWithNothingToReadHasNoSourceText() {
        // Recognition has not run, or found nothing legible.
        XCTAssertNil(sourceText(kind: .image))
        XCTAssertNil(sourceText(kind: .image, ocrText: "  \n "))
        XCTAssertNil(sourceText(kind: .file, isScreenshot: true))
        // A colour swatch, and a file clip that is a list of paths.
        XCTAssertNil(sourceText(kind: .color, text: french))
        XCTAssertNil(sourceText(kind: .file, text: french, ocrText: french))
    }
}

/// Everything `plan` refuses to do, and the one thing it does.
final class ClipTranslationPlanTests: XCTestCase {
    private func plan(
        text: String? = french,
        cached: ClipTranslationResult? = nil,
        isEnabled: Bool = true,
        target: Locale.Language = englishTarget
    ) -> ClipTranslationPlan {
        ClipTranslation.plan(text: text, cached: cached, isEnabled: isEnabled, target: target)
    }

    // MARK: - The reasons not to translate

    func testSwitchedOffTranslatesNothing() {
        XCTAssertEqual(plan(isEnabled: false), .skip)
    }

    func testTextTooShortToIdentifyIsSkipped() {
        XCTAssertEqual(plan(text: "Bonjour"), .skip)
        XCTAssertEqual(plan(text: String(repeating: " ", count: 200)), .skip)
        XCTAssertEqual(plan(text: nil), .skip)
        // The floor is the detector's, not one of this feature's own.
        XCTAssertEqual(plan(text: String(french.prefix(LanguageDetector.minimumCharacters - 1))), .skip)
    }

    /// A wall of digits has no language, and guessing one costs a pointless
    /// translation of text that needed none.
    func testTextWithNoIdentifiableLanguageIsSkipped() {
        XCTAssertNil(LanguageDetector.dominantLanguage(of: "1234567890 0987654321 55555 4444"))
        XCTAssertEqual(plan(text: "1234567890 0987654321 55555 4444"), .skip)
    }

    func testTextAlreadyInTheTargetLanguageIsSkipped() {
        XCTAssertEqual(plan(text: english, target: englishTarget), .skip)
        XCTAssertEqual(plan(text: french, target: Locale.Language(identifier: "fr")), .skip)
        // Region is not a language: a clip in en does not need translating
        // for someone reading en-GB.
        XCTAssertEqual(plan(text: english, target: Locale.Language(identifier: "en-GB")), .skip)
    }

    // MARK: - Work

    func testForeignTextIsTranslatedIntoTheTarget() {
        guard case .translate(let request) = plan(text: french, target: germanTarget) else {
            return XCTFail("expected French text to be translated")
        }
        XCTAssertEqual(request.source.languageCode?.identifier, "fr")
        XCTAssertEqual(request.target, germanTarget)
        XCTAssertEqual(request.text, french)
        XCTAssertFalse(request.isTruncated)
    }

    /// The budget is the note pipeline's, and so is the promise that the rest
    /// of the clip is marked rather than dropped.
    func testLongTextIsBoundedAndMarkedTruncated() {
        let line = French.line + "\n"
        let text = String(repeating: line, count: 200)
        XCTAssertGreaterThan(text.count, NoteTranslation.characterBudget)

        guard case .translate(let request) = plan(text: text) else {
            return XCTFail("expected a long French clip to be translated")
        }
        XCTAssertLessThanOrEqual(request.text.count, NoteTranslation.characterBudget)
        XCTAssertTrue(request.isTruncated)
        // Whole lines only: a translator handed half a sentence completes it.
        XCTAssertTrue(request.text.split(separator: "\n").allSatisfy { $0.count == French.line.count })
    }

    // MARK: - Cache

    func testATranslationForTheCurrentTargetIsReused() {
        let cached = ClipTranslationResult(text: "Hallo", sourceLanguage: "fr", targetLanguage: "de")
        XCTAssertEqual(plan(cached: cached, target: germanTarget), .cached(cached))
        // A region on the setting is not a different language, so the cache
        // still stands.
        XCTAssertEqual(plan(cached: cached, target: Locale.Language(identifier: "de-AT")), .cached(cached))
    }

    func testATranslationForAnotherTargetIsStale() {
        let cached = ClipTranslationResult(text: "Hello", sourceLanguage: "fr", targetLanguage: "en")
        guard case .translate(let request) = plan(cached: cached, target: germanTarget) else {
            return XCTFail("expected a cache made for English to be re-translated into German")
        }
        XCTAssertEqual(request.target, germanTarget)
    }

    /// The cache is consulted before the recognizer, so a clip that would be
    /// skipped for having no identifiable language still shows what was
    /// translated when it did.
    func testTheCacheIsReadBeforeTheLanguageIsIdentified() {
        let cached = ClipTranslationResult(text: "Hello", sourceLanguage: "fr", targetLanguage: "en")
        XCTAssertEqual(plan(text: "1234567890 0987654321 55555 4444", cached: cached), .cached(cached))
    }

    // MARK: - Target identity

    /// The picker stores whatever the framework's own list is keyed on, which
    /// carries a script for every language; the clip stores what actually
    /// distinguishes one target from another.
    func testATargetIsIdentifiedByItsLanguageAndOnlyAMeaningfulScript() {
        XCTAssertEqual(ClipTranslation.identity(of: Locale.Language(identifier: "fr-Latn")), "fr")
        XCTAssertEqual(ClipTranslation.identity(of: Locale.Language(identifier: "de-AT")), "de")
        XCTAssertEqual(ClipTranslation.identity(of: Locale.Language(identifier: "zh-Hant")), "zh-Hant")
        XCTAssertEqual(ClipTranslation.identity(of: englishTarget), "en")
    }

    /// English is dropped from the note pipeline's menu because it is that
    /// pipeline's target. A target picker has no such language.
    func testTheTargetMenuKeepsEveryLanguageIncludingEnglish() {
        let rows = TranslationCatalog.menu(from: [
            Locale.Language(identifier: "en-US"),
            Locale.Language(identifier: "fr-FR"),
        ])
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.contains { $0.language.languageCode?.identifier == "en" })
        // Every row is a target `plan` can be asked about.
        for row in rows {
            XCTAssertFalse(ClipTranslation.identity(of: row.language).isEmpty)
        }
    }

    private enum French {
        /// One whole sentence, repeated until the clip runs past the budget.
        static let line = "La réunion de mardi porte sur le budget, le calendrier et les nouvelles règles du service."
    }
}

/// The one thing the service adds on top of the translator.
final class ClipTranslationServiceTests: XCTestCase {
    private func request(isTruncated: Bool = false, target: Locale.Language = germanTarget) -> ClipTranslationRequest {
        ClipTranslationRequest(
            text: french,
            isTruncated: isTruncated,
            source: Locale.Language(identifier: "fr"),
            target: target
        )
    }

    func testTheResultNamesBothLanguages() async throws {
        let service = ClipTranslationService(translator: StubTranslator())
        let translated = await service.translation(for: request())
        let result = try XCTUnwrap(translated)

        XCTAssertEqual(result.sourceLanguage, "fr")
        XCTAssertEqual(result.targetLanguage, "de")
        XCTAssertEqual(result.languagePair, "French → German")
        XCTAssertEqual(result.accessibilityDescription, "Translated from French into German")
        XCTAssertFalse(result.text.contains(NoteTranslation.truncationMarker))
    }

    /// A region on the target is not part of the pair the clip caches: a
    /// translation into de-AT is a translation into German.
    func testTheTargetIsRecordedMinimally() async throws {
        let service = ClipTranslationService(translator: StubTranslator())
        let translated = await service.translation(for: request(target: Locale.Language(identifier: "de-AT")))
        XCTAssertEqual(try XCTUnwrap(translated).targetLanguage, "de")
    }

    func testATruncatedClipSaysWhereTheTranslationStops() async throws {
        let service = ClipTranslationService(translator: StubTranslator())
        let translated = await service.translation(for: request(isTruncated: true))
        let result = try XCTUnwrap(translated)

        XCTAssertTrue(result.text.hasSuffix(NoteTranslation.truncationMarker))
        // The remainder is NOT repeated: the clip itself is on screen right
        // underneath the translation.
        XCTAssertEqual(result.text.components(separatedBy: NoteTranslation.truncationMarker).count, 2)
    }

    /// Every failure looks the same from here, and none of them is shown to
    /// the user: the pane keeps the clip it was already showing.
    func testAFailedTranslationIsNil() async {
        let service = ClipTranslationService(translator: StubTranslator { _, _ in nil })
        let result = await service.translation(for: request())
        XCTAssertNil(result)
    }

    func testTheTargetReachesTheTranslator() async throws {
        let service = ClipTranslationService(translator: StubTranslator { _, target in
            LanguageDetector.identifier(for: target)
        })
        let translated = await service.translation(for: request())
        XCTAssertEqual(try XCTUnwrap(translated).text, "de")
    }
}

/// The settings and the cache columns behind them.
@MainActor
final class ClipTranslationSettingsTests: XCTestCase {
    private let enabledKey = NoteSettingsKeys.clipTranslateEnabled
    private let targetKey = NoteSettingsKeys.clipTranslationTarget
    private var storedEnabled: Any?
    private var storedTarget: Any?

    override func setUp() {
        super.setUp()
        storedEnabled = UserDefaults.standard.object(forKey: enabledKey)
        storedTarget = UserDefaults.standard.object(forKey: targetKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(storedEnabled, forKey: enabledKey)
        UserDefaults.standard.set(storedTarget, forKey: targetKey)
        super.tearDown()
    }

    /// Off unless asked for: this reads what the user copies.
    func testTheFeatureIsOffUntilItIsSwitchedOn() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        NoteSettingsKeys.registerDefaults()
        XCTAssertFalse(ClipTranslation.isEnabled)

        UserDefaults.standard.set(true, forKey: enabledKey)
        XCTAssertTrue(ClipTranslation.isEnabled)
    }

    /// A language code, never a locale: someone on en-GB wants English.
    func testTheDefaultTargetIsABareLanguageCode() {
        let identifier = ClipTranslation.defaultTargetIdentifier
        XCTAssertFalse(identifier.isEmpty)
        XCTAssertFalse(identifier.contains("-"))
        XCTAssertEqual(Locale.Language(identifier: identifier).languageCode?.identifier, identifier)
    }

    func testAnEmptyStoredTargetFallsBackToTheDefault() {
        UserDefaults.standard.set("", forKey: targetKey)
        XCTAssertEqual(ClipTranslation.targetIdentifier, ClipTranslation.defaultTargetIdentifier)

        ClipTranslation.targetIdentifier = "ja"
        XCTAssertEqual(ClipTranslation.targetIdentifier, "ja")
        XCTAssertEqual(ClipTranslation.target.languageCode?.identifier, "ja")
    }

    func testTheCacheRoundTripsThroughTheClip() {
        let item = ClipItem(kind: .text, text: french, contentHash: "hash")
        XCTAssertNil(item.cachedClipTranslation)

        item.cachedClipTranslation = ClipTranslationResult(text: "Hallo", sourceLanguage: "fr", targetLanguage: "de")
        XCTAssertEqual(item.clipTranslationText, "Hallo")
        XCTAssertEqual(item.clipTranslationSource, "fr")
        XCTAssertEqual(item.clipTranslationTarget, "de")
        XCTAssertEqual(item.cachedClipTranslation?.languagePair, "French → German")

        item.cachedClipTranslation = nil
        XCTAssertNil(item.clipTranslationText)
        XCTAssertNil(item.clipTranslationSource)
        XCTAssertNil(item.clipTranslationTarget)
    }

    /// A clip half-written by an older build (text but no target) is not a
    /// cache: it would be shown without knowing what language it is in.
    func testAPartialCacheIsNotUsed() {
        let item = ClipItem(kind: .text, text: french, contentHash: "hash")
        item.clipTranslationText = "Hallo"
        XCTAssertNil(item.cachedClipTranslation)
    }

    /// A screenshot reads from its picture, and the model's cleanup of that
    /// recognition wins once it exists.
    func testAScreenshotIsReadFromItsRecognisedText() {
        let item = ClipItem(kind: .file, contentHash: "hash", ocrText: french, isScreenshot: true)
        XCTAssertEqual(item.clipTranslationSourceText, french)

        item.refinedText = "La réunion aura lieu mardi."
        XCTAssertEqual(item.clipTranslationSourceText, "La réunion aura lieu mardi.")
    }

    func testATextClipIsReadFromItsOwnText() {
        let item = ClipItem(kind: .text, text: french, contentHash: "hash")
        XCTAssertEqual(item.clipTranslationSourceText, french)
    }
}
