import AppKit
import XCTest

@testable import MemoryClip

/// A translator with no language assets behind it, so the pipeline can be
/// tested without depending on which pairs happen to be downloaded on the
/// machine running the suite — which varies from Mac to Mac and changes
/// under you when macOS fetches one.
private struct StubTranslator: NoteTranslator {
    /// Applied to the text to stand in for the engine.
    let translate: @Sendable (String) -> String?

    init(translate: @escaping @Sendable (String) -> String? = { "English of: \($0)" }) {
        self.translate = translate
    }

    func supportedLanguages() async -> [Locale.Language] { [Locale.Language(identifier: "ar")] }

    func readiness(for language: Locale.Language) async -> TranslationReadiness { .ready }

    func translate(_ text: String, from language: Locale.Language) async -> TranslatedText? {
        guard let translated = translate(text) else { return nil }
        return TranslatedText(text: translated, sourceLanguage: LanguageDetector.identifier(for: language))
    }
}

/// A refiner that reads only English, the way the on-device model does.
private struct EnglishOnlyRefiner: NoteRefiner {
    let isAvailable = true

    func supportsLanguage(_ language: Locale.Language?) -> Bool {
        guard let code = language?.languageCode?.identifier else { return true }
        return code == "en"
    }

    func refine(_ input: RefinementInput) async -> RefinedNote {
        guard supportsLanguage(input.language) else {
            return await PassthroughRefiner().refine(input)
        }
        return RefinedNote(
            title: "Tuesday meeting",
            summary: "Notes from the meeting.",
            tags: ["meeting"],
            cleanedText: input.rawText.replacingOccurrences(of: "  ", with: " "),
            wasRefined: true
        )
    }
}

private let arabic = """
مرحبا بالعالم
هذا اختبار للتعرف الضوئي على الحروف
الاجتماع يوم الثلاثاء الساعة الثالثة
"""

// MARK: - Detection

final class LanguageDetectorTests: XCTestCase {
    func testIdentifiesArabic() {
        let language = LanguageDetector.dominantLanguage(of: arabic)
        XCTAssertEqual(language?.languageCode?.identifier, "ar")
    }

    func testIdentifiesEnglish() {
        let text = "The quick brown fox jumps over the lazy dog and keeps running."
        XCTAssertEqual(LanguageDetector.dominantLanguage(of: text)?.languageCode?.identifier, "en")
    }

    /// A button label or a menu title is not evidence of a language, and
    /// acting on it would translate text that was already readable.
    func testShortTextIsNotIdentified() {
        XCTAssertNil(LanguageDetector.dominantLanguage(of: "Sign in"))
        XCTAssertNil(LanguageDetector.dominantLanguage(of: "OK"))
        XCTAssertNil(LanguageDetector.dominantLanguage(of: "   "))
    }

    func testOnlyNonEnglishNeedsTranslation() {
        XCTAssertTrue(LanguageDetector.needsTranslation(Locale.Language(identifier: "ar")))
        XCTAssertTrue(LanguageDetector.needsTranslation(Locale.Language(identifier: "ja")))
        XCTAssertFalse(LanguageDetector.needsTranslation(Locale.Language(identifier: "en")))
        // Region is not a language: en-GB text is already readable.
        XCTAssertFalse(LanguageDetector.needsTranslation(Locale.Language(identifier: "en-GB")))
        XCTAssertFalse(LanguageDetector.needsTranslation(nil))
    }

    func testDisplayNameFallsBackToTheIdentifier() {
        XCTAssertEqual(LanguageDetector.displayName(forIdentifier: "ar"), "Arabic")
        XCTAssertEqual(LanguageDetector.displayName(forIdentifier: "zzz"), "zzz")
    }
}

// MARK: - Bounds and pending downloads

final class NoteTranslationBoundsTests: XCTestCase {
    func testShortTextIsSentWhole() {
        let (sent, remainder) = NoteTranslation.bounded("one\ntwo")
        XCTAssertEqual(sent, "one\ntwo")
        XCTAssertTrue(remainder.isEmpty)
    }

    /// The remainder is carried, never dropped: losing the second half of a
    /// long note silently is worse than not translating it.
    func testLongTextIsCutOnALineBoundaryAndKeepsTheRemainder() {
        let line = String(repeating: "a", count: 99) + "\n"
        let text = String(repeating: line, count: 60)  // 6000 characters
        let (sent, remainder) = NoteTranslation.bounded(text)

        XCTAssertLessThanOrEqual(sent.count, NoteTranslation.characterBudget)
        XCTAssertFalse(remainder.isEmpty)
        // Whole lines only, on both sides of the cut: a translator handed
        // half a sentence completes it.
        XCTAssertTrue(sent.split(separator: "\n").allSatisfy { $0.count == 99 })
        XCTAssertTrue(remainder.split(separator: "\n").allSatisfy { $0.count == 99 })
        XCTAssertTrue(text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(remainder))
    }

    func testPendingDownloadsDedupeAndClear() {
        let key = NoteSettingsKeys.translationPending
        let original = UserDefaults.standard.stringArray(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        NoteTranslation.pendingDownloads = []
        NoteTranslation.notePendingDownload("ar")
        NoteTranslation.notePendingDownload("ar")
        NoteTranslation.notePendingDownload("th")
        XCTAssertEqual(NoteTranslation.pendingDownloads, ["ar", "th"])

        NoteTranslation.clearPendingDownload("ar")
        XCTAssertEqual(NoteTranslation.pendingDownloads, ["th"])

        for code in ["a", "b", "c", "d", "e", "f"] { NoteTranslation.notePendingDownload(code) }
        XCTAssertEqual(NoteTranslation.pendingDownloads.count, NoteTranslation.pendingDownloadLimit)
    }
}

// MARK: - Composition

final class TranslatedNoteCompositionTests: XCTestCase {
    private func draft(
        body: String = arabic,
        translation: String? = "Hello world\nThis is an OCR test\nThe meeting is on Tuesday at three",
        language: String? = "ar"
    ) -> NoteDraft {
        NoteDraft(
            clipUUID: UUID(),
            title: "Tuesday meeting",
            summary: "Notes from the meeting.",
            tags: ["meeting"],
            body: body,
            translation: translation,
            sourceLanguage: language,
            createdAt: Date(timeIntervalSince1970: 1_786_000_000)
        )
    }

    func testMarkdownCarriesBothTheOriginalAndTheTranslation() {
        let markdown = NoteComposer.markdown(for: draft())

        XCTAssertTrue(markdown.contains("lang: \"ar\""), markdown)
        XCTAssertTrue(markdown.contains("## English translation from Arabic"), markdown)
        // The original is the body, above the translation — it is the record
        // of what was on screen.
        let original = try? XCTUnwrap(markdown.range(of: "مرحبا بالعالم"))
        let translated = try? XCTUnwrap(markdown.range(of: "Hello world"))
        XCTAssertNotNil(original)
        XCTAssertNotNil(translated)
        if let original, let translated {
            XCTAssertTrue(original.lowerBound < translated.lowerBound, "The original must come first")
        }
    }

    func testHTMLAndPlainTextCarryTheTranslationToo() {
        let html = NoteComposer.html(for: draft())
        XCTAssertTrue(html.contains("<h2>English translation from Arabic</h2>"), html)
        XCTAssertTrue(html.contains("Hello world"), html)

        let plain = NoteComposer.plainText(for: draft())
        XCTAssertTrue(plain.contains("English translation from Arabic"), plain)
        XCTAssertTrue(plain.contains("مرحبا بالعالم"), plain)
        XCTAssertTrue(plain.contains("Hello world"), plain)
    }

    func testAnEnglishNoteHasNoTranslationSection() {
        let markdown = NoteComposer.markdown(
            for: draft(body: "Meeting on Tuesday at three.", translation: nil, language: nil)
        )
        XCTAssertFalse(markdown.contains("English translation"), markdown)
        XCTAssertFalse(markdown.contains("lang:"), markdown)
    }

    /// A translation identical to the body is a no-op, and printing it twice
    /// under a heading claiming it was translated is a lie.
    func testATranslationEqualToTheBodyIsDropped() {
        let text = "Meeting on Tuesday at three."
        let markdown = NoteComposer.markdown(for: draft(body: text, translation: text, language: "en"))
        XCTAssertFalse(markdown.contains("English translation"), markdown)
    }

    func testHeadingFallsBackWhenTheLanguageIsUnknown() {
        let markdown = NoteComposer.markdown(for: draft(language: nil))
        XCTAssertTrue(markdown.contains("## English translation\n"), markdown)
    }

    /// A clip whose text could not be translated but whose translation is all
    /// there is still counts as having something to write.
    func testDraftWithOnlyATranslationHasContent() {
        let draft = NoteDraft(clipUUID: UUID(), title: "", body: "", translation: "Hello world")
        XCTAssertTrue(draft.hasContent)
    }
}

// MARK: - Pipeline

@MainActor
final class TranslationPipelineTests: XCTestCase {
    override func setUpWithError() throws {
        UserDefaults.standard.set(1000, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(0, forKey: SettingsKeys.retentionDays)
        UserDefaults.standard.set(true, forKey: NoteSettingsKeys.refineEnabled)
        UserDefaults.standard.set(true, forKey: NoteSettingsKeys.translateEnabled)
        UserDefaults.standard.set(false, forKey: NoteSettingsKeys.autoNoteEnabled)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.set(true, forKey: NoteSettingsKeys.translateEnabled)
    }

    private func screenshotClip(text: String, in store: ClipStore) throws -> ClipItem {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TranslationPipelineTests-\(UUID().uuidString).png")
        let image = NSImage(size: NSSize(width: 40, height: 20))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 20).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw XCTSkip("Could not render a PNG in this environment") }
        try png.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let item = try XCTUnwrap(store.insertScreenshot(at: url))
        store.applyOCR(text, toClipWith: item.uuid)
        return try XCTUnwrap(store.item(withUUID: item.uuid))
    }

    /// The whole point: an Arabic screenshot keeps its Arabic text AND gains
    /// an English reading of it, with the note's English fields written from
    /// the translation rather than from text the model cannot read.
    func testArabicClipIsTranslatedAndLabelledInEnglish() async throws {
        let store = try ClipStore(inMemory: true)
        let item = try screenshotClip(text: arabic, in: store)

        let coordinator = NoteCoordinator(
            store: store,
            refiner: EnglishOnlyRefiner(),
            translator: StubTranslator { _ in "Hello world\nThe meeting is on Tuesday at three" }
        )
        _ = await coordinator.exportNote(for: item)

        let refreshed = try XCTUnwrap(store.item(withUUID: item.uuid))
        XCTAssertEqual(refreshed.ocrText, arabic, "The recognised text is the record and must not be overwritten")
        XCTAssertNil(refreshed.refinedText, "A translated clip keeps its own language as the body")
        XCTAssertEqual(refreshed.sourceLanguage, "ar")
        XCTAssertEqual(refreshed.translatedText, "Hello world\nThe meeting is on Tuesday at three")
        // Written from the English, which is the only text the model could read.
        XCTAssertEqual(refreshed.refinedTitle, "Tuesday meeting")
        XCTAssertEqual(refreshed.refinedTags, ["meeting"])

        let draft = try XCTUnwrap(NoteCoordinator.draft(for: refreshed))
        XCTAssertEqual(draft.body, arabic)
        XCTAssertEqual(draft.translation, "Hello world\nThe meeting is on Tuesday at three")
        XCTAssertEqual(draft.sourceLanguage, "ar")
    }

    func testEnglishClipIsNotTranslated() async throws {
        let store = try ClipStore(inMemory: true)
        let english = "The deploy checklist for Tuesday: tag the release, run the build, publish the notes."
        let item = try screenshotClip(text: english, in: store)

        let coordinator = NoteCoordinator(
            store: store,
            refiner: EnglishOnlyRefiner(),
            translator: StubTranslator { _ in XCTFail("English text must not be translated"); return nil }
        )
        _ = await coordinator.exportNote(for: item)

        let refreshed = try XCTUnwrap(store.item(withUUID: item.uuid))
        XCTAssertNil(refreshed.translatedText)
        XCTAssertNil(refreshed.sourceLanguage)
        XCTAssertEqual(refreshed.refinedText, english)
    }

    /// Translation off, or no assets for the language: the note is still
    /// written, in the language it was captured in.
    func testUntranslatableClipStillBecomesANote() async throws {
        let store = try ClipStore(inMemory: true)
        let item = try screenshotClip(text: arabic, in: store)

        let coordinator = NoteCoordinator(
            store: store,
            refiner: EnglishOnlyRefiner(),
            translator: StubTranslator { _ in nil }
        )
        _ = await coordinator.exportNote(for: item)

        let refreshed = try XCTUnwrap(store.item(withUUID: item.uuid))
        XCTAssertNil(refreshed.translatedText)
        // The language is still recorded: it is true, and it is what tells
        // the user which notes downloading Arabic would have helped.
        XCTAssertEqual(refreshed.sourceLanguage, "ar")
        let draft = try XCTUnwrap(NoteCoordinator.draft(for: refreshed))
        XCTAssertEqual(draft.body, arabic)
        XCTAssertNil(draft.translation)
        XCTAssertFalse(draft.title.isEmpty, "An untranslated clip still gets a title")
    }

    func testTranslationRespectsItsSetting() async throws {
        UserDefaults.standard.set(false, forKey: NoteSettingsKeys.translateEnabled)
        let store = try ClipStore(inMemory: true)
        let item = try screenshotClip(text: arabic, in: store)

        let coordinator = NoteCoordinator(
            store: store,
            refiner: EnglishOnlyRefiner(),
            translator: StubTranslator { _ in XCTFail("Translation is switched off"); return nil }
        )
        _ = await coordinator.exportNote(for: item)

        XCTAssertNil(try XCTUnwrap(store.item(withUUID: item.uuid)).translatedText)
    }

    /// A card number translated into English is still a card number, so the
    /// sensitive-content guard has to see the translation too.
    func testSensitiveTranslationIsDropped() throws {
        UserDefaults.standard.set(true, forKey: SensitiveFilter.filteringEnabledKey)
        let store = try ClipStore(inMemory: true)
        let item = try screenshotClip(text: "Numéro de carte 4111 1111 1111 1111", in: store)

        store.applyRefinement(
            title: "Card",
            summary: "",
            text: nil,
            tags: ["card"],
            translation: TranslatedText(text: "Card number 4111 1111 1111 1111", sourceLanguage: "fr"),
            toClipWith: item.uuid
        )

        let refreshed = try XCTUnwrap(store.item(withUUID: item.uuid))
        XCTAssertNil(refreshed.translatedText)
        XCTAssertNil(refreshed.sourceLanguage)
        XCTAssertNil(refreshed.refinedTitle)
        XCTAssertTrue(refreshed.refinedTags.isEmpty)
        XCTAssertTrue(refreshed.refineAttempted)
    }

    /// Tags belong to the text they were derived from — and for a translated
    /// clip that is the translation, not the (absent) refined text.
    func testTagsSurviveAClipWithNoRefinedText() throws {
        UserDefaults.standard.set(false, forKey: SensitiveFilter.filteringEnabledKey)
        let store = try ClipStore(inMemory: true)
        let item = try screenshotClip(text: arabic, in: store)

        store.applyRefinement(
            title: "Tuesday meeting",
            summary: "",
            text: nil,
            tags: ["meeting"],
            translation: TranslatedText(text: "The meeting is on Tuesday", sourceLanguage: "ar"),
            toClipWith: item.uuid
        )

        let refreshed = try XCTUnwrap(store.item(withUUID: item.uuid))
        XCTAssertEqual(refreshed.refinedTags, ["meeting"])
        XCTAssertEqual(refreshed.translatedText, "The meeting is on Tuesday")
    }
}

// MARK: - The language menu

final class TranslationCatalogTests: XCTestCase {
    /// Shaped like the framework's own list on macOS 26.5: maximal
    /// identifiers, several regions per language, both Chinese scripts.
    private let supported = [
        "en-Latn-US", "en-Latn-GB", "ar-Arab-AE", "zh-Hans-CN", "zh-Hant-TW", "zh-Hant-HK",
        "es-Latn-ES", "es-Latn-MX", "fr-Latn-FR", "fr-Latn-CA", "da-Latn-DK", "th-Thai-TH",
    ].map(Locale.Language.init(identifier:))

    private func menu() -> [TranslationLanguage] {
        TranslationCatalog.menu(from: supported, excluding: Locale.Language(identifier: "en-US"))
    }

    func testTargetLanguageIsNotOffered() {
        XCTAssertFalse(menu().contains { $0.language.languageCode?.identifier == "en" })
    }

    /// Regions collapse — three Spanishes is a choice with no right answer —
    /// but scripts do not: Simplified and Traditional are not the same text.
    func testRegionsCollapseAndScriptsDoNot() {
        let ids = menu().map(\.id)
        XCTAssertEqual(ids.filter { $0.hasPrefix("es") }.count, 1)
        XCTAssertEqual(ids.filter { $0.hasPrefix("fr") }.count, 1)
        XCTAssertTrue(ids.contains("zh-Hans"))
        XCTAssertTrue(ids.contains("zh-Hant"))
    }

    /// The script is spelled out only where a language has more than one, so
    /// the list reads "Danish", not "Danish (Latin)".
    func testNamesCarryTheScriptOnlyWhenItDisambiguates() {
        let names = Dictionary(uniqueKeysWithValues: menu().map { ($0.id, $0.name) })
        XCTAssertEqual(names["da-Latn"], "Danish")
        XCTAssertEqual(names["ar-Arab"], "Arabic")
        XCTAssertEqual(names["th-Thai"], "Thai")
        XCTAssertTrue(names["zh-Hans"]?.contains("Simplified") == true, "\(names["zh-Hans"] ?? "nil")")
        XCTAssertTrue(names["zh-Hant"]?.contains("Traditional") == true, "\(names["zh-Hant"] ?? "nil")")
    }

    func testMenuIsSortedByName() {
        let names = menu().map(\.name)
        XCTAssertEqual(names, names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    /// The language object handed back is the framework's own, never one
    /// rebuilt from the row's id.
    func testRowsCarryTheFrameworksOwnLanguage() throws {
        let arabic = try XCTUnwrap(menu().first { $0.id == "ar-Arab" })
        XCTAssertEqual(arabic.language.maximalIdentifier, "ar-Arab-AE")
    }

    /// The pipeline records what the recognizer saw ("ar"), which is not how
    /// the framework spells it ("ar-Arab-AE") — the menu still has to match.
    func testDetectedIdentifiersMatchTheirRow() {
        XCTAssertEqual(TranslationCatalog.row(matching: "ar", in: menu())?.id, "ar-Arab")
        XCTAssertEqual(TranslationCatalog.row(matching: "zh-Hans", in: menu())?.id, "zh-Hans")
        XCTAssertNil(TranslationCatalog.row(matching: "sw", in: menu()))
    }
}
