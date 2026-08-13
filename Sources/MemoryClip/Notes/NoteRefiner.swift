import Foundation

/// Note refinement: turning raw OCR into something worth keeping (Phase 4).
///
/// # What this layer is for
///
/// Vision gives us reading order and little else. Its output carries broken
/// line wrapping (a paragraph arrives as eight lines), hyphenation left over
/// from justified text, the classic confusion pairs (`l`/`1`, `rn`/`m`,
/// `O`/`0`), and every scrap of interface chrome that happened to be on
/// screen — "File Edit View Window Help", "3 unread", a dock badge. Pasted
/// into a note that is all still there.
///
/// A refiner post-processes that text with an on-device language model, the
/// same way a transcription tool cleans up an ASR transcript before showing
/// it. See `FoundationModelsRefiner` for the implementation.
///
/// # Why the seam is here and not in the provider
///
/// This file deliberately does not import FoundationModels. Everything the
/// rest of the app touches — the input, the result, the protocol, the
/// fallback, the sanity check — is plain Foundation, so:
///
/// - the whole pipeline compiles and runs on a machine where Apple
///   Intelligence is off, unsupported, or the framework is missing entirely;
/// - `RefinementGuard` is unit-testable without a model, which matters
///   because it is the part that decides whether we trust the model at all;
/// - a second provider later is a conformance, not a rewrite. The
///   `@Generable` response type stays behind the seam.
///
/// # The failure contract
///
/// Refinement is a convenience layer over data we already have: the raw OCR
/// is persisted on the clip (`ClipItem.ocrText`) before anything here runs,
/// and it stays there afterwards. Nothing downstream is waiting on a refiner
/// to make progress. That gives every failure the same answer — degrade to
/// the passthrough result and carry on:
///
/// - `refine` is not `throws`. A refiner that cannot run has a defined
///   output, not an error to propagate.
/// - No path blocks. A model that is slow costs a slow note, never a hang in
///   the capture pipeline.
/// - A model that answered the question in the screenshot, summarised the
///   text away, or hallucinated a paragraph must not be able to replace the
///   record. That is what `RefinementGuard` is for, and rejecting is always
///   cheaper than being wrong: the cost is an unpolished note.
///
/// # What this layer does not do
///
/// It does not re-run `SensitiveFilter`. Text reaches a refiner only after
/// `PasteboardWatcher` (captured text) or `ClipStore.applyOCR` (recognized
/// text) has already applied it, so a card number never gets this far while
/// the filter is on — and re-running it here would quietly override a user
/// who turned it off. Inference is on-device in every provider we ship, so
/// refinement adds no egress to guard.

// MARK: - Types

/// What the refiner is given.
///
/// Deliberately a value, not a `ClipItem`: `ClipItem` is a `@MainActor`
/// SwiftData model and is not Sendable, and refinement runs off the main
/// actor. The caller lifts the fields it needs, refines, and writes the
/// result back by uuid — the same shape `OCRCoordinator` uses to get image
/// data across the actor boundary.
struct RefinementInput: Sendable {
    /// The OCR (or captured) text, exactly as stored.
    var rawText: String
    /// The app the clip came from, when it is known. Screenshot clips
    /// usually have no source app, so this is optional rather than "".
    var sourceAppName: String?
    var capturedAt: Date
    /// Whether this came from a screenshot rather than the pasteboard.
    /// Screenshots are the noisy case — they are the ones carrying window
    /// chrome — so a provider can lean on this when prompting.
    var isScreenshot: Bool

    init(rawText: String, sourceAppName: String? = nil, capturedAt: Date = Date(), isScreenshot: Bool = false) {
        self.rawText = rawText
        self.sourceAppName = sourceAppName
        self.capturedAt = capturedAt
        self.isScreenshot = isScreenshot
    }
}

/// What it produces.
struct RefinedNote: Sendable, Equatable {
    var title: String
    /// One or two sentences. Empty from the fallback path — an empty summary
    /// renders as no summary, whereas a placeholder sentence would have to be
    /// special-cased by every consumer.
    var summary: String
    var tags: [String]
    /// The body to write. Always non-empty when the input was non-empty.
    var cleanedText: String
    /// False when this came from the fallback path — no model ran, or the
    /// model's answer was rejected. Consumers use it to decide whether to
    /// show "refined" affordances, never to decide whether the note is
    /// usable: a `wasRefined == false` note is complete, just unpolished.
    var wasRefined: Bool
}

/// Anything that can turn raw text into a note.
protocol NoteRefiner: Sendable {
    /// Whether a real refinement would run right now. False means `refine`
    /// still works and still returns a usable note — it just returns the
    /// passthrough one. Read at call time, not cached: Apple Intelligence can
    /// be switched on, and assets can finish downloading, while the app runs.
    var isAvailable: Bool { get }

    /// Never throws: a refiner that cannot run returns the passthrough result.
    func refine(_ input: RefinementInput) async -> RefinedNote
}

// MARK: - Passthrough

/// The no-model refiner, and the floor every other refiner falls back to.
///
/// This is what ships on a Mac where Apple Intelligence is off or the
/// hardware is not eligible, and it is also what `FoundationModelsRefiner`
/// returns on every failure path. The feature still works — screenshots
/// still become notes with a sensible filename-ish title — it just does not
/// get the polish.
struct PassthroughRefiner: NoteRefiner {
    init() {}

    /// Always true. Not "is a model available" but "can this produce a
    /// note", and it always can.
    var isAvailable: Bool { true }

    func refine(_ input: RefinementInput) async -> RefinedNote {
        RefinedNote(
            title: Self.heuristicTitle(for: input),
            summary: "",
            tags: [],
            cleanedText: input.rawText,
            wasRefined: false
        )
    }

    /// First usable line, else a timestamp.
    ///
    /// The first line of a screenshot is the window title, the document
    /// heading, the subject line — right often enough to beat a timestamp,
    /// and when it is wrong the user is looking at their own text rather than
    /// at something a model made up.
    ///
    /// It keeps scanning past the first non-empty line, skipping any line
    /// with no letter and no digit anywhere in it. Screenshots open with a
    /// rule far more often than they open with a heading — `────────`,
    /// `════`, `***`, `• • •` — and this title is not only the note's
    /// `title:` front matter but its filename, so taking one would name the
    /// file `2026-08-13 1422 ────────.md`. Falling straight to the timestamp
    /// instead would be no better: it would date-stamp every note that had a
    /// perfectly good heading one line below the rule.
    ///
    /// The test is a character class rather than a list of rule characters
    /// because a list goes stale against the next divider someone screenshots
    /// — the trailing-punctuation set below covers `-`, `–` and `—` but not
    /// U+2500 `─`, U+2550 `═` or U+2501 `━`, which is exactly how `────────`
    /// became a title. One letter or digit anywhere on the line is enough to
    /// qualify, so "Fix #4213", "2.1 release notes" and "→ next steps" all
    /// still title their notes.
    static func heuristicTitle(for input: RefinementInput) -> String {
        for line in input.rawText.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            let trimmed = trimmingTrailingPunctuation(String(line))
            let clamped = RefinementGuard.clampedTitle(trimmed)
            if !clamped.isEmpty { return clamped }
        }
        return timestampTitle(for: input)
    }

    /// "Screenshot 13 Aug 2026 at 14:22" — the last-resort title.
    ///
    /// The noun comes from what we know about the clip: a screenshot says so,
    /// a pasteboard clip borrows the source app ("Safari 13 Aug 2026 at
    /// 14:22"), and an unattributed one falls back to "Clip". Dates are
    /// formatted in the user's locale, so this reads as "Aug 13, 2026 at
    /// 2:22 PM" in en_US — a title is user-facing text, not an identifier.
    static func timestampTitle(for input: RefinementInput) -> String {
        let noun: String
        if input.isScreenshot {
            noun = "Screenshot"
        } else if let app = input.sourceAppName?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
            noun = app
        } else {
            noun = "Clip"
        }
        return "\(noun) \(timestampFormatter.string(from: input.capturedAt))"
    }

    /// Built once: `DateFormatter` construction dominates the cost of
    /// formatting one date, and this can run once per captured screenshot.
    /// `DateFormatter` is thread-safe for formatting on macOS 10.9+, and this
    /// instance is never mutated after construction.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Trim whitespace both ends, plus sentence punctuation at the tail.
    ///
    /// The trailing set is deliberately narrow — sentence terminators,
    /// separators and dashes only. Trimming all of `.punctuationCharacters`
    /// would eat the closing half of "Build (v2)" and "release notes]",
    /// which is worse than leaving a stray colon on a heading.
    static func trimmingTrailingPunctuation(_ line: String) -> String {
        var result = Substring(line)
        while let last = result.last, last.isWhitespace || trailingPunctuation.contains(last) {
            result = result.dropLast()
        }
        return String(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let trailingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "-", "–", "—", "…", "|", "*", "_", "#", "•", "·",
    ]
}

// MARK: - Guard

/// The anti-hallucination check: does this rewrite still say what the
/// original said, and nothing much else?
///
/// Pure and free of any model type on purpose. This is the one piece that
/// decides whether a model's output is allowed to become the user's note, so
/// it has to be testable without a model, on any machine, deterministically.
///
/// The method is a bag-of-tokens comparison, not a diff. It is checking for
/// the two ways a language model ruins a cleanup task — it summarised
/// (most of the original is gone) or it composed (most of what it wrote was
/// never there) — and both show up plainly in token overlap. It is not
/// checking for correctness: a model that swaps two numbers passes this and
/// nothing here will catch it. That is accepted, because the raw OCR is
/// preserved on the clip and remains the record.
///
/// It also, by design, passes a model that did nothing at all — echoing the
/// input back scores perfectly. This bounds damage; it does not measure
/// improvement, and a wasted refinement is not a failure worth detecting.
enum RefinementGuard {
    // MARK: Tokenizing

    /// Lowercased alphanumeric tokens, one-character tokens dropped.
    ///
    /// Dropping length-1 tokens takes out exactly the noise this comparison
    /// is worst at: list bullets, stray OCR marks, and the single letters
    /// that fall out of a mangled word. They are also the tokens legitimate
    /// OCR repair most often creates or destroys ("l" + "ike" → "like"), so
    /// counting them would push both ratios around for no signal.
    static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count > 1 }
            .map(String.init)
    }

    // MARK: Ratios

    /// Fraction of the RAW text's distinct tokens that survive into `cleaned`.
    ///
    /// 1.0 for empty raw: there was nothing to lose, so nothing was lost —
    /// and it avoids the divide-by-zero. Distinct rather than total counts so
    /// that a word repeated forty times in a table cannot outvote the rest of
    /// the page.
    static func retentionRatio(cleaned: String, raw: String) -> Double {
        let rawTokens = Set(tokens(raw))
        guard !rawTokens.isEmpty else { return 1 }
        let cleanedTokens = Set(tokens(cleaned))
        return Double(rawTokens.intersection(cleanedTokens).count) / Double(rawTokens.count)
    }

    /// Fraction of the CLEANED text's distinct tokens that were not in `raw`.
    ///
    /// 0.0 for empty cleaned: nothing was written, so nothing was invented.
    /// (Empty output is caught by `isPlausible`, not by this ratio — this
    /// function answers one question and answers it honestly.)
    static func inventionRatio(cleaned: String, raw: String) -> Double {
        let cleanedTokens = Set(tokens(cleaned))
        guard !cleanedTokens.isEmpty else { return 0 }
        let rawTokens = Set(tokens(raw))
        return Double(cleanedTokens.subtracting(rawTokens).count) / Double(cleanedTokens.count)
    }

    // MARK: Thresholds

    /// At least 40% of the original's distinct tokens must survive.
    ///
    /// The instinct is to put this high — "a cleanup keeps nearly every
    /// word" — and that is wrong, because cleaning is *supposed* to delete.
    /// Menu bars, tab strips, sidebar items, "3 unread", clock and battery
    /// readouts and cookie banners are all vocabulary that only appears in
    /// the chrome, so removing them alone takes a large bite out of the
    /// distinct-token count.
    ///
    /// Measured over hand-built raw/cleaned pairs — a chrome-heavy note
    /// window, a news article behind a full browser frame, and a Terminal
    /// screenshot with OCR damage — a CORRECT cleanup retained 0.59, 0.62 and
    /// 0.75. The failures it has to catch, run against the same inputs,
    /// retained 0.04 (summarised), 0.11 (answered the question in the text),
    /// 0.14 (summarised the article) and 0.15 (paraphrased). The gap between
    /// 0.15 and 0.59 is where the threshold belongs, and 0.6 — the first
    /// number that feels right — sits on the wrong side of it and rejects a
    /// correct rewrite of the chrome-heavy case. 0.4 is roughly midway, with
    /// ~1.5x margin on both sides.
    static let minimumRetention = 0.4

    /// At most 20% of what the model wrote may be new.
    ///
    /// This cannot be near zero, because correct output legitimately invents
    /// tokens. Dehyphenation is the clearest case: "inter-" / "esting" across
    /// a line break are two raw tokens and become one token that appears
    /// nowhere in the raw text. Rejoining a wrapped word does the same, and
    /// so does every OCR repair — "rnight" → "might" is by construction a
    /// token the raw text did not contain.
    ///
    /// Over the same pairs, correct cleanups invented 0.02, 0.06 and 0.08
    /// (the last being a Terminal screenshot with two character fixes in 16
    /// distinct tokens); the failures invented 0.29, 0.50, 0.75 and 0.79,
    /// because a model choosing its own words is choosing words that were
    /// not there. 0.2 clears the honest cases by 2.5x and still catches the
    /// closest failure.
    ///
    /// This is the second net, not the first — retention separates far more
    /// cleanly — which is why it is set nearer the honest side of the gap.
    static let maximumInvention = 0.2

    /// Below this many distinct raw tokens, ratios are too coarse to use.
    ///
    /// At 6 distinct tokens each one is worth 17 percentage points: two
    /// honest OCR fixes look identical to a third of the text being made up.
    /// Short inputs are also the *noisiest* — a two-line screenshot is mostly
    /// chrome — so the ratios would misfire in both directions. Under this
    /// count the check switches to absolute allowances instead.
    static let shortTextTokenCount = 12

    /// Distinct raw tokens a short input may lose, in absolute terms.
    static let shortTextDropAllowance = 2

    /// New distinct tokens a short input's rewrite may contain.
    /// One more than the drop allowance because a single OCR repair both
    /// drops a token and adds one, and short inputs are where repairs land.
    static let shortTextInventionAllowance = 3

    /// Whether `cleaned` is a believable rewrite of `raw`.
    ///
    /// Rejecting is cheap — the caller falls back to passthrough and the user
    /// gets their unpolished text — so this errs toward rejection wherever
    /// the signal is ambiguous.
    static func isPlausible(cleaned: String, raw: String) -> Bool {
        let rawIsEmpty = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let cleanedIsEmpty = cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Erasing the note is never a valid cleanup, and the token counts
        // below cannot see it: a two-token input emptied entirely is "2
        // dropped", inside the short-input allowance.
        if !rawIsEmpty, cleanedIsEmpty { return false }

        let rawTokens = Set(tokens(raw))
        let cleanedTokens = Set(tokens(cleaned))
        // The mirror image, and just as invisible to the counts below: raw
        // text that tokenizes to nothing at all — "• • •", a screenshot of
        // icons, a row of single digits — has no tokens to drop, so it takes
        // the short-input branch at 0 dropped and accepts up to
        // `shortTextInventionAllowance` distinct tokens of pure invention. A
        // model handed a picture and asked to clean up its text will describe
        // the picture ("Login dialog"), and that would read here as a
        // faithful rewrite. Content that appears from nothing is exactly as
        // wrong as content that vanishes into nothing. Both sides tokenizing
        // to nothing still passes: that is a model echoing a row of bullets
        // back unchanged, which is a no-op, not a fabrication.
        if rawTokens.isEmpty, !cleanedTokens.isEmpty { return false }

        let dropped = rawTokens.subtracting(cleanedTokens).count
        let invented = cleanedTokens.subtracting(rawTokens).count

        if rawTokens.count < shortTextTokenCount {
            return dropped <= shortTextDropAllowance && invented <= shortTextInventionAllowance
        }

        let retention = Double(rawTokens.count - dropped) / Double(rawTokens.count)
        let invention = cleanedTokens.isEmpty ? 0 : Double(invented) / Double(cleanedTokens.count)
        return retention >= minimumRetention && invention <= maximumInvention
    }

    // MARK: Normalizing model output

    /// Words a title may have before it is cut.
    static let titleWordLimit = 8

    /// Characters a title may have before it is cut. Roughly what fits on one
    /// line of the panel's card, and short enough to survive being used as a
    /// Markdown filename.
    static let titleCharacterLimit = 60

    /// Most tags a note gets. Past five they stop being navigation and start
    /// being noise in a vault's tag pane.
    static let tagLimit = 5

    /// Clamp a candidate title to `maxWords` words and `maxCharacters`
    /// characters, cutting on a word boundary and marking the cut.
    ///
    /// Returns "" for input with no words, which is the signal callers use to
    /// mean "no usable title here, try the next line". The ellipsis is added
    /// outside the character budget — one character over is not worth a
    /// second pass of arithmetic.
    static func clampedTitle(
        _ raw: String,
        maxWords: Int = titleWordLimit,
        maxCharacters: Int = titleCharacterLimit
    ) -> String {
        let words = raw.split(whereSeparator: { $0.isWhitespace })
        guard let first = words.first else { return "" }

        var kept: [Substring] = []
        var length = 0
        for word in words.prefix(maxWords) {
            let cost = kept.isEmpty ? word.count : word.count + 1
            if length + cost > maxCharacters { break }
            kept.append(word)
            length += cost
        }
        // One word longer than the whole budget (a URL, a base64 blob):
        // hard-cut it rather than returning "" and pretending there was no
        // title at all.
        guard !kept.isEmpty else { return String(first.prefix(maxCharacters)) + "…" }
        return kept.joined(separator: " ") + (kept.count < words.count ? "…" : "")
    }

    /// Normalize a model's tag list into something a vault can use.
    ///
    /// Lowercased, punctuation stripped, spaces and slashes folded to
    /// hyphens, deduped in first-seen order, empties dropped, capped at
    /// `limit`. The hyphen folding is not cosmetic: the default destination
    /// is a Markdown vault, where `#project notes` is the tag `#project`
    /// followed by a stray word, so a tag with a space in it silently means
    /// something else. Order is preserved because models put their most
    /// confident tag first and the cap cuts from the tail.
    static func sanitizedTags(_ tags: [String], limit: Int = tagLimit) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let normalized = normalizedTag(tag)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            result.append(normalized)
            if result.count == limit { break }
        }
        return result
    }

    /// One tag, normalized. A leading '#' disappears here along with every
    /// other punctuation mark — models emit "#swift", "Swift.", and "swift"
    /// for the same concept, and all three have to dedupe against each other.
    static func normalizedTag(_ tag: String) -> String {
        var normalized = ""
        for character in tag.lowercased() {
            if character.isLetter || character.isNumber {
                normalized.append(character)
            } else if character == "_" || character == "-" || character.isWhitespace || character == "/" {
                // Separators all become '-' so "note taking", "note/taking"
                // and "note-taking" collapse to one tag.
                normalized.append("-")
            }
            // Anything else — '#', quotes, brackets, emoji — is dropped.
        }
        while normalized.contains("--") {
            normalized = normalized.replacingOccurrences(of: "--", with: "-")
        }
        while normalized.hasPrefix("-") { normalized.removeFirst() }
        while normalized.hasSuffix("-") { normalized.removeLast() }
        return normalized
    }
}
