import AppKit
import Foundation
import SwiftData
import Vision
import XCTest

@testable import MemoryClip

/// Benchmarks for the OCR pipeline: recognition level (`.fast` vs
/// `.accurate`) and the concurrency level the coordinator's TaskGroup should
/// use. Skipped unless MEMORYCLIP_BENCH=1, like `PerformanceBenchmarks`.
///
/// SAFETY: only in-memory containers are used here; the user's real store is
/// never opened.
final class OCRPipelineBenchmarks: XCTestCase {

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["MEMORYCLIP_BENCH"] == "1"
    }

    private func requireBench() throws {
        try XCTSkipUnless(Self.enabled, "set MEMORYCLIP_BENCH=1 to run benchmarks")
    }

    private func fmt(_ value: Double) -> String { String(format: "%.1f", value) }

    private func report(_ label: String, _ millis: Double, extra: String? = nil) {
        print("BENCH | \(label) | \(fmt(millis)) ms\(extra.map { " (\($0))" } ?? "")")
    }

    /// The same synthetic 1512x982 "screenshot" shape used by
    /// PerformanceBenchmarks, so numbers are comparable across the two files.
    private func syntheticScreenshot(width: Int = 1512, height: Int = 982) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor(calibratedWhite: 0.20, alpha: 1).setFill()
        NSRect(x: 0, y: CGFloat(height) - 40, width: CGFloat(width), height: 40).fill()

        let lines = [
            "Terminal — swift build — 120x40",
            "$ swift build -c release",
            "Compiling MemoryClip Store/ClipStore.swift",
            "Compiling MemoryClip UI/PanelView.swift",
            "warning: variable 'previewItem' was never mutated",
            "Build complete! (18.42s)",
            "$ ./Scripts/make_app.sh",
            "codesign --force --sign - dist/MemoryClip.app",
            "dist/MemoryClip.app: replacing existing signature",
            "$ open dist/MemoryClip.app",
            "the quick brown fox jumps over the lazy dog",
            "SELECT uuid, contentHash FROM ZCLIPITEM ORDER BY ZCREATEDAT DESC LIMIT 20;",
            "error: cannot find 'nukeAll' in scope",
            "Total 14 clips captured in 3.2 seconds",
            "https://github.com/yuzeguitarist/Deck",
        ]
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1),
        ]
        var y = CGFloat(height) - 100
        for line in lines {
            (line as NSString).draw(at: NSPoint(x: 60, y: y), withAttributes: attrs)
            y -= 34
        }
        y = CGFloat(height) - 100
        for line in lines.reversed() {
            (line as NSString).draw(at: NSPoint(x: 60, y: y - 560), withAttributes: attrs)
            y -= 34
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }

    /// A light-theme screenshot: black text on white, larger type — the
    /// easiest realistic input for OCR.
    private func lightScreenshot(width: Int = 1512, height: Int = 982) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28),
            .foregroundColor: NSColor.black,
        ]
        var y = CGFloat(height) - 120
        for line in [
            "Invoice 2026-08-07",
            "Acme Corporation, 100 Market Street",
            "Total due: 1,240.00 USD",
            "the quick brown fox jumps over the lazy dog",
            "https://example.com/invoice/44219",
        ] {
            (line as NSString).draw(at: NSPoint(x: 80, y: y), withAttributes: attrs)
            y -= 90
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }

    /// Recognition at an explicit level, so the two levels can be compared
    /// without changing `OCRService`.
    private func recognize(_ data: Data, level: RecognizeTextRequest.RecognitionLevel) async -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = (level == .accurate)
        guard let observations = try? await request.perform(on: data) else { return nil }
        return OCRService.joinedText(from: observations)
    }

    /// Raw observations, so a level that finds text but at a confidence below
    /// `OCRService.minimumConfidence` can be told apart from one that finds
    /// nothing at all.
    private func rawObservations(
        _ data: Data,
        level: RecognizeTextRequest.RecognitionLevel,
        languageCorrection: Bool
    ) async -> [(text: String, confidence: Float)] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = languageCorrection
        guard let observations = try? await request.perform(on: data) else { return [] }
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return (candidate.string, candidate.confidence)
        }
    }

    /// Why `.fast` was rejected: it is ~10x quicker but reads almost nothing
    /// off a real screenshot, at any confidence threshold.
    func testFastLevelRawObservations() async throws {
        try requireBench()
        // A light-theme screenshot too: dark-on-light is the friendliest case
        // for `.fast`, so it gets the benefit of the doubt.
        let light = lightScreenshot()
        for (name, level, correction) in [
            ("light/accurate", RecognizeTextRequest.RecognitionLevel.accurate, true),
            ("light/fast", .fast, false),
        ] {
            let start = DispatchTime.now().uptimeNanoseconds
            let observations = await rawObservations(light, level: level, languageCorrection: correction)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let above = observations.filter { $0.confidence >= OCRService.minimumConfidence }
            print("BENCH | ocrlevel/\(name) raw | \(observations.count) observations, "
                  + "\(above.count) above \(OCRService.minimumConfidence), \(fmt(elapsed)) ms")
            print("BENCH | ocrlevel/\(name) sample | "
                  + observations.prefix(4).map { "\"\($0.text)\"@\($0.confidence)" }.joined(separator: " "))
        }

        let shot = syntheticScreenshot()
        for (name, level, correction) in [
            ("accurate", RecognizeTextRequest.RecognitionLevel.accurate, true),
            ("fast", .fast, false),
            ("fast+correction", .fast, true),
        ] {
            let observations = await rawObservations(shot, level: level, languageCorrection: correction)
            let above = observations.filter { $0.confidence >= OCRService.minimumConfidence }
            let best = observations.map(\.confidence).max() ?? 0
            print("BENCH | ocrlevel/\(name) raw | \(observations.count) observations, "
                  + "\(above.count) above \(OCRService.minimumConfidence), max confidence \(best)")
            print("BENCH | ocrlevel/\(name) sample | "
                  + observations.prefix(4).map { "\"\($0.text)\"@\($0.confidence)" }.joined(separator: " "))
        }
    }

    // MARK: - Table detection

    /// What the table pass costs on an image that has no table in it — the
    /// case it runs on every time and must not be paid for.
    ///
    /// Measures the two halves separately: asking Vision for a box per word
    /// (`OCRService.fragments`), and the geometry search over them
    /// (`TableLayout`).
    func testTablePassOverhead() async throws {
        try requireBench()
        var request = RecognizeTextRequest()
        request.recognitionLevel = OCRService.recognitionLevel
        request.usesLanguageCorrection = true

        for (name, data) in [("terminal", syntheticScreenshot()), ("light", lightScreenshot())] {
            guard let observations = try? await request.perform(on: data) else { continue }
            let lines = OCRService.recognizedLines(from: observations)

            var fragments: [TextFragment] = []
            var boxMillis = 0.0
            var layoutMillis = 0.0
            for _ in 0..<5 {
                var start = DispatchTime.now().uptimeNanoseconds
                fragments = OCRService.fragments(in: lines)
                boxMillis += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

                start = DispatchTime.now().uptimeNanoseconds
                _ = TableLayout.textWithTables(lines: lines.map(\.text), fragments: fragments)
                layoutMillis += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
            report("table/\(name) word boxes", boxMillis / 5,
                   extra: "\(lines.count) lines, \(fragments.count) words")
            report("table/\(name) layout search", layoutMillis / 5)
        }
    }

    // MARK: - .fast vs .accurate

    func testRecognitionLevelComparison() async throws {
        try requireBench()
        let shot = syntheticScreenshot()

        // Warm the Vision models for both levels first.
        _ = await recognize(shot, level: .accurate)
        _ = await recognize(shot, level: .fast)

        var accurateText: String?
        var fastText: String?

        for level in [RecognizeTextRequest.RecognitionLevel.accurate, .fast] {
            var samples: [Double] = []
            var text: String?
            for _ in 0..<5 {
                let start = DispatchTime.now().uptimeNanoseconds
                text = await recognize(shot, level: level)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            let avg = samples.reduce(0, +) / Double(samples.count)
            report("ocrlevel/\(level == .accurate ? "accurate" : "fast") warm avg over 5", avg,
                   extra: "\(text?.count ?? 0) chars")
            if level == .accurate { accurateText = text } else { fastText = text }
        }

        // Quality proxy: how many of the known strings each level recovers.
        let needles = ["swift build", "codesign", "quick brown fox", "ZCLIPITEM", "nukeAll", "github.com"]
        for (name, text) in [("accurate", accurateText), ("fast", fastText)] {
            let hits = needles.filter { needle in
                (text ?? "").lowercased().contains(needle.lowercased())
            }
            print("BENCH | ocrlevel/\(name) recall | \(hits.count)/\(needles.count) — \(hits.joined(separator: ", "))")
        }
    }

    // MARK: - Concurrency sweep

    /// How long N images take at each TaskGroup width, to pick the
    /// coordinator's concurrency constant.
    func testConcurrencySweep() async throws {
        try requireBench()
        let shot = syntheticScreenshot()
        let count = 12
        let images: [Data] = (0..<count).map { i in
            var data = shot
            data.append(UInt8(i))
            return data
        }
        _ = await recognize(shot, level: .accurate)

        for width in [1, 2, 3, 4, 6, 8] {
            let start = DispatchTime.now().uptimeNanoseconds
            await withTaskGroup(of: Void.self) { group in
                var index = 0
                var running = 0
                while index < images.count {
                    if running == width {
                        await group.next()
                        running -= 1
                    }
                    let data = images[index]
                    index += 1
                    running += 1
                    group.addTask { _ = await OCRService.recognizeText(in: data) }
                }
                await group.waitForAll()
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            report("ocrconc/width=\(width) \(count) images", elapsed,
                   extra: "\(fmt(elapsed / Double(count))) ms/image")
        }
    }

    // MARK: - Coordinator drain

    /// End-to-end drain through the real coordinator (same shape as
    /// PerformanceBenchmarks.testOCRCoordinatorBacklog, kept here so the
    /// before/after of this change is measured on an identical workload).
    @MainActor
    func testCoordinatorDrainThroughput() async throws {
        try requireBench()
        UserDefaults.standard.set(true, forKey: OCRCoordinator.enabledKey)
        UserDefaults.standard.set(0, forKey: SettingsKeys.historyCap)
        UserDefaults.standard.set(0, forKey: SettingsKeys.retentionDays)

        let store = try ClipStore(inMemory: true)
        let shot = syntheticScreenshot(width: 800, height: 500)
        let backlog = 40
        for i in 0..<backlog {
            var data = shot
            data.append(UInt8(i))
            store.context.insert(ClipItem(
                kind: .image,
                imageData: data,
                contentHash: ContentParser.hashText("drainbench:\(i)"),
                createdAt: .now.addingTimeInterval(-Double(i))
            ))
        }
        store.save()

        _ = await OCRService.recognizeText(in: shot)

        let coordinator = OCRCoordinator(store: store)
        let start = DispatchTime.now().uptimeNanoseconds
        coordinator.processPending()
        while !store.pendingOCR(limit: 1).isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        report("ocrdrain/\(backlog) images (800x500)", elapsed,
               extra: "\(fmt(elapsed / Double(backlog))) ms/image")
        coordinator.stop()
    }
}
