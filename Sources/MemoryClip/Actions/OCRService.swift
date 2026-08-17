import CoreGraphics
import Foundation
import ImageIO
import Vision

/// On-device text extraction from image clips (Phase 3).
///
/// Uses the Vision framework's Swift API — everything runs locally, no
/// network and no extra permissions. Recognition happens off the main
/// actor; the caller writes the result back onto the model on @MainActor.
enum OCRService {
    /// Candidates below this confidence are dropped (Vision reports 0…1).
    static let minimumConfidence: Float = 0.3

    /// Recognition level, and why it is `.accurate` despite the cost.
    ///
    /// `.accurate` is ~670 ms per 1512x982 screenshot; `.fast` is ~50-65 ms,
    /// roughly 10x quicker. Measured on an M1 Pro (macOS 26, release) against
    /// two realistic inputs — a dark terminal screenshot and a light-theme
    /// document — `.fast` returned ZERO observations on both, with and
    /// without language correction, while `.accurate` returned 25 and 5
    /// respectively, all at confidence 1.0. A 10x saving that indexes nothing
    /// is not a trade-off, so the search index is built at `.accurate`; the
    /// cost is absorbed by running several images concurrently in
    /// `OCRCoordinator` instead. See `OCRPipelineBenchmarks`.
    static let recognitionLevel: RecognizeTextRequest.RecognitionLevel = .accurate

    /// Let Vision work out which language it is looking at, instead of
    /// assuming English.
    ///
    /// `RecognizeTextRequest.recognitionLanguages` defaults to `["en-Latn-US"]`
    /// alone, and Vision does not fall back: handed a screenshot of Arabic it
    /// returns ZERO observations, so the clip is indexed as having no text and
    /// any note written from it is built out of nothing. Measured on an M1 Pro
    /// (macOS 26.5) against rendered samples — Arabic went from nothing at all
    /// to every line recognised, and a mixed English/Arabic screenshot went
    /// from the Arabic half being dropped to both halves being read. English
    /// output was character-for-character identical with the flag on and off,
    /// including the `l`/`1` confusion the test sample was built around, so
    /// this costs the common case nothing.
    ///
    /// Vision supports 30 languages here (`supportedRecognitionLanguages`),
    /// among them Arabic, Chinese, Japanese, Korean, Russian, Thai and
    /// Ukrainian — none of which the previous default could see.
    ///
    /// `usesLanguageCorrection` stays on alongside it: correction is applied
    /// in whichever language was detected, which is what fixes OCR slips in
    /// Arabic as well as in English.
    static let detectsLanguageAutomatically = true

    /// Whether recognized text is checked for table layout before it is
    /// stored.
    ///
    /// On, and with no setting behind it, because the two outcomes are not
    /// symmetric: when no table is found the stored text is byte-identical to
    /// what this file produced before `TableLayout` existed, so the feature
    /// has no cost to opt out of. See `TableLayout` for why its thresholds
    /// are set to reject.
    ///
    /// The pass is also nearly free: measured on an M1 Pro against the
    /// benchmarks' 1512x982 terminal screenshot (25 lines, 126 words), asking
    /// Vision for a box per word costs 2.3 ms and the geometry search 0.6 ms,
    /// against ~670 ms of recognition — 0.4% of an image. See
    /// `OCRPipelineBenchmarks.testTablePassOverhead`.
    static let detectsTables = true

    /// Recognize text in encoded image data (PNG/TIFF/JPEG…).
    ///
    /// Returns nil when the data isn't a decodable image, when Vision
    /// fails, or when nothing legible was found — callers use nil to mean
    /// "no text", not "try again".
    ///
    /// Safe to call from several tasks at once: each call builds its own
    /// request, and Vision serializes what it must internally.
    static func recognizeText(in imageData: Data) async -> String? {
        guard !imageData.isEmpty else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard hasPixels(CGImageSourceCreateWithData(imageData as CFData, options as CFDictionary))
        else { return nil }
        return await recognize { try await $0.perform(on: imageData) }
    }

    /// Recognize text in an image file, without reading it into memory first.
    ///
    /// Vision opens the URL itself and streams what it needs, so a screenshot
    /// clip — which holds a path rather than bytes — is recognized at no
    /// resident-memory cost. Returns nil for the same three reasons as the
    /// `Data` entry point, plus a file that has been moved or deleted since
    /// it was captured.
    static func recognizeText(inFileAt url: URL) async -> String? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard hasPixels(CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary))
        else { return nil }
        return await recognize { try await $0.perform(on: url) }
    }

    /// Recognize text from whichever shape the clip's pixels take.
    static func recognizeText(in payload: ImagePayload) async -> String? {
        switch payload {
        case .data(let data): return await recognizeText(in: data)
        case .fileURL(let url): return await recognizeText(inFileAt: url)
        }
    }

    /// Whether there is an image here with actual pixels in it — asked
    /// before the request rather than left for Vision to answer.
    ///
    /// Vision refuses a zero-dimensioned image, and it refuses it loudly: the
    /// request fails with `invalidImage("Zero-dimensioned image (0.0 x 0.0")`
    /// and Vision logs that failure itself, on its own thread, where the
    /// `catch` in `recognize` cannot keep it out of the console. Bytes that
    /// never decode are not an anomaly worth a log line — a truncated
    /// screenshot, a row written by an older build, anything the pasteboard
    /// claimed was an image and was not — and the defined answer for all of
    /// them is already nil, so the request is not worth making.
    ///
    /// ImageIO answers from the header (`kCGImageSourceShouldCache: false`
    /// decodes no bitmap), which is a few hundred bytes against the ~670 ms
    /// of recognition it guards.
    private static func hasPixels(_ source: CGImageSource?) -> Bool {
        guard let source, CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        return width > 0 && height > 0
    }

    /// Shared body of the entry points above: build a request, run the
    /// caller's `perform` overload, and fold failure into nil.
    private static func recognize(
        _ perform: (RecognizeTextRequest) async throws -> [RecognizedTextObservation]
    ) async -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = detectsLanguageAutomatically

        do {
            return text(from: try await perform(request))
        } catch {
            log.error("OCR failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Assemble the recognized lines into one searchable string, keeping
    /// Vision's reading order and dropping low-confidence candidates.
    static func joinedText(from observations: [RecognizedTextObservation]) -> String? {
        let lines = recognizedLines(from: observations)
        guard !lines.isEmpty else { return nil }
        return lines.map(\.text).joined(separator: "\n")
    }

    /// The searchable text for an image: `joinedText`, except where the words
    /// on the page turn out to be laid out as a table.
    ///
    /// The flat text is computed first and returned unless a table is
    /// actually found, so a screenshot with no table in it produces exactly
    /// the string it produced before tables existed — the table pass cannot
    /// reorder or reword text it does not claim.
    static func text(from observations: [RecognizedTextObservation]) -> String? {
        let lines = recognizedLines(from: observations)
        guard !lines.isEmpty else { return nil }
        let flat = lines.map(\.text).joined(separator: "\n")
        guard detectsTables else { return flat }
        return TableLayout.textWithTables(
            lines: lines.map(\.text),
            fragments: fragments(in: lines)
        ) ?? flat
    }

    /// One accepted line of recognition: its text, and the candidate it came
    /// from so word boxes can be asked for later.
    struct RecognizedLine {
        var text: String
        var candidate: RecognizedText
        var boundingBox: NormalizedRect
    }

    /// The lines worth keeping, in Vision's reading order.
    static func recognizedLines(from observations: [RecognizedTextObservation]) -> [RecognizedLine] {
        var lines: [RecognizedLine] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            guard candidate.confidence >= minimumConfidence else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            lines.append(
                RecognizedLine(text: text, candidate: candidate, boundingBox: observation.boundingBox)
            )
        }
        return lines
    }

    /// The words of `lines`, each with the box it occupied.
    ///
    /// Word boxes rather than line boxes, because Vision's idea of a "line"
    /// is not stable across the very thing being detected: handed a table it
    /// sometimes returns one observation per cell and sometimes one for the
    /// whole row, depending on how wide the column gaps are. Asking the
    /// candidate where each word sits removes that variable — a row that came
    /// back as one string is still a row of separately-placed words.
    ///
    /// When a word's box cannot be resolved the whole line falls back to its
    /// own bounding box as a single fragment: a line at the wrong granularity
    /// costs at most a missed table, whereas a guessed box would put a word
    /// in the wrong column.
    static func fragments(in lines: [RecognizedLine]) -> [TextFragment] {
        var fragments: [TextFragment] = []
        for (index, line) in lines.enumerated() {
            let string = line.candidate.string
            let ranges = wordRanges(in: string)
            var words: [TextFragment] = []
            var resolvedAll = !ranges.isEmpty
            for range in ranges {
                guard let box = line.candidate.boundingBox(for: range)?.boundingBox else {
                    resolvedAll = false
                    break
                }
                let text = String(string[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                words.append(TextFragment(text: text, rect: readingOrderRect(box), lineIndex: index))
            }
            if resolvedAll, !words.isEmpty {
                fragments.append(contentsOf: words)
            } else {
                fragments.append(
                    TextFragment(
                        text: line.text,
                        rect: readingOrderRect(line.boundingBox),
                        lineIndex: index
                    )
                )
            }
        }
        return fragments
    }

    /// Vision's normalized rect flipped to a top-left origin.
    ///
    /// Vision measures y from the BOTTOM of the image; every reader of these
    /// rects thinks in reading order, so the flip happens once, here, rather
    /// than being remembered correctly at each use.
    static func readingOrderRect(_ box: NormalizedRect) -> CGRect {
        let rect = box.cgRect
        return CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The ranges of whitespace-separated runs in `string`.
    static func wordRanges(in string: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = string.startIndex
        while index < string.endIndex {
            if string[index].isWhitespace {
                if let begin = start {
                    ranges.append(begin..<index)
                    start = nil
                }
            } else if start == nil {
                start = index
            }
            index = string.index(after: index)
        }
        if let begin = start { ranges.append(begin..<string.endIndex) }
        return ranges
    }
}
