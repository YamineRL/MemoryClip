import AppKit
import Foundation
import SwiftData
import XCTest

@testable import MemoryClip

/// Performance benchmarks. Skipped unless MEMORYCLIP_BENCH=1 is set in the
/// environment, so the normal `swift test` run stays fast.
///
/// SAFETY: every measurement here runs against either an in-memory
/// ModelContainer or a ModelContainer explicitly pointed at a throwaway
/// directory under NSTemporaryDirectory(). Nothing here ever constructs
/// `ClipStore(inMemory: false)`, which would open the user's real
/// ~/Library/Application Support/default.store.
@MainActor
final class PerformanceBenchmarks: XCTestCase {

    // MARK: - Harness

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["MEMORYCLIP_BENCH"] == "1"
    }

    private func requireBench() throws {
        try XCTSkipUnless(Self.enabled, "set MEMORYCLIP_BENCH=1 to run benchmarks")
    }

    /// Milliseconds for one execution of `body`.
    @discardableResult
    private func ms(_ label: String, _ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        report(label, elapsed)
        return elapsed
    }

    /// Milliseconds per iteration, averaged over `count` executions.
    @discardableResult
    private func msEach(_ label: String, count: Int, _ body: (Int) throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<count { try body(i) }
        let total = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let each = total / Double(count)
        report(label, each, extra: "total \(fmt(total)) ms over \(count) iters")
        return each
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private func report(_ label: String, _ millis: Double, extra: String? = nil) {
        let suffix = extra.map { " (\($0))" } ?? ""
        print("BENCH | \(label) | \(fmt(millis)) ms\(suffix)")
    }

    private func note(_ label: String, _ value: String) {
        print("BENCH | \(label) | \(value)")
    }

    // MARK: - Fixtures

    private func tempDirectory(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoryclip-bench-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An on-disk container in a throwaway directory. NEVER the default location.
    private func diskContainer(_ name: String) throws -> (ModelContainer, URL) {
        let dir = try tempDirectory(name)
        let file = dir.appendingPathComponent("bench.store")
        let config = ModelConfiguration(url: file)
        let container = try ModelContainer(for: Schema([ClipItem.self]), configurations: [config])
        return (container, dir)
    }

    private func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([ClipItem.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return 0
        }
        for case let f as URL in e {
            let values = try? f.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    private func mb(_ bytes: Int64) -> String {
        String(format: "%.2f MB", Double(bytes) / 1_048_576)
    }

    /// Realistic-ish clip text: varied length, some long.
    private func clipText(_ i: Int) -> String {
        switch i % 5 {
        case 0: return "https://example.com/some/path/\(i)?utm_source=bench&q=alpha"
        case 1: return "func handleRequest\(i)(_ req: Request) async throws -> Response { return .ok }"
        case 2: return String(repeating: "lorem ipsum dolor sit amet \(i) ", count: 12)
        case 3: return "user\(i)@example.com"
        default: return "snippet \(i) zebra quokka"
        }
    }

    private let appNames = ["Safari", "Xcode", "Terminal", "Slack", "Notes", "Mail", "Finder"]

    /// Bulk-populate a context with N text clips, spread over the past 60 days.
    private func populate(_ context: ModelContext, count: Int, withOCR: Bool = false) {
        let now = Date.now
        for i in 0..<count {
            let item = ClipItem(
                kind: .text,
                text: clipText(i),
                contentHash: ContentParser.hashText("text:\(i)"),
                sourceBundleID: "com.example.app\(i % 7)",
                sourceAppName: appNames[i % appNames.count],
                createdAt: now.addingTimeInterval(-Double(i) * 100),
                ocrText: withOCR ? "screenshot text \(i) marmalade" : nil,
                ocrAttempted: withOCR
            )
            context.insert(item)
            if i % 2000 == 1999 { try? context.save() }
        }
        try? context.save()
    }

    /// A synthetic "screenshot": window chrome, a code-ish body of text.
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
        // A second column so the page is denser than a toy image.
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

    /// Resident + footprint memory of this process, in bytes.
    private func memoryFootprint() -> (resident: Int64, footprint: Int64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (Int64(info.resident_size), Int64(info.phys_footprint))
    }

    // MARK: - 1. Store at scale (in-memory, real ClipStore API)

    func testStoreInMemoryAtScale() throws {
        try requireBench()
        let previousCap = UserDefaults.standard.integer(forKey: SettingsKeys.historyCap)
        let previousRetention = UserDefaults.standard.integer(forKey: SettingsKeys.retentionDays)
        defer {
            UserDefaults.standard.set(previousCap, forKey: SettingsKeys.historyCap)
            UserDefaults.standard.set(previousRetention, forKey: SettingsKeys.retentionDays)
        }

        for size in [1_000, 10_000, 50_000] {
            // cap = 0 => unlimited, so enforceCap() short-circuits and we
            // measure raw insert cost.
            UserDefaults.standard.set(0, forKey: SettingsKeys.historyCap)
            UserDefaults.standard.set(0, forKey: SettingsKeys.retentionDays)

            let store = try ClipStore(inMemory: true)
            // Bulk-populate with batched saves: this is setup, not the
            // measured path. Driving ClipStore.insert() 50k times is
            // quadratic (see testInsertCostVsHistoryCap) and takes ~30 min.
            populate(store.context, count: size)

            // MARGINAL cost: what one more insert costs at this table size.
            let each = msEach("mem/insert marginal (cap=0) n=\(size)", count: 300) { i in
                store.insert(
                    CapturedClip(
                        kind: .text,
                        text: clipText(i),
                        richTextData: nil,
                        imageData: nil,
                        fileURLStrings: [],
                        colorHex: nil,
                        hash: ContentParser.hashText("marginal:\(i)")
                    ),
                    sourceBundleID: "com.example.bench",
                    sourceAppName: "Bench"
                )
            }
            note("mem/insert throughput n=\(size)", "\(Int(1000 / each)) clips/s")

            // The dedup path (re-copying something already in history).
            msEach("mem/insert DUPLICATE n=\(size)", count: 200) { i in
                store.insert(
                    CapturedClip(
                        kind: .text,
                        text: clipText(i),
                        richTextData: nil,
                        imageData: nil,
                        fileURLStrings: [],
                        colorHex: nil,
                        hash: ContentParser.hashText("text:\(i)")
                    ),
                    sourceBundleID: "com.example.bench",
                    sourceAppName: "Bench"
                )
            }
            msEach("mem/pendingOCR(20) n=\(size)", count: 50) { _ in
                _ = store.pendingOCR(limit: 20)
            }
            UserDefaults.standard.set(30, forKey: SettingsKeys.retentionDays)
            ms("mem/enforceRetention(30d) n=\(size)") { store.enforceRetention() }
            UserDefaults.standard.set(0, forKey: SettingsKeys.retentionDays)
            ms("mem/nukeAll n=\(size)") { store.nukeAll() }
            populate(store.context, count: size)

            // fetchByHash — the dedup lookup, on the #Index'd contentHash.
            let hitCount = 200
            msEach("mem/fetchByHash(hit) n=\(size)", count: hitCount) { i in
                _ = store.fetchByHash(ContentParser.hashText("text:\(i * (size / hitCount))"))
            }
            msEach("mem/fetchByHash(miss) n=\(size)", count: hitCount) { i in
                _ = store.fetchByHash(ContentParser.hashText("nope:\(i)"))
            }

            msEach("mem/recent(20) n=\(size)", count: 100) { _ in
                _ = store.recent(limit: 20)
            }
            msEach("mem/recent(200) n=\(size)", count: 100) { _ in
                _ = store.recent(limit: 200)
            }

            // items(withUUIDs:) with a 10-element set.
            let uuids = store.recent(limit: 10).map(\.uuid)
            msEach("mem/items(withUUIDs:10) n=\(size)", count: 50) { _ in
                _ = store.items(withUUIDs: uuids)
            }

            // enforceCap with cap=200 against the full table.
            UserDefaults.standard.set(200, forKey: SettingsKeys.historyCap)
            ms("mem/enforceCap(200) n=\(size)") {
                store.enforceCap()
            }
            note("mem/after enforceCap n=\(size)", "\(store.recent(limit: 100_000).count) remain")
        }
    }

    /// The headline store finding: ClipStore.insert() calls enforceCap(),
    /// which fetches EVERY unpinned row sorted, on every single capture.
    /// Cost therefore scales with the configured historyCap, on @MainActor,
    /// on every ⌘C the user makes.
    func testInsertCostVsHistoryCap() throws {
        try requireBench()
        let previousCap = UserDefaults.standard.integer(forKey: SettingsKeys.historyCap)
        defer { UserDefaults.standard.set(previousCap, forKey: SettingsKeys.historyCap) }

        for cap in [50, 200, 500, 1_000, 2_000, 5_000] {
            UserDefaults.standard.set(0, forKey: SettingsKeys.historyCap)
            let store = try ClipStore(inMemory: true)
            for i in 0..<cap {
                store.context.insert(ClipItem(
                    kind: .text,
                    text: clipText(i),
                    contentHash: ContentParser.hashText("prime:\(cap):\(i)"),
                    createdAt: .now.addingTimeInterval(-Double(cap - i))
                ))
            }
            store.save()

            UserDefaults.standard.set(cap, forKey: SettingsKeys.historyCap)
            let iterations = cap > 1_000 ? 30 : 100
            msEach("insert() one clip, historyCap=\(cap)", count: iterations) { i in
                store.insert(
                    CapturedClip(
                        kind: .text,
                        text: clipText(i),
                        richTextData: nil,
                        imageData: nil,
                        fileURLStrings: [],
                        colorHex: nil,
                        hash: ContentParser.hashText("new:\(cap):\(i)")
                    ),
                    sourceBundleID: "com.example.bench",
                    sourceAppName: "Bench"
                )
            }
            UserDefaults.standard.set(0, forKey: SettingsKeys.historyCap)
        }
    }

    // MARK: - 1b. Store at scale (on-disk, isolated temp container)

    /// Same descriptors as ClipStore, run against a temp-directory container.
    /// ClipStore has no init that accepts a URL, so the on-disk numbers are
    /// measured on a hand-rolled twin of its fetch/insert paths.
    func testStoreOnDiskAtScale() throws {
        try requireBench()

        for size in [1_000, 10_000, 50_000] {
            let (container, dir) = try diskContainer("scale\(size)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let context = container.mainContext

            let now = Date.now
            let each = msEach("disk/insert n=\(size)", count: size) { i in
                context.insert(ClipItem(
                    kind: .text,
                    text: clipText(i),
                    contentHash: ContentParser.hashText("text:\(i)"),
                    sourceBundleID: "com.example.app\(i % 7)",
                    sourceAppName: appNames[i % appNames.count],
                    createdAt: now.addingTimeInterval(-Double(i) * 100)
                ))
                if i % 500 == 499 { try? context.save() }
            }
            try context.save()
            note("disk/insert throughput n=\(size)", "\(Int(1000 / each)) clips/s")
            note("disk/store size n=\(size) text-only", mb(directorySize(dir)))

            // Indexed lookup: contentHash carries an #Index.
            try msEach("disk/fetchByHash(hit) n=\(size)", count: 200) { i in
                let hash = ContentParser.hashText("text:\(i * (size / 200))")
                var d = FetchDescriptor<ClipItem>(
                    predicate: #Predicate { $0.contentHash == hash },
                    sortBy: [SortDescriptor(\ClipItem.createdAt, order: .reverse)]
                )
                d.fetchLimit = 1
                _ = try context.fetch(d)
            }

            // Control: the SAME shape of query on a NON-indexed column.
            // If the #Index is doing work, this should be markedly slower
            // and should scale with n while the indexed one does not.
            try msEach("disk/fetchByBundleID(non-indexed) n=\(size)", count: 200) { i in
                let needle = "com.example.missing\(i)"
                var d = FetchDescriptor<ClipItem>(
                    predicate: #Predicate { $0.sourceBundleID == needle },
                    sortBy: [SortDescriptor(\ClipItem.createdAt, order: .reverse)]
                )
                d.fetchLimit = 1
                _ = try context.fetch(d)
            }

            try msEach("disk/recent(20) n=\(size)", count: 100) { _ in
                var d = FetchDescriptor<ClipItem>(
                    sortBy: [SortDescriptor(\ClipItem.createdAt, order: .reverse)]
                )
                d.fetchLimit = 20
                _ = try context.fetch(d)
            }

            // enforceCap's fetch: ALL unpinned, sorted ascending, materialized.
            ms("disk/enforceCap-fetch(all unpinned) n=\(size)") {
                let d = FetchDescriptor<ClipItem>(
                    predicate: #Predicate { !$0.isPinned },
                    sortBy: [SortDescriptor(\ClipItem.createdAt, order: .forward)]
                )
                _ = try? context.fetch(d)
            }

            // enforceRetention's fetch (30-day cutoff over 60 days of data).
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
            ms("disk/enforceRetention-fetch n=\(size)") {
                let d = FetchDescriptor<ClipItem>(
                    predicate: #Predicate { !$0.isPinned && $0.createdAt < cutoff }
                )
                let expired = (try? context.fetch(d)) ?? []
                print("BENCH |   retention would delete \(expired.count) of \(size)")
            }

            // items(withUUIDs:) — Set.contains inside a #Predicate.
            var all = FetchDescriptor<ClipItem>()
            all.fetchLimit = 10
            let uuids = ((try? context.fetch(all)) ?? []).map(\.uuid)
            let wanted = Set(uuids)
            try msEach("disk/items(withUUIDs:10) n=\(size)", count: 20) { _ in
                _ = try context.fetch(FetchDescriptor<ClipItem>(
                    predicate: #Predicate { wanted.contains($0.uuid) }
                ))
            }
        }
    }

    /// On-disk size for 10k MIXED clips including images.
    func testOnDiskSizeMixedWithImages() throws {
        try requireBench()
        let (container, dir) = try diskContainer("mixed10k")
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = container.mainContext

        let shot = syntheticScreenshot()
        note("image/synthetic screenshot png", "\(shot.count) bytes (1512x982)")

        // 10k clips, 5% images (a realistic screenshot-heavy ratio).
        let total = 10_000
        let imageEvery = 20
        let now = Date.now
        ms("disk/insert 10k mixed (5% images)") {
            for i in 0..<total {
                let isImage = i % imageEvery == 0
                let item = ClipItem(
                    kind: isImage ? .image : .text,
                    text: isImage ? nil : clipText(i),
                    imageData: isImage ? shot : nil,
                    contentHash: ContentParser.hashText("mixed:\(i)"),
                    sourceAppName: appNames[i % appNames.count],
                    createdAt: now.addingTimeInterval(-Double(i) * 100)
                )
                context.insert(item)
                if i % 200 == 199 { try? context.save() }
            }
            try? context.save()
        }
        let size = directorySize(dir)
        note("disk/10k mixed store size", "\(mb(size)) (\(total / imageEvery) images @ \(shot.count) B)")
        note("disk/bytes per clip", "\(size / Int64(total)) B avg")
    }

    // MARK: - 2. Search — PanelView's Swift-side linear filter

    /// Reproduces PanelView.visibleItems / matchesSearch exactly
    /// (Sources/MemoryClip/UI/PanelView.swift:80-113) over an in-memory store.
    func testPanelSearchFilterScaling() throws {
        try requireBench()

        for size in [1_000, 10_000, 50_000] {
            let container = try inMemoryContainer()
            let context = container.mainContext
            populate(context, count: size, withOCR: true)

            // The @Query itself: full sorted fetch of every clip.
            var queryMs = 0.0
            var items: [ClipItem] = []
            queryMs = ms("search/@Query full fetch n=\(size)") {
                items = (try? context.fetch(FetchDescriptor<ClipItem>(
                    sortBy: [SortDescriptor(\ClipItem.createdAt, order: .reverse)]
                ))) ?? []
            }
            XCTAssertEqual(items.count, size)
            _ = queryMs

            // Warm pass so the objects are faulted in; the filter below then
            // measures pure Swift-side matching, which is the best case for
            // the current design.
            _ = items.filter { $0.text != nil }

            let queries = ["z", "ze", "zeb", "zebr", "zebra"] // a 5-keystroke word
            for q in queries {
                let each = msEach("search/filter '\(q)' n=\(size)", count: 20) { _ in
                    let query = q.lowercased()
                    var matched = 0
                    for item in items {
                        guard TypeFilter.all.matches(item.kind) else { continue }
                        if let text = item.text, text.lowercased().contains(query) { matched += 1; continue }
                        if let ocr = item.ocrText, ocr.lowercased().contains(query) { matched += 1; continue }
                        if let hex = item.colorHex, hex.lowercased().contains(query) { matched += 1; continue }
                        var hit = false
                        for u in item.fileURLStrings where u.lowercased().contains(query) { hit = true; break }
                        if hit { matched += 1; continue }
                        if let app = item.sourceAppName, app.lowercased().contains(query) { matched += 1 }
                    }
                    _ = matched
                }
                _ = each
            }

            // PanelView recomputes `visibleItems` several times per body
            // evaluation (clipList, footer count, onChange handlers,
            // scroll-to). Measure the realistic per-keystroke multiple.
            let onePass = msEach("search/filter single-pass n=\(size)", count: 20) { _ in
                let query = "zebra"
                _ = items.filter { item in
                    if let text = item.text, text.lowercased().contains(query) { return true }
                    if let ocr = item.ocrText, ocr.lowercased().contains(query) { return true }
                    if let hex = item.colorHex, hex.lowercased().contains(query) { return true }
                    for u in item.fileURLStrings where u.lowercased().contains(query) { return true }
                    if let app = item.sourceAppName, app.lowercased().contains(query) { return true }
                    return false
                }
            }
            note("search/est. per-keystroke n=\(size)", "\(fmt(onePass * 4)) ms if visibleItems is evaluated 4x")

            // sourceAppNames — also recomputed, builds a Set over all items.
            msEach("search/sourceAppNames n=\(size)", count: 20) { _ in
                _ = Set(items.compactMap(\.sourceAppName).filter { !$0.isEmpty })
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            }

            // What a predicate-side CONTAINS would cost instead.
            try msEach("search/SwiftData predicate contains n=\(size)", count: 20) { _ in
                let needle = "zebra"
                var d = FetchDescriptor<ClipItem>(
                    predicate: #Predicate<ClipItem> { $0.text?.localizedStandardContains(needle) == true },
                    sortBy: [SortDescriptor(\ClipItem.createdAt, order: .reverse)]
                )
                d.fetchLimit = 200
                _ = try context.fetch(d)
            }
        }
    }

    /// Splits the search-filter cost between SwiftData attribute access and
    /// the Swift string work, so the fix can be aimed at the right half.
    func testSearchCostAttribution() throws {
        try requireBench()
        let size = 10_000
        let container = try inMemoryContainer()
        let context = container.mainContext
        populate(context, count: size, withOCR: true)
        let items = try context.fetch(FetchDescriptor<ClipItem>(
            sortBy: [SortDescriptor(\ClipItem.createdAt, order: .reverse)]
        ))
        _ = items.filter { ($0.text ?? "").lowercased().contains("warm") }

        msEach("attrib/full matchesSearch pass n=\(size)", count: 20) { _ in
            let query = "zebra"
            _ = items.filter { item in
                if let text = item.text, text.lowercased().contains(query) { return true }
                if let ocr = item.ocrText, ocr.lowercased().contains(query) { return true }
                if let hex = item.colorHex, hex.lowercased().contains(query) { return true }
                for u in item.fileURLStrings where u.lowercased().contains(query) { return true }
                if let app = item.sourceAppName, app.lowercased().contains(query) { return true }
                return false
            }
        }
        msEach("attrib/SwiftData attribute reads only n=\(size)", count: 20) { _ in
            var n = 0
            for item in items {
                n += (item.text?.count ?? 0) + (item.ocrText?.count ?? 0) + (item.sourceAppName?.count ?? 0)
            }
            _ = n
        }
        msEach("attrib/.kind read only n=\(size)", count: 20) { _ in
            var n = 0
            for item in items where item.kind == .text { n += 1 }
            _ = n
        }
        struct Plain { var text: String?; var ocr: String?; var app: String? }
        let plains = items.map { Plain(text: $0.text, ocr: $0.ocrText, app: $0.sourceAppName) }
        msEach("attrib/same string work over plain structs n=\(size)", count: 20) { _ in
            let q = "zebra"
            _ = plains.filter { p in
                if let t = p.text, t.lowercased().contains(q) { return true }
                if let o = p.ocr, o.lowercased().contains(q) { return true }
                if let a = p.app, a.lowercased().contains(q) { return true }
                return false
            }
        }
    }

    /// Same filter, but on-disk, where each item must be faulted from SQLite
    /// the first time it is touched — the cold-panel case a user actually hits.
    func testPanelSearchColdFaulting() throws {
        try requireBench()
        for size in [10_000, 50_000] {
            let (container, dir) = try diskContainer("search\(size)")
            defer { try? FileManager.default.removeItem(at: dir) }
            populate(container.mainContext, count: size, withOCR: true)

            // Fresh container = cold caches, like opening the panel at launch.
            let cold = try ModelContainer(
                for: Schema([ClipItem.self]),
                configurations: [ModelConfiguration(url: dir.appendingPathComponent("bench.store"))]
            )
            let ctx = cold.mainContext
            var items: [ClipItem] = []
            ms("searchcold/@Query full fetch n=\(size)") {
                items = (try? ctx.fetch(FetchDescriptor<ClipItem>(
                    sortBy: [SortDescriptor(\ClipItem.createdAt, order: .reverse)]
                ))) ?? []
            }
            ms("searchcold/first filter pass (faults all rows) n=\(size)") {
                _ = items.filter { ($0.text ?? "").lowercased().contains("zebra") }
            }
            msEach("searchcold/warm filter pass n=\(size)", count: 10) { _ in
                _ = items.filter { ($0.text ?? "").lowercased().contains("zebra") }
            }
        }
    }

    // MARK: - 3. Memory — image clips under @Query

    func testMemoryWith500ImageClips() throws {
        try requireBench()
        let shot = syntheticScreenshot()
        note("memory/screenshot png size", "\(shot.count) bytes")

        let (container, dir) = try diskContainer("images")
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = container.mainContext

        let count = 500
        for i in 0..<count {
            // Vary the bytes slightly so SQLite cannot dedupe blobs.
            var data = shot
            data.append(contentsOf: [UInt8(i & 0xFF), UInt8((i >> 8) & 0xFF)])
            context.insert(ClipItem(
                kind: .image,
                imageData: data,
                contentHash: ContentParser.hashText("img:\(i)"),
                sourceAppName: "Screenshot",
                createdAt: .now.addingTimeInterval(-Double(i))
            ))
            if i % 50 == 49 { try? context.save() }
        }
        try context.save()
        note("memory/on-disk size for 500 images", mb(directorySize(dir)))

        // Fresh container so nothing is already resident.
        let cold = try ModelContainer(
            for: Schema([ClipItem.self]),
            configurations: [ModelConfiguration(url: dir.appendingPathComponent("bench.store"))]
        )
        let ctx = cold.mainContext

        let before = memoryFootprint()
        note("memory/footprint before @Query", mb(before.footprint))

        var items: [ClipItem] = []
        ms("memory/full fetch of 500 image clips") {
            items = (try? ctx.fetch(FetchDescriptor<ClipItem>(
                sortBy: [SortDescriptor(\ClipItem.createdAt, order: .reverse)]
            ))) ?? []
        }
        let afterFetch = memoryFootprint()
        note("memory/footprint after fetch (rows not faulted)", mb(afterFetch.footprint))
        note("memory/delta from fetch", mb(afterFetch.footprint - before.footprint))

        // Touching imageData is what a rendered row does (ClipRowView shows a
        // thumbnail built from the full blob).
        var bytes = 0
        ms("memory/touch imageData on all 500") {
            for item in items { bytes += item.imageData?.count ?? 0 }
        }
        let afterTouch = memoryFootprint()
        note("memory/total image bytes materialized", mb(Int64(bytes)))
        note("memory/footprint after touching imageData", mb(afterTouch.footprint))
        note("memory/delta from touching blobs", mb(afterTouch.footprint - afterFetch.footprint))
        note("memory/resident after", mb(afterTouch.resident))
        XCTAssertEqual(items.count, count)
    }

    // MARK: - 4. OCR

    func testOCRLatency() async throws {
        try requireBench()
        let shot = syntheticScreenshot()
        note("ocr/input png", "\(shot.count) bytes, 1512x982")

        // Warm-up: first Vision call loads models and is not representative.
        let warmStart = DispatchTime.now().uptimeNanoseconds
        let first = await OCRService.recognizeText(in: shot)
        let warmMs = Double(DispatchTime.now().uptimeNanoseconds - warmStart) / 1_000_000
        report("ocr/first call (cold, model load)", warmMs)
        note("ocr/characters extracted", "\(first?.count ?? 0)")

        var totals: [Double] = []
        for _ in 0..<5 {
            let s = DispatchTime.now().uptimeNanoseconds
            _ = await OCRService.recognizeText(in: shot)
            totals.append(Double(DispatchTime.now().uptimeNanoseconds - s) / 1_000_000)
        }
        let avg = totals.reduce(0, +) / Double(totals.count)
        report("ocr/warm call avg over 5", avg)
        note("ocr/warm samples", totals.map { fmt($0) }.joined(separator: ", "))

        // Small image (a cropped snippet).
        let small = syntheticScreenshot(width: 600, height: 300)
        _ = await OCRService.recognizeText(in: small)
        let s2 = DispatchTime.now().uptimeNanoseconds
        _ = await OCRService.recognizeText(in: small)
        report("ocr/small 600x300", Double(DispatchTime.now().uptimeNanoseconds - s2) / 1_000_000)

        note("ocr/projected backlog 20 images (one batch)", "\(fmt(avg * 20)) ms")
        note("ocr/projected backlog 200 images", "\(fmt(avg * 200 / 1000)) s")
    }

    /// OCRCoordinator drains serially: measure end-to-end for a real backlog.
    func testOCRCoordinatorBacklog() async throws {
        try requireBench()
        UserDefaults.standard.set(true, forKey: OCRCoordinator.enabledKey)

        let store = try ClipStore(inMemory: true)
        let shot = syntheticScreenshot(width: 800, height: 500)
        let backlog = 40
        for i in 0..<backlog {
            var data = shot
            data.append(UInt8(i))
            store.context.insert(ClipItem(
                kind: .image,
                imageData: data,
                contentHash: ContentParser.hashText("backlog:\(i)"),
                createdAt: .now.addingTimeInterval(-Double(i))
            ))
        }
        store.save()

        // Warm Vision first so we time the drain, not the model load.
        _ = await OCRService.recognizeText(in: shot)

        let coordinator = OCRCoordinator(store: store)
        let start = DispatchTime.now().uptimeNanoseconds
        coordinator.processPending()
        // Poll until the queue is empty.
        while !store.pendingOCR(limit: 1).isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        report("ocr/coordinator drain \(backlog) images (800x500)", elapsed)
        note("ocr/per image in drain", "\(fmt(elapsed / Double(backlog))) ms")
        note("ocr/batchSize", "\(OCRCoordinator.batchSize) per batch, \(OCRCoordinator.concurrency) concurrent, max \(OCRCoordinator.maxImagesPerDrain) images per drain — a drain is bounded and re-arms itself for the remaining backlog")
        coordinator.stop()
    }

    // MARK: - 5. Startup

    func testColdStartAgainstLargeStore() throws {
        try requireBench()
        let previousRetention = UserDefaults.standard.integer(forKey: SettingsKeys.retentionDays)
        defer { UserDefaults.standard.set(previousRetention, forKey: SettingsKeys.retentionDays) }

        for size in [1_000, 10_000, 50_000] {
            let (container, dir) = try diskContainer("startup\(size)")
            defer { try? FileManager.default.removeItem(at: dir) }
            populate(container.mainContext, count: size)
            let file = dir.appendingPathComponent("bench.store")
            note("startup/store size n=\(size)", mb(directorySize(dir)))

            // Cold ModelContainer init — the AppDelegate's `try ClipStore()`.
            ms("startup/ModelContainer init n=\(size)") {
                _ = try? ModelContainer(
                    for: Schema([ClipItem.self]),
                    configurations: [ModelConfiguration(url: file)]
                )
            }

            let fresh = try ModelContainer(
                for: Schema([ClipItem.self]),
                configurations: [ModelConfiguration(url: file)]
            )
            let ctx = fresh.mainContext
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
            ms("startup/enforceRetention(30d) n=\(size)") {
                let d = FetchDescriptor<ClipItem>(
                    predicate: #Predicate { !$0.isPinned && $0.createdAt < cutoff }
                )
                let expired = (try? ctx.fetch(d)) ?? []
                for item in expired { ctx.delete(item) }
                try? ctx.save()
            }

            // And the first panel open right after: full sorted fetch.
            let fresh2 = try ModelContainer(
                for: Schema([ClipItem.self]),
                configurations: [ModelConfiguration(url: file)]
            )
            ms("startup/first @Query after retention n=\(size)") {
                _ = try? fresh2.mainContext.fetch(FetchDescriptor<ClipItem>(
                    sortBy: [SortDescriptor(\ClipItem.createdAt, order: .reverse)]
                ))
            }
        }
    }
}
