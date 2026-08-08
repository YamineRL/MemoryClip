import Foundation
import SwiftData
import XCTest

@testable import MemoryClip

/// Before/after measurements for the panel's search path: the old design
/// (fetch every clip, filter in Swift) against the current one (filter in
/// SQLite with a page limit, then a Swift pass over the page).
///
/// Skipped unless MEMORYCLIP_BENCH=1, like `PerformanceBenchmarks`. Everything runs
/// against in-memory containers — never the user's store.
@MainActor
final class PanelQueryBenchmarks: XCTestCase {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["MEMORYCLIP_BENCH"] == "1"
    }

    private func requireBench() throws {
        try XCTSkipUnless(Self.enabled, "set MEMORYCLIP_BENCH=1 to run benchmarks")
    }

    private func fmt(_ value: Double) -> String { String(format: "%.2f", value) }

    private func report(_ label: String, _ millis: Double) {
        print("BENCH | \(label) | \(fmt(millis)) ms")
    }

    /// Milliseconds per iteration.
    @discardableResult
    private func each(_ label: String, count: Int, _ body: (Int) throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<count { try body(i) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / Double(count)
        report(label, ms)
        return ms
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([ClipItem.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func populate(_ context: ModelContext, count: Int) {
        let now = Date.now
        let apps = ["Safari", "Xcode", "Terminal", "Slack", "Notes", "Mail", "Finder"]
        for i in 0..<count {
            let kind: ClipKind = i % 97 == 0 ? .file : (i % 31 == 0 ? .image : .text)
            let item = ClipItem(
                kind: kind,
                text: kind == .file ? nil : "lorem ipsum dolor \(i) zebra quokka snippet \(i % 13)",
                fileURLStrings: kind == .file ? ["/Users/x/Documents/report-\(i).pdf"] : [],
                contentHash: "hash-\(i)",
                sourceAppName: apps[i % apps.count],
                createdAt: now.addingTimeInterval(-Double(i)),
                ocrText: kind == .image ? "extracted text \(i) invoice" : nil
            )
            context.insert(item)
        }
        try? context.save()
    }

    /// The old panel pipeline, reproduced: one unbounded sorted fetch plus a
    /// Swift-side pass per use site.
    private func legacyVisible(_ context: ModelContext, _ filter: ClipFilter) throws -> [ClipItem] {
        let all = try context.fetch(
            FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\ClipItem.createdAt, order: .reverse)])
        )
        return filter.apply(to: all)
    }

    func testSearchBeforeAfter() throws {
        try requireBench()
        for size in [1_000, 10_000, 50_000] {
            let container = try container()
            let context = ModelContext(container)
            populate(context, count: size)

            let filter = ClipFilter(search: "zebra")

            // Cold panel open: no search, just the list.
            report("panel open (old, full fetch) n=\(size)", try each("", count: 3) { _ in
                _ = try legacyVisible(context, ClipFilter())
            })
            report("panel open (new, paged query) n=\(size)", try each("", count: 3) { _ in
                _ = ClipFilter().refine(try context.fetch(ClipFilter().fetchDescriptor()))
            })

            // One keystroke: the old code re-derived `visibleItems` at four
            // use sites (list, footer count, onChange, scroll), the new one
            // fetches once per body pass.
            let oldOnce = try each("search old, one pass n=\(size)", count: 5) { _ in
                _ = try legacyVisible(context, filter)
            }
            report("search old, one keystroke (x4) n=\(size)", oldOnce * 4)

            let newOnce = try each("search new, one fetch+refine n=\(size)", count: 5) { _ in
                _ = filter.refine(try context.fetch(filter.fetchDescriptor()))
            }
            report("search new, one keystroke n=\(size)", newOnce)

            // The worst case for the new path: a needle that matches nothing,
            // so SQLite has to look at every row instead of filling a page
            // and stopping.
            let miss = ClipFilter(search: "qwertyuiop")
            _ = try each("search old, no matches n=\(size)", count: 5) { _ in
                _ = try legacyVisible(context, miss)
            }
            _ = try each("search new, no matches n=\(size)", count: 5) { _ in
                _ = miss.refine(try context.fetch(miss.fetchDescriptor()))
            }

            // Type + source filters, which also moved into SQL.
            _ = try each("filter old (type+source) n=\(size)", count: 5) { _ in
                _ = try legacyVisible(context, ClipFilter(type: .image, source: "Safari"))
            }
            _ = try each("filter new (type+source) n=\(size)", count: 5) { _ in
                let f = ClipFilter(type: .image, source: "Safari")
                _ = f.refine(try context.fetch(f.fetchDescriptor()))
            }

            // The source-app menu: was a Set over every faulted clip on every
            // render, is now one attribute-only fetch when the panel opens.
            _ = try each("sourceAppNames old n=\(size)", count: 5) { _ in
                let all = try context.fetch(FetchDescriptor<ClipItem>())
                _ = Set(all.compactMap(\.sourceAppName).filter { !$0.isEmpty })
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            }
            // The replacement: one fetchLimit-1 query per distinct app.
            _ = try each("sourceAppNames new n=\(size)", count: 5) { _ in
                var found: [String?] = []
                while found.count < 50 {
                    let seen = found
                    var d = FetchDescriptor<ClipItem>(
                        predicate: #Predicate<ClipItem> { !seen.contains($0.sourceAppName) }
                    )
                    d.fetchLimit = 1
                    d.propertiesToFetch = [\.sourceAppName]
                    guard let next = try context.fetch(d).first else { break }
                    found.append(next.sourceAppName)
                }
                _ = found.compactMap { $0 }
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            }
        }
    }
}
