import Foundation
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

        var request = RecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = true

        do {
            let observations = try await request.perform(on: imageData)
            return joinedText(from: observations)
        } catch {
            log.error("OCR failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Assemble the recognized lines into one searchable string, keeping
    /// Vision's reading order and dropping low-confidence candidates.
    static func joinedText(from observations: [RecognizedTextObservation]) -> String? {
        var lines: [String] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            guard candidate.confidence >= minimumConfidence else { continue }
            let line = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
}
