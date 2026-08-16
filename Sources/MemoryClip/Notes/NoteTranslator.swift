import Foundation
import NaturalLanguage

/// Reading a screenshot that is not in English (Phase 5).
///
/// # What this layer is for
///
/// Recognition is language-blind once `OCRService` turns automatic language
/// detection on: an Arabic screenshot comes back as Arabic, a Japanese one
/// as Japanese. Everything downstream of it is not. Apple's on-device model
/// reads 23 locales and Arabic, Hindi, Russian, Thai and Ukrainian are not
/// among them (`SystemLanguageModel.supportedLanguages`), so refinement of a
/// language it cannot read is at best a no-op and at worst a rewrite that
/// `RefinementGuard` has no way to judge. And a note the user cannot read
/// back is not a note.
///
/// So a clip whose text is not in `NoteTranslation.target` is translated
/// first, on-device, and the note carries BOTH: the original text as
/// recognised, and the English rendering underneath it. The original is the
/// record — the same contract the raw OCR has against refinement — and the
/// translation is the part that makes it findable and readable.
///
/// # Why the seam is here and not in the provider
///
/// The same reasoning as `NoteRefiner`: this file imports NaturalLanguage
/// (which is present everywhere) but not Translation, so the pipeline
/// compiles and runs where the framework or its language assets are missing,
/// the detection rules are unit-testable without a translation session, and
/// a second provider is a conformance rather than a rewrite.
///
/// # The failure contract
///
/// Identical to refinement's, and for the same reason — the original text is
/// already persisted on the clip before anything here runs and stays there
/// afterwards. `translate` does not throw and does not block anything the
/// user is waiting on; every failure (unsupported pair, assets not
/// downloaded, cancellation) returns nil, which downstream means "write the
/// note in its own language", not "try again".

// MARK: - Types

/// A completed translation.
struct TranslatedText: Sendable, Equatable {
    /// The translated text, in `NoteTranslation.target`.
    var text: String
    /// What it was translated FROM, as a BCP-47 identifier ("ar", "ja").
    /// Stored on the clip and written into note front matter, so a vault can
    /// be queried for everything that arrived in a given language.
    var sourceLanguage: String
}

/// Anything that can turn foreign-language text into English.
protocol NoteTranslator: Sendable {
    /// Every language this Mac can translate, downloaded or not — as a source
    /// for the note pipeline, and as a target for the preview pane.
    ///
    /// Read live rather than hard-coded: the list is Apple's, it grows with
    /// macOS releases, and a list of our own would be wrong the moment one
    /// does. Settings turns it into the menus the user picks from.
    func supportedLanguages() async -> [Locale.Language]

    /// Whether `language` could be translated into `NoteTranslation.target`
    /// right now, without a download.
    ///
    /// Three-valued rather than a Bool because the middle case is the one the
    /// user can do something about — see `TranslationReadiness`.
    func readiness(for language: Locale.Language) async -> TranslationReadiness

    /// The same question for a pair the caller chooses. The preview pane
    /// translates into the user's own language rather than into English —
    /// see `ClipTranslation` — so it asks about a pair, not a source.
    func readiness(from source: Locale.Language, to target: Locale.Language) async -> TranslationReadiness

    /// Never throws: anything that goes wrong returns nil and the note is
    /// written in its original language.
    func translate(_ text: String, from language: Locale.Language) async -> TranslatedText?

    /// Translate into a chosen language. Same contract: nil rather than a
    /// throw, and the caller shows the original.
    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async -> TranslatedText?
}

/// The pair-aware calls, for a translator that only knows one target.
///
/// Every conformer answers about its own fixed target — English, for the two
/// in this app that predate the preview pane, and whatever a test stub was
/// told to return. A provider that can genuinely translate into more than one
/// language implements both and these defaults never run.
extension NoteTranslator {
    func readiness(from source: Locale.Language, to target: Locale.Language) async -> TranslationReadiness {
        await readiness(for: source)
    }

    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async -> TranslatedText? {
        await translate(text, from: source)
    }
}

/// Whether a language pair can be used, could be after a download, or never.
enum TranslationReadiness: Sendable, Equatable {
    /// The assets are on the Mac; translation works now.
    case ready
    /// macOS can translate this language, but the assets have not been
    /// downloaded. Nothing MemoryClip does in the background can fetch them —
    /// see `AppleTranslator.translate` — so this is surfaced in Settings with
    /// a button rather than swallowed.
    case needsDownload
    /// macOS cannot translate this language at all.
    case unsupported
}

// MARK: - Settings and target

/// The fixed points of translation: what we translate into, and how much of
/// a clip is worth translating.
enum NoteTranslation {
    /// The language notes are translated into.
    ///
    /// English rather than the user's preferred locale, deliberately: it is
    /// the language the rest of the pipeline is best at — the on-device model
    /// reads it, `RefinementGuard`'s tokenizer was tuned on it — and it is
    /// the one pairing macOS ships assets for most widely. The original text
    /// is always kept, so this is a second reading of the note, never a
    /// replacement of it.
    static let target = Locale.Language(identifier: "en-US")

    /// The identifier written into note front matter for `target`.
    static let targetIdentifier = "en"

    /// How much text is translated, in characters.
    ///
    /// Translation is by far the slowest stage of the pipeline. Measured on
    /// an M1 Pro (macOS 26.5) against an installed es→en pair: ~180
    /// characters took 2.5 s including session warm-up, and a 10,080
    /// character block took **80 seconds** — the cost is close to linear, so
    /// an unbounded screenshot of a long article would hold the note queue
    /// for well over a minute. 4000 characters is ~30 s worst case and
    /// covers a dense full-screen page of text; past that the remainder is
    /// carried through untranslated behind `truncationMarker` rather than
    /// silently dropped.
    static let characterBudget = 4000

    /// How far back from the budget a line boundary is worth looking for,
    /// as a fraction of it. Same rule and same reasoning as
    /// `FoundationModelsRefiner.lineBoundarySearchFloor`: cutting mid-sentence
    /// hands the translator a fragment.
    static let lineBoundarySearchFloor = 0.8

    /// Marks where the translation stops and untranslated text begins.
    static let truncationMarker = "— translation ends here; the rest is untranslated —"

    /// Whether the user has translation switched on. Registered `true`;
    /// treated as on when the key was never registered (tests, wiped
    /// defaults), matching `FoundationModelsRefiner.isEnabled`.
    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: NoteSettingsKeys.translateEnabled) != nil else { return true }
        return defaults.bool(forKey: NoteSettingsKeys.translateEnabled)
    }

    /// Split `text` into the part sent to the translator and the untouched
    /// remainder, cutting on a line boundary where one is close enough.
    static func bounded(_ text: String) -> (sent: String, remainder: String) {
        guard text.count > characterBudget else { return (text, "") }

        let hardCut = text.index(text.startIndex, offsetBy: characterBudget)
        let searchFloor = text.index(
            text.startIndex,
            offsetBy: Int(Double(characterBudget) * lineBoundarySearchFloor)
        )
        let cut = text[searchFloor..<hardCut].lastIndex(of: "\n") ?? hardCut

        return (
            String(text[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines),
            String(text[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// The languages the user picked to have detected and translated, as
    /// catalog identifiers.
    static var enabledLanguages: [String] {
        get { UserDefaults.standard.stringArray(forKey: NoteSettingsKeys.translationLanguages) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: NoteSettingsKeys.translationLanguages) }
    }

    /// Whether a clip detected as `identifier` is one the user wants
    /// translated.
    ///
    /// An empty selection means yes to everything. That is not a shortcut for
    /// "nobody chose": it is the only default that leaves the feature working
    /// for someone who never opens Settings, and it degrades safely, because
    /// a language whose assets are not on the Mac is skipped a moment later
    /// anyway. Once the user picks languages, the picked set is exactly what
    /// gets translated — which is the point of picking.
    static func allowsLanguage(_ identifier: String) -> Bool {
        let selected = enabledLanguages
        guard !selected.isEmpty else { return true }
        return selected.contains { TranslationCatalog.matches(selection: $0, detected: identifier) }
    }

    /// Languages MemoryClip has met and could not translate for want of a
    /// download, as BCP-47 identifiers.
    ///
    /// Written by the pipeline, read by Settings, which is the only place
    /// that CAN fix it: a translation session created outside SwiftUI reports
    /// `canRequestDownloads == false` and can never fetch an asset, so the
    /// background path's only honest move is to leave a note of what was
    /// missing. Capped and deduplicated, because this is a to-do list for the
    /// user, not a log.
    static var pendingDownloads: [String] {
        get { UserDefaults.standard.stringArray(forKey: NoteSettingsKeys.translationPending) ?? [] }
        set {
            let trimmed = Array(newValue.reduce(into: [String]()) { seen, code in
                if !seen.contains(code) { seen.append(code) }
            }.suffix(pendingDownloadLimit))
            UserDefaults.standard.set(trimmed, forKey: NoteSettingsKeys.translationPending)
        }
    }

    /// Most languages remembered as needing a download. Five is more than a
    /// Settings callout can list without becoming a wall.
    static let pendingDownloadLimit = 5

    static func notePendingDownload(_ identifier: String) {
        guard !identifier.isEmpty else { return }
        pendingDownloads = pendingDownloads + [identifier]
    }

    static func clearPendingDownload(_ identifier: String) {
        pendingDownloads = pendingDownloads.filter { $0 != identifier }
    }
}

// MARK: - Detection

/// Which language a piece of recognised text is in.
///
/// Split out from the translator so the rule that decides whether to
/// translate at all is testable without any translation assets on the
/// machine — the same reason `RefinementGuard` is separate from the model.
///
/// # Why the recognizer is not believed on its own
///
/// `NLLanguageRecognizer` scores an n-gram model of every language it knows
/// against the whole string and reports the winner. That is the right answer
/// for a paragraph and the wrong one for a photograph of a jar. A jar of
/// Laoganma chilli crisp comes back from Vision as `LAOGANMA / SPICY CHILI
/// CRISP / 净含量 670 克 / Net wt. 23.63 oz (670 g) / 菜籽油 辣椒 豆豉 /
/// PVC / BPA / 6923555200041`, and the recognizer weighs that Latin half —
/// units, a barcode, a brand shouted in capitals — against the same models
/// it would use on prose and calls the label **Portuguese at 0.76**, well
/// past `minimumConfidence`. A quarter of the letters on it were Han and
/// they counted for nothing. That is how a jar of chilli crisp came to be
/// translated out of a language nobody had written on it.
///
/// So three guards sit around the recognizer, in the order they run:
///
/// 1. `signalBearingText` drops the part numbers, net weights and shouted
///    brand names, which are evidence for no language and, to an n-gram
///    model, evidence for some language.
/// 2. `dominantScript` counts what the text is *written in* and, when a
///    non-Latin script holds enough of it, answers from the script instead —
///    a census of characters is a fact, and an inference that contradicts it
///    is wrong however confident it sounds.
/// 3. `decisiveLanguage` makes the winning hypothesis beat its runner-up
///    rather than merely clear a floor.
///
/// The cost model behind all three is unchanged and still asymmetric: a
/// false positive translates text the user could already read, a false
/// negative is the note we would have written anyway. The one place that
/// argument flips is a label in a script the user cannot read at all, which
/// is why guard 2 overrides rather than rejects.
enum LanguageDetector {
    // MARK: Thresholds

    /// Below this many characters, identification is guesswork.
    ///
    /// `NLLanguageRecognizer` will happily name a language for "OK" or for a
    /// row of menu titles, and a wrong answer here costs a pointless
    /// translation of text that was already English. Screenshots are full of
    /// short fragments, so the floor is deliberately above the length of a
    /// button label.
    static let minimumCharacters = 20

    /// How sure the recognizer has to be before we act on it.
    ///
    /// Applied to the top hypothesis. Latin-script languages compete with
    /// each other (a Spanish sentence with three English nouns in it splits
    /// its probability), and the cost of a false positive — translating text
    /// the user can already read — is worse than the cost of a false
    /// negative, which is simply the note we would have written anyway.
    static let minimumConfidence = 0.65

    /// How far clear of the runner-up the top hypothesis has to be.
    ///
    /// A confidence floor on its own cannot say "that was close": it passes
    /// a winner that took the lead by a hundredth. The hypotheses are a
    /// distribution over every language, so a top score at the 0.65 floor
    /// already caps its nearest rival at 0.35 — which means any margin below
    /// 0.30 is a rule that can never fire. 0.35 is the smallest number that
    /// fires at all, and what it asks for is that the winner hold at least
    /// twice the mass of the runner-up: 0.65 against 0.30 is the tightest
    /// pair that gets through, 0.66 against 0.34 does not. Nothing
    /// legitimate is near that line — measured on Arabic, Chinese, Japanese,
    /// Korean, Russian, Portuguese and English samples, the margin on text
    /// that really is in one language runs from 0.80 to 1.00.
    static let minimumMargin = 0.35

    /// The share of a text's letters one non-Latin script has to hold before
    /// it overrules the recognizer.
    ///
    /// Set where the two scripts contribute the same number of *words*, not
    /// the same number of characters, because per character they are not
    /// comparable: a Han ideograph is a word where an English word is about
    /// five letters. Equal word counts fall at f = (1 − f) / 5, or f ≈ 0.17.
    /// 0.15 sits under that with room to spare, which is what the Laoganma
    /// label needs (0.24 of its letters are Han before filtering, 0.47
    /// after) while an English page quoting a Chinese place name — two or
    /// three ideographs in a paragraph — stays well below it.
    static let minimumScriptShare = 0.15

    /// How many characters of a script there have to be before its share is
    /// worth reading at all.
    ///
    /// The share alone is a ratio, and a ratio computed over a handful of
    /// characters says nothing: three ideographs in a twenty-character
    /// caption clear 0.15 and are still a logo rather than a sentence. Eight
    /// is about eight words of an ideographic script and one short phrase of
    /// an alphabetic one, which is the least that could be called text.
    static let minimumScriptCharacters = 8

    /// The share of CJK characters that have to be kana before the text is
    /// called Japanese outright.
    ///
    /// Kana is written by exactly one language, so its presence is proof
    /// rather than evidence and the bar is only high enough to rule out a
    /// stray character — a Chinese page quoting a Japanese product name.
    /// Ordinary Japanese prose is around half kana by character.
    static let minimumKanaShare = 0.05

    /// How many hypotheses are read back from the recognizer.
    ///
    /// Enough to see the runner-up and to know which languages were on the
    /// ballot at all, which is what `languageHints` needs (see below).
    static let hypothesisDepth = 10

    /// The prior weight given to a language the user did not pick.
    ///
    /// Hints are a prior, and a language *absent* from the dictionary is
    /// driven to zero, not left alone: a Portuguese paragraph hinted with
    /// only Chinese, Arabic and English came back as English at 1.00. So
    /// every language the unhinted pass thought plausible is put back on the
    /// ballot at this floor before the user's own languages are lifted above
    /// it, and the recognizer keeps the right to disagree with the user.
    static let neutralHintWeight = 0.01

    /// The prior weight given to a language the user asked to have detected.
    ///
    /// 30:1 against `neutralHintWeight` — enough to settle a scrap between
    /// Latin-script neighbours (on the Laoganma label, hinting Chinese,
    /// Arabic and English moved a four-way split led by Indonesian at 0.30
    /// to English at 0.58), and nowhere near enough to overturn text that
    /// really is in another language: that Portuguese paragraph still came
    /// back as Portuguese at 1.00 with Portuguese hinted at a thousandth.
    static let preferredHintWeight = 0.30

    // MARK: Scripts

    /// A writing system, as far as character ranges can tell them apart.
    ///
    /// Coarser than ISO 15924 on purpose. Han and kana are one case because
    /// Japanese mixes them in every sentence and counting them apart would
    /// split one language's vote between two scripts; `other` is every
    /// letter outside the ranges named here, so the census stays total and a
    /// script we do not model reads as "no prior" rather than as Latin.
    enum Script: String, Sendable, CaseIterable {
        case latin
        case cjk
        case hangul
        case arabic
        case cyrillic
        case hebrew
        case greek
        case thai
        case devanagari
        case other
    }

    /// The script a single character belongs to, or nil when it is not a
    /// letter at all — a digit, a bracket, a space.
    static func script(of scalar: Unicode.Scalar) -> Script? {
        guard scalar.properties.isAlphabetic else { return nil }
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x02AF, 0x1E00...0x1EFF: return .latin
        case 0x3040...0x30FF, 0x31F0...0x31FF: return .cjk  // hiragana, katakana
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return .cjk  // han
        case 0x1100...0x11FF, 0xA960...0xA97F, 0xAC00...0xD7FF: return .hangul
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
        case 0x0400...0x052F: return .cyrillic
        case 0x0590...0x05FF: return .hebrew
        case 0x0370...0x03FF, 0x1F00...0x1FFF: return .greek
        case 0x0E00...0x0E7F: return .thai
        case 0x0900...0x097F: return .devanagari
        default: return .other
        }
    }

    /// The script a language is written in, taken from the system's own
    /// likely-subtag data rather than a table of our own: "pt" maximises to
    /// pt-Latn-BR, "ja" to ja-Jpan-JP, "ur" to ur-Aran-PK.
    static func script(of language: Locale.Language) -> Script? {
        switch language.script?.identifier {
        case "Latn": return .latin
        case "Hans", "Hant", "Hani", "Jpan", "Hrkt", "Hira", "Kana": return .cjk
        case "Kore", "Hang": return .hangul
        case "Arab", "Aran": return .arabic
        case "Cyrl": return .cyrillic
        case "Hebr": return .hebrew
        case "Grek": return .greek
        case "Thai": return .thai
        case "Deva": return .devanagari
        default: return nil
        }
    }

    /// The script `text` is written in, or nil when it holds no letters.
    ///
    /// Latin is the answer unless some other script clears both
    /// `minimumScriptShare` and `minimumScriptCharacters`, which is the
    /// asymmetry the bug asks for: Latin characters turn up inside text in
    /// every other script — brand names, units, model numbers — while the
    /// reverse is a quotation.
    static func dominantScript(of text: String) -> Script? {
        var counts: [Script: Int] = [:]
        for scalar in text.unicodeScalars {
            guard let script = script(of: scalar) else { continue }
            counts[script, default: 0] += 1
        }
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return nil }

        // Sorted rather than max-by-value so a tie resolves the same way
        // twice; a dictionary's iteration order does not.
        let contender = counts
            .filter { $0.key != .latin }
            .sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
            .first
        if let contender,
           contender.value >= minimumScriptCharacters,
           Double(contender.value) / Double(total) >= minimumScriptShare {
            return contender.key
        }
        // The two floors exist to stop a caption overruling a page of Latin
        // prose, so they only bite when there is Latin prose to protect.
        // Text holding no Latin at all is written in whatever else it holds,
        // however little of it there is.
        return counts[.latin] != nil ? .latin : contender?.key
    }

    // MARK: Detection

    /// The dominant language of `text`, or nil when there is not enough
    /// evidence to say.
    ///
    /// Nil is not an error: it means "write this note as it is", which is
    /// also the right answer for a screenshot of a table of numbers.
    ///
    /// `preferred` is the user's own list of languages to detect, as catalog
    /// identifiers ("ar-Arab", "zh-Hans"). Passed in rather than read from
    /// `UserDefaults` here, so this whole type stays pure and its rules stay
    /// testable with no defaults registered; the caller that has settings
    /// already — `NoteCoordinator` — is the one that supplies them.
    static func dominantLanguage(of text: String, preferring preferred: [String] = []) -> Locale.Language? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacters else { return nil }

        // Judge the filtered text where enough of it survives, the original
        // where it does not. A short UI screenshot can be nothing but
        // capitalised labels, and reading that on weak evidence beats
        // reading a two-word remnant on none.
        let filtered = signalBearingText(in: trimmed)
        let sample = filtered.count >= minimumCharacters ? filtered : trimmed

        let dominant = dominantScript(of: sample)

        // The script prior, and it wins. A label whose letters are a sixth
        // Han is not Portuguese whatever the n-grams say, and answering
        // "nothing" there would leave a Chinese jar untranslated — the one
        // case where the false negative is the expensive one.
        if let dominant, dominant != .latin, dominant != .other {
            return language(writtenIn: dominant, within: sample)
        }

        guard let identifier = decisiveLanguage(in: hypotheses(for: sample, preferring: preferred)) else {
            return nil
        }

        // The mirror of the rule above, and the reason it rejects rather
        // than overrides: Latin text is not Japanese however the n-grams
        // fell, but Latin script names no language on its own, so there is
        // nothing to override it *with*. Only applied when the census
        // actually saw Latin — a script this type does not model leaves the
        // recognizer's answer alone.
        if dominant == .latin, script(of: Locale.Language(identifier: identifier)) != .latin { return nil }
        return Locale.Language(identifier: identifier)
    }

    /// The language of the part of `text` written in `script`.
    ///
    /// The recognizer is re-run on that part alone, which is the whole point:
    /// asked about the Laoganma label it says Portuguese, asked about the
    /// twenty-eight ideographs on the Laoganma label it says Simplified
    /// Chinese at 1.00. `minimumCharacters` is not re-applied to the
    /// projection — that floor is a count of Latin letters, and
    /// twenty-eight ideographs are twenty-eight words — but
    /// `minimumScriptCharacters` has already been met.
    ///
    /// Nil when the projection is not decisive, which is the honest answer
    /// for a script whose languages the recognizer cannot separate on this
    /// sample.
    static func language(writtenIn script: Script, within text: String) -> Locale.Language? {
        let sample = projection(of: text, onto: script)
        guard !sample.isEmpty else { return nil }

        // Han does not distinguish Chinese from Japanese; kana settles it in
        // one direction and nothing settles it in the other, so kana is
        // checked first and the recognizer is left to weigh Han vocabulary
        // when there is none. (It does that well — a kana-free Japanese
        // headline still comes back as Japanese at 1.00 — but it is a
        // judgement where kana is a fact.)
        if script == .cjk, kanaShare(of: sample) >= minimumKanaShare {
            return Locale.Language(identifier: "ja")
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let identifier = decisiveLanguage(in: identifiers(of: recognizer.languageHypotheses(withMaximum: hypothesisDepth))) else {
            return nil
        }
        let language = Locale.Language(identifier: identifier)
        // Left deliberately unconstrained rather than pinned to a list of
        // the script's languages. `languageConstraints` zeroes everything
        // outside the list the same way an incomplete hint dictionary does,
        // and no hand-written list of, say, the Cyrillic languages is going
        // to have Serbian in it on the day someone screenshots Serbian. So
        // the recognizer picks freely and is only checked for having stayed
        // inside the script it was shown.
        guard self.script(of: language) == script else { return nil }
        return language
    }

    /// The top hypothesis, when it is far enough ahead of the second to be a
    /// decision rather than a coin toss.
    ///
    /// Takes plain identifiers and probabilities rather than the
    /// recognizer's own types so both thresholds can be tested directly:
    /// real text that lands in the narrow band between them is hard to come
    /// by, and a rule nobody can exercise is a rule nobody can trust.
    static func decisiveLanguage(in hypotheses: [String: Double]) -> String? {
        let ranked = hypotheses.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let top = ranked.first, top.value >= minimumConfidence else { return nil }
        let runnerUp = ranked.dropFirst().first?.value ?? 0
        guard top.value - runnerUp >= minimumMargin else { return nil }
        return top.key
    }

    /// `text` with the tokens that carry no language signal taken out.
    ///
    /// Packaging and UI screenshots are largely not prose: barcodes, net
    /// weights, percentages, standard numbers, and brand names and acronyms
    /// in capitals. None of that is evidence for a language and all of it is
    /// evidence for *some* language once an n-gram model is pointed at it —
    /// "NET WT", "23.63 OZ" and "GB/T 20293" are what carried the Laoganma
    /// label to Portuguese. Dropping them raised the Han share of that
    /// label's letters from 0.24 to 0.47 and moved the recognizer's own
    /// answer from Portuguese at 0.76 to English at 0.79.
    ///
    /// Only Latin-script tokens are ever dropped, for two reasons. The noise
    /// this exists to remove is Latin — units and part numbers are written
    /// in ASCII whatever language the label is in — and Chinese, Japanese
    /// and Thai are not written with spaces, so a whole sentence in them
    /// arrives as a single token and a rule that dropped it would delete the
    /// very text this is protecting. That is not hypothetical:
    /// `Character.isNumber` is true of 三 and 千, so the obvious "drop any
    /// token with a digit in it" erases a Chinese paragraph entirely.
    static func signalBearingText(in text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).filter { token in
            let scripts = token.unicodeScalars.compactMap(script(of:))
            // Anything with a non-Latin letter in it is text, whatever else
            // it holds.
            guard scripts.allSatisfy({ $0 == .latin }) else { return true }
            // "670", "23.63", "11%", "6923555200041" — no letters, no signal.
            guard !scripts.isEmpty else { return false }
            // "23.63oz", "GB/T", "1080p" — a measurement or a part number.
            guard !token.contains(where: { $0.isASCII && $0.isNumber }) else { return false }
            // "LAOGANMA", "PVC", "NET", "WT" — a word shouted in capitals is
            // the same word in every Latin-script language, so it belongs to
            // none of them.
            return token.contains(where: \.isLowercase) || !token.contains(where: \.isCased)
        }.joined(separator: " ")
    }

    // MARK: Detection internals

    /// What the recognizer makes of `text`, biased toward the languages the
    /// user actually meets.
    ///
    /// Two passes, because hints are a prior over a closed ballot: hinting
    /// only the user's languages would delete every other language rather
    /// than merely demote it. So the first pass says which languages are
    /// plausible at all, and the second re-weighs exactly those, lifting the
    /// user's picks and English above the rest. With no picks there is no
    /// prior to apply — an empty selection means "anything", the same as it
    /// does in `NoteTranslation.allowsLanguage` — and the first pass stands.
    private static func hypotheses(for text: String, preferring preferred: [String]) -> [String: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let unhinted = recognizer.languageHypotheses(withMaximum: hypothesisDepth)

        guard !preferred.isEmpty, !unhinted.isEmpty else { return identifiers(of: unhinted) }
        // English joins the user's picks unconditionally: it is the language
        // this whole layer translates INTO, so a clip that is already in it
        // is the outcome no part of the pipeline has to work for.
        let boosted = ([NoteTranslation.targetIdentifier] + preferred).compactMap(recognizerLanguage(for:))
        guard !boosted.isEmpty else { return identifiers(of: unhinted) }

        var hints = unhinted.mapValues { _ in neutralHintWeight }
        for language in boosted { hints[language] = preferredHintWeight }

        let hinted = NLLanguageRecognizer()
        hinted.languageHints = hints
        hinted.processString(text)
        return identifiers(of: hinted.languageHypotheses(withMaximum: hypothesisDepth))
    }

    /// The spelling `NLLanguageRecognizer` uses for a catalog identifier.
    ///
    /// The two sides are written by different libraries. Settings keys its
    /// rows on what the Translation framework offers ("ar-Arab", "de-Latn"),
    /// and the recognizer answers in bare language codes with exactly one
    /// exception — Simplified against Traditional Chinese, the only pair it
    /// spells with a script. So the script is carried through for Chinese
    /// and dropped everywhere else, where it would name a language the
    /// recognizer has never heard of.
    private static func recognizerLanguage(for identifier: String) -> NLLanguage? {
        let language = Locale.Language(identifier: identifier)
        guard let code = language.languageCode?.identifier else { return nil }
        guard code == "zh" else { return NLLanguage(rawValue: code) }
        return NLLanguage(rawValue: language.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans")
    }

    private static func identifiers(of hypotheses: [NLLanguage: Double]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: hypotheses.map { ($0.key.rawValue, $0.value) })
    }

    /// `text` reduced to the letters of one script, with the gaps it leaves
    /// closed up into single spaces so the recognizer sees word boundaries
    /// where the original had them.
    private static func projection(of text: String, onto script: Script) -> String {
        var kept = ""
        var gap = false
        for scalar in text.unicodeScalars {
            guard self.script(of: scalar) == script else {
                gap = !kept.isEmpty
                continue
            }
            if gap { kept.append(" ") }
            gap = false
            kept.unicodeScalars.append(scalar)
        }
        return kept.trimmingCharacters(in: .whitespaces)
    }

    /// What fraction of the CJK characters in `text` are kana.
    private static func kanaShare(of text: String) -> Double {
        var kana = 0
        var total = 0
        for scalar in text.unicodeScalars where script(of: scalar) == .cjk {
            total += 1
            if (0x3040...0x30FF).contains(scalar.value) || (0x31F0...0x31FF).contains(scalar.value) { kana += 1 }
        }
        guard total > 0 else { return 0 }
        return Double(kana) / Double(total)
    }

    // MARK: Naming

    /// Whether text in `language` needs translating for the note to be
    /// readable.
    ///
    /// Compares language codes only, never regions: en-GB text does not need
    /// translating into en-US, and `Locale.Language.isEquivalent(to:)` — which
    /// would say the same — is not available for every identifier shape the
    /// recognizer emits (it returns bare codes like "ar" and "zh-Hans").
    static func needsTranslation(_ language: Locale.Language?) -> Bool {
        needsTranslation(language, into: NoteTranslation.target)
    }

    /// The same question against a target the caller chooses, for the preview
    /// pane's translation into the user's own language.
    static func needsTranslation(_ language: Locale.Language?, into target: Locale.Language) -> Bool {
        guard let code = language?.languageCode?.identifier else { return false }
        return code != target.languageCode?.identifier
    }

    /// A BCP-47 identifier for storage and front matter ("ar", "zh-Hans").
    static func identifier(for language: Locale.Language) -> String {
        language.minimalIdentifier
    }

    /// The language's name in the user's own language ("Arabic"), for the
    /// heading over a translation and for Settings. Falls back to the
    /// identifier, so an unnamed language still reads as something.
    static func displayName(forIdentifier identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier)
            ?? Locale.current.localizedString(forLanguageCode: identifier)
            ?? identifier
    }
}

// MARK: - Catalog

/// One row of the language menu in Settings.
struct TranslationLanguage: Identifiable, Sendable, Equatable {
    /// A stable identifier for the row — the language code plus its script
    /// where the script matters ("ar", "zh-Hans").
    let id: String
    /// What the user reads: the language's name in their own language.
    let name: String
    /// The language object to hand back to the framework, taken from its own
    /// list rather than rebuilt from `id`, so we never ask it about an
    /// identifier it did not offer.
    let language: Locale.Language

    static func == (lhs: TranslationLanguage, rhs: TranslationLanguage) -> Bool { lhs.id == rhs.id }
}

/// Turning the framework's list of supported languages into a menu.
///
/// Pure, and separate from the provider, so the grouping and naming rules are
/// testable on a machine with no translation assets at all — the same split
/// as `LanguageDetector` against `AppleTranslator`.
enum TranslationCatalog {
    /// The menu, sorted by name in the user's locale.
    ///
    /// Three rules, each earning its place against the raw list (38 entries
    /// on macOS 26.5):
    ///
    /// 1. **English is dropped.** It is the target; "translate English into
    ///    English" is not an option, it is a no-op.
    /// 2. **Regions are collapsed, scripts are not.** Apple lists es-ES,
    ///    es-MX and es-US separately, and offering three Spanishes to someone
    ///    who wants to read a screenshot is a choice with no right answer.
    ///    Script is different: Simplified and Traditional Chinese are not the
    ///    same text, so zh-Hans and zh-Hant stay apart.
    /// 3. **Names carry the script only when it disambiguates.** Naming the
    ///    grouped identifier directly gives "Danish (Latin)" and "Thai
    ///    (Thai)"; naming the bare language code gives "Chinese" twice. So
    ///    the script is spelled out exactly where a language has more than
    ///    one of them, and left off everywhere else.
    static func menu(from languages: [Locale.Language], excluding target: Locale.Language) -> [TranslationLanguage] {
        let targetCode = target.languageCode?.identifier

        // First pass: group by language + script, keeping the framework's own
        // first entry for each, and count the scripts per language.
        var order: [String] = []
        var byKey: [String: Locale.Language] = [:]
        var scriptsByCode: [String: Set<String>] = [:]
        for language in languages {
            guard let code = language.languageCode?.identifier, code != targetCode else { continue }
            let script = language.script?.identifier
            let key = [code, script].compactMap { $0 }.joined(separator: "-")
            scriptsByCode[code, default: []].insert(script ?? "")
            guard byKey[key] == nil else { continue }
            byKey[key] = language
            order.append(key)
        }

        return order.compactMap { key -> TranslationLanguage? in
            guard let language = byKey[key], let code = language.languageCode?.identifier else { return nil }
            let needsScript = (scriptsByCode[code]?.count ?? 0) > 1
            let name = needsScript
                ? (Locale.current.localizedString(forIdentifier: key) ?? key)
                : (Locale.current.localizedString(forLanguageCode: code) ?? key)
            return TranslationLanguage(id: key, name: name, language: language)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The whole menu, with nothing dropped.
    ///
    /// The exclusion above exists because English cannot be a *source* for
    /// the note pipeline, which translates into it. A target picker has no
    /// such language: every one the framework names, English included, is
    /// something a user might want their clips rendered into.
    static func menu(from languages: [Locale.Language]) -> [TranslationLanguage] {
        // "und" is BCP-47 for an undetermined language, so it matches nothing
        // in the list and the exclusion is a no-op.
        menu(from: languages, excluding: Locale.Language(identifier: "und"))
    }

    /// Whether a picked language and a detected one are the same language.
    ///
    /// Compared on code and, where both sides name one, script — the two
    /// sides are spelled by different libraries. `NLLanguageRecognizer`
    /// returns "ar" and "zh-Hans"; the menu is keyed on what the Translation
    /// framework offers ("ar-Arab"). Script is only compared when both name
    /// one, so picking Simplified Chinese does not reject text the recognizer
    /// reported as plain "zh", while Simplified and Traditional still do not
    /// match each other.
    static func matches(selection: String, detected: String) -> Bool {
        let picked = Locale.Language(identifier: selection)
        let found = Locale.Language(identifier: detected)
        guard let pickedCode = picked.languageCode?.identifier,
              let foundCode = found.languageCode?.identifier,
              pickedCode == foundCode
        else { return false }
        guard let pickedScript = picked.script?.identifier,
              let foundScript = found.script?.identifier
        else { return true }
        return pickedScript == foundScript
    }

    /// The row a detected-language identifier belongs to, if any.
    ///
    /// Matched on language code rather than on the whole identifier: the
    /// pipeline records what `NLLanguageRecognizer` saw ("ar", "zh-Hans"),
    /// and the menu is keyed on what the Translation framework offers, which
    /// need not be spelled the same way.
    static func row(matching identifier: String, in menu: [TranslationLanguage]) -> TranslationLanguage? {
        let code = Locale.Language(identifier: identifier).languageCode?.identifier
        return menu.first { $0.id == identifier }
            ?? menu.first { $0.language.languageCode?.identifier == code }
    }
}
