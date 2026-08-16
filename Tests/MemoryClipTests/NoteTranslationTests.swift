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

/// The bug this suite's script rules were written for: a photographed jar of
/// Laoganma chilli crisp, as Vision reads it.
///
/// The line order is the order the text boxes came back in, not reading
/// order — on a curved jar the two are not the same, and the front label,
/// the back label and the recycling marks interleave. A quarter of the
/// letters are Han; the rest are a barcode, two net weights and a brand
/// name shouted in capitals. Handed the whole string, `NLLanguageRecognizer`
/// calls it **Portuguese at 0.76** — comfortably past `minimumConfidence`,
/// which is how MemoryClip came to translate a Chinese label out of
/// Portuguese.
private let laoganmaLabel = """
开盖后请冷藏
NET WT
净含量 670 克
670 g
BPA
PVC
Net wt. 23.63 oz (670 g)
LAOGANMA
菜籽油 辣椒 豆豉 大豆油 食用盐 味精 白砂糖
6923555200041
23.63 OZ
Calories
LAO GAN MA
PRODUCT OF CHINA
SPICY CHILI CRISP
Nutrition Facts
"""

/// The same jar with the boxes in reading order, which the old detector got
/// wrong the other way: the Latin fragments split the probability four ways,
/// nothing cleared the floor, and a Chinese label was left untranslated.
private let laoganmaLabelInReadingOrder = """
LAOGANMA
LAO GAN MA
SPICY CHILI CRISP
老干妈
风味豆豉油制辣椒
NET WT 23.63 OZ
Net wt. 23.63 oz (670 g)
净含量 670 克
菜籽油 辣椒 豆豉 大豆油 食用盐 味精 白砂糖
开盖后请冷藏
Nutrition Facts
Calories 80
GB/T 20293
PVC
BPA
6923555200041
"""

private let portuguese = """
A reunião de terça-feira foi adiada para a próxima semana porque o
diretor precisa viajar para o Porto e ainda não temos o relatório.
"""

private let japanese = """
こんにちは世界
これは光学文字認識のテストです
会議は火曜日の午後三時からです
"""

private let chinese = "今天的会议改到下星期二下午三点开始，请大家提前准备好相关的材料。"

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

// MARK: - Mixed-script detection

/// The Laoganma bug and the guards written for it.
final class LanguageScriptGuardTests: XCTestCase {
    /// The report itself: a Chinese label read as Portuguese and translated
    /// out of it. Both halves are asserted, because "not Portuguese" would
    /// also be satisfied by giving up, and giving up leaves a jar the user
    /// cannot read sitting untranslated in their vault.
    func testLaoganmaLabelIsChineseAndNotPortuguese() {
        let language = LanguageDetector.dominantLanguage(of: laoganmaLabel)
        XCTAssertNotEqual(language?.languageCode?.identifier, "pt")
        XCTAssertEqual(language?.languageCode?.identifier, "zh")
    }

    /// The same label with the boxes in reading order, where the failure was
    /// a shrug rather than a wrong answer.
    func testLaoganmaLabelInReadingOrderIsAlsoChinese() {
        let language = LanguageDetector.dominantLanguage(of: laoganmaLabelInReadingOrder)
        XCTAssertEqual(language?.languageCode?.identifier, "zh")
    }

    /// The guard has to survive the user's own settings being applied to it:
    /// hinting the languages someone picked must bias detection, not close
    /// the ballot to everything else.
    func testLaoganmaLabelIsChineseWhateverTheUserPicked() {
        XCTAssertEqual(
            LanguageDetector.dominantLanguage(of: laoganmaLabel, preferring: ["zh-Hans", "ar-Arab"])?
                .languageCode?.identifier,
            "zh"
        )
        XCTAssertEqual(
            LanguageDetector.dominantLanguage(of: laoganmaLabel, preferring: ["pt-Latn", "es-Latn"])?
                .languageCode?.identifier,
            "zh"
        )
    }

    /// Text that really is Portuguese still is, which is the half of this
    /// that a script rule could easily have broken.
    func testPortugueseIsStillPortuguese() {
        XCTAssertEqual(LanguageDetector.dominantLanguage(of: portuguese)?.languageCode?.identifier, "pt")
    }

    /// And still is when the user's picked languages do not include it.
    /// Hints are a prior, not a filter — a language left out of the
    /// dictionary would otherwise be driven to zero and the sentence would
    /// come back as English.
    func testPortugueseSurvivesLanguagePreferencesItIsNotIn() {
        XCTAssertEqual(
            LanguageDetector.dominantLanguage(of: portuguese, preferring: ["zh-Hans", "ar-Arab"])?
                .languageCode?.identifier,
            "pt"
        )
    }

    /// Han alone does not tell Chinese from Japanese. Kana does, and it is
    /// the reason the script prior can override rather than only reject.
    func testJapaneseIsNotCalledChinese() {
        XCTAssertEqual(LanguageDetector.dominantLanguage(of: japanese)?.languageCode?.identifier, "ja")
    }

    /// A Japanese headline written entirely in Han — no kana to settle it —
    /// falls to the recognizer, which is shown only the ideographs and
    /// weighs their vocabulary.
    func testKanaFreeJapaneseIsNotCalledChinese() {
        let headline = "東京株式市場今日午後株価急落経済産業省発表新型半導体輸出規制強化方針"
        XCTAssertEqual(LanguageDetector.dominantLanguage(of: headline)?.languageCode?.identifier, "ja")
    }

    func testChineseIsStillChinese() {
        XCTAssertEqual(LanguageDetector.dominantLanguage(of: chinese)?.languageCode?.identifier, "zh")
    }

    /// A paragraph of English quoting a Chinese name is English. The share
    /// threshold is set where the two scripts contribute the same number of
    /// words, and three ideographs in a paragraph are nowhere near it.
    func testEnglishQuotingChineseIsStillEnglish() {
        let text = "The jar is labelled 老干妈, which the importer translates as Old Godmother chilli crisp."
        XCTAssertEqual(LanguageDetector.dominantLanguage(of: text)?.languageCode?.identifier, "en")
    }

    func testArabicSurvivesTheScriptGuard() {
        XCTAssertEqual(LanguageDetector.dominantLanguage(of: arabic)?.languageCode?.identifier, "ar")
    }
}

// MARK: - The rules the guards are built from

final class LanguageDetectorRuleTests: XCTestCase {
    /// The margin rule, exercised directly: real text almost never lands in
    /// the narrow band where it bites, so the thresholds are tested on the
    /// numbers rather than hunted for in a corpus.
    func testANearTieIsNotADecision() {
        XCTAssertNil(LanguageDetector.decisiveLanguage(in: ["pt": 0.66, "es": 0.64]))
        XCTAssertNil(LanguageDetector.decisiveLanguage(in: ["pt": 0.70, "es": 0.40]))
    }

    func testAClearWinnerIsADecision() {
        XCTAssertEqual(LanguageDetector.decisiveLanguage(in: ["pt": 0.90, "es": 0.05]), "pt")
        // The tightest pair the two thresholds together let through.
        XCTAssertEqual(LanguageDetector.decisiveLanguage(in: ["pt": 0.65, "es": 0.30]), "pt")
    }

    /// A confident single hypothesis has no runner-up to beat.
    func testASoleHypothesisIsJudgedOnConfidenceAlone() {
        XCTAssertEqual(LanguageDetector.decisiveLanguage(in: ["ar": 0.99]), "ar")
        XCTAssertNil(LanguageDetector.decisiveLanguage(in: ["ar": 0.40]))
        XCTAssertNil(LanguageDetector.decisiveLanguage(in: [:]))
    }

    func testPrefilterDropsWhatCarriesNoLanguage() {
        let filtered = LanguageDetector.signalBearingText(in: "LAOGANMA Net wt. 23.63 oz (670 g) PVC 6923555200041")
        XCTAssertFalse(filtered.contains("LAOGANMA"))
        XCTAssertFalse(filtered.contains("PVC"))
        XCTAssertFalse(filtered.contains("6923555200041"))
        XCTAssertFalse(filtered.contains("23.63"))
        // What is left is the prose: lower-case words the model can read.
        XCTAssertTrue(filtered.contains("Net"))
        XCTAssertTrue(filtered.contains("wt."))
    }

    /// The filter must never touch a script that is not written with spaces.
    /// A Chinese sentence is one whitespace-delimited token, and
    /// `Character.isNumber` is true of 三 and 千 — so the obvious rule would
    /// delete the paragraph the guard exists to protect.
    func testPrefilterKeepsUnspacedScriptsWhole() {
        XCTAssertEqual(LanguageDetector.signalBearingText(in: chinese), chinese)
        XCTAssertTrue(LanguageDetector.signalBearingText(in: laoganmaLabel).contains("菜籽油"))
    }

    /// Filtering must not be allowed to starve a short capture. An all-caps
    /// interface is nothing but tokens the filter would drop, and judging
    /// the remnant is worse than judging the original.
    func testPrefilterFallsBackWhenItStripsTooMuch() {
        let shouted = "FILE EDIT VIEW WINDOW HELP EXPORT SETTINGS"
        XCTAssertTrue(LanguageDetector.signalBearingText(in: shouted).isEmpty)
        // Whatever the recognizer makes of it, it is not read as a language
        // of another script, and it does not crash on an empty sample.
        let language = LanguageDetector.dominantLanguage(of: shouted)
        XCTAssertNotEqual(language?.languageCode?.identifier, "zh")
    }

    func testDominantScriptReadsWordsRatherThanCharacters() {
        XCTAssertEqual(LanguageDetector.dominantScript(of: laoganmaLabel), .cjk)
        XCTAssertEqual(LanguageDetector.dominantScript(of: portuguese), .latin)
        XCTAssertEqual(LanguageDetector.dominantScript(of: arabic), .arabic)
        XCTAssertEqual(LanguageDetector.dominantScript(of: japanese), .cjk)
        XCTAssertNil(LanguageDetector.dominantScript(of: "670 23.63 (%) 6923555200041"))
    }

    /// A handful of ideographs in a caption clears the share threshold on a
    /// ratio alone; the character floor is what stops a logo being read as a
    /// language.
    func testAFewIdeographsAreNotEnoughToOverruleTheRecognizer() {
        XCTAssertEqual(LanguageDetector.dominantScript(of: "Buy 老干妈 crisp"), .latin)
    }

    func testLanguageScriptsComeFromTheSystemNotATableOfOurOwn() {
        XCTAssertEqual(LanguageDetector.script(of: Locale.Language(identifier: "pt")), .latin)
        XCTAssertEqual(LanguageDetector.script(of: Locale.Language(identifier: "ja")), .cjk)
        XCTAssertEqual(LanguageDetector.script(of: Locale.Language(identifier: "zh-Hant")), .cjk)
        XCTAssertEqual(LanguageDetector.script(of: Locale.Language(identifier: "ko")), .hangul)
        XCTAssertEqual(LanguageDetector.script(of: Locale.Language(identifier: "ar")), .arabic)
        XCTAssertEqual(LanguageDetector.script(of: Locale.Language(identifier: "ru")), .cyrillic)
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

    /// A language the user did not tick is left in its own language, even
    /// when the Mac could have translated it.
    func testAnUnpickedLanguageIsNotTranslated() async throws {
        NoteTranslation.enabledLanguages = ["ja-Jpan"]
        defer { NoteTranslation.enabledLanguages = [] }

        let store = try ClipStore(inMemory: true)
        let item = try screenshotClip(text: arabic, in: store)
        let coordinator = NoteCoordinator(
            store: store,
            refiner: EnglishOnlyRefiner(),
            translator: StubTranslator { _ in XCTFail("Arabic was not picked"); return nil }
        )
        _ = await coordinator.exportNote(for: item)

        let refreshed = try XCTUnwrap(store.item(withUUID: item.uuid))
        XCTAssertNil(refreshed.translatedText)
        XCTAssertEqual(refreshed.sourceLanguage, "ar", "The language is still recorded")
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

// MARK: - Which languages the user picked

final class EnabledLanguagesTests: XCTestCase {
    override func setUpWithError() throws {
        NoteTranslation.enabledLanguages = []
    }

    override func tearDownWithError() throws {
        NoteTranslation.enabledLanguages = []
    }

    /// The default. Not "nobody chose" but "everything this Mac can do" —
    /// the only default that leaves the feature working for someone who never
    /// opens Settings.
    func testAnEmptySelectionAllowsEverything() {
        XCTAssertTrue(NoteTranslation.allowsLanguage("ar"))
        XCTAssertTrue(NoteTranslation.allowsLanguage("ja"))
    }

    func testOnlyPickedLanguagesAreTranslated() {
        NoteTranslation.enabledLanguages = ["ar-Arab", "ja-Jpan"]
        XCTAssertTrue(NoteTranslation.allowsLanguage("ar"))
        XCTAssertTrue(NoteTranslation.allowsLanguage("ja"))
        XCTAssertFalse(NoteTranslation.allowsLanguage("ru"))
    }

    /// The two sides are spelled by different libraries: the recognizer says
    /// "ar", the framework's menu says "ar-Arab".
    func testPickedAndDetectedIdentifiersNeedNotMatchExactly() {
        XCTAssertTrue(TranslationCatalog.matches(selection: "ar-Arab", detected: "ar"))
        XCTAssertTrue(TranslationCatalog.matches(selection: "zh-Hans", detected: "zh-Hans"))
        // Script is only compared when both sides name one…
        XCTAssertTrue(TranslationCatalog.matches(selection: "zh-Hans", detected: "zh"))
        // …but Simplified and Traditional are not each other.
        XCTAssertFalse(TranslationCatalog.matches(selection: "zh-Hans", detected: "zh-Hant"))
        XCTAssertFalse(TranslationCatalog.matches(selection: "ar-Arab", detected: "fa"))
    }
}
