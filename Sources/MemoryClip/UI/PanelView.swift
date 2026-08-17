import AppKit
import SwiftUI
import SwiftData

/// Content-type filter chips for the panel search row.
enum TypeFilter: String, CaseIterable, Identifiable {
    case all, text, image, link, file, color

    var id: String { rawValue }

    /// Human-readable label for menus and chips.
    var label: String {
        switch self {
        case .all: return "All"
        case .text: return "Text"
        case .image: return "Images"
        case .link: return "Links"
        case .file: return "Files"
        case .color: return "Colors"
        }
    }

    /// The chip's leading dot. Colour is a *secondary* cue only — the chip's
    /// text label carries the meaning, so a dot nobody can distinguish costs
    /// nothing.
    var dotColor: Color {
        switch self {
        case .all: return Color(nsColor: .tertiaryLabelColor)
        case .text: return Color(nsColor: .systemBlue)
        case .image: return Color(nsColor: .systemGreen)
        case .link: return Color(nsColor: .systemTeal)
        case .file: return Color(nsColor: .systemPink)
        case .color: return Color(nsColor: .systemOrange)
        }
    }

    func matches(_ kind: ClipKind) -> Bool {
        kinds.map { $0.contains(kind) } ?? true
    }

    /// The clip kinds this chip admits, or nil for "everything".
    ///
    /// The single source of truth for both the Swift-side `matches` and the
    /// SwiftData predicate, so the two can never drift apart.
    var kinds: Set<ClipKind>? {
        switch self {
        case .all:
            return nil
        case .text:
            // Rich text is text as far as the filter is concerned; links are
            // deliberately *not* folded in (they have their own chip).
            return [.text, .richText]
        case .image:
            return [.image]
        case .link:
            return [.link]
        case .file:
            return [.file]
        case .color:
            return [.color]
        }
    }

    /// The same set as raw strings — `ClipItem.kindRaw` is what the store
    /// actually holds, and a predicate can only compare stored attributes.
    var kindRawValues: [String] {
        (kinds ?? []).map(\.rawValue).sorted()
    }
}

// MARK: - Filtering (pure, testable)

/// The subset of a clip the panel needs to filter and describe it.
///
/// Declared as a protocol — the way `QueueOrder` was split out of
/// `QueueService` — so the filtering and selection logic can be tested with
/// plain values, without a SwiftData container.
protocol ClipDisplayable {
    var uuid: UUID { get }
    var kind: ClipKind { get }
    var text: String? { get }
    var ocrText: String? { get }
    var colorHex: String? { get }
    var fileURLStrings: [String] { get }
    var sourceAppName: String? { get }
    /// The local model's title for the clip, when one was produced.
    var refinedTitle: String? { get }
    /// The local model's cleaned-up version of `ocrText`, when one was
    /// produced.
    var refinedText: String? { get }
    /// Whether this file clip is a screenshot picked up from the screenshot
    /// folder.
    var isScreenshot: Bool { get }
}

extension ClipItem: ClipDisplayable {}

extension ClipDisplayable {
    // Defaults for the three properties above, so the test doubles that
    // conform to this protocol (and predate the note pipeline) keep
    // compiling. `ClipItem`'s stored properties satisfy the requirements
    // directly and shadow these.
    var refinedTitle: String? { nil }
    var refinedText: String? { nil }
    var isScreenshot: Bool { false }

    /// One-line description used for VoiceOver announcements.
    var announcementSummary: String {
        let raw: String
        // A refined title beats every other summary when there is one: it is
        // a sentence about the content, where the alternatives are a file
        // name or the first line of raw OCR.
        if let title = refinedTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title.count > 80 ? String(title.prefix(80)) + "…" : title
        }
        switch kind {
        case .file:
            // Through `ClipDisplay`, which decodes: VoiceOver reading
            // "my%20file.txt" out loud as "my percent twenty file dot t x t"
            // is the same bug as showing it, only louder.
            raw = ClipDisplay.displayNames(fileURLStrings)
        case .color:
            raw = colorHex ?? "colour"
        case .image:
            let ocr = ocrText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            raw = ocr.isEmpty ? "image" : "image, \(ocr)"
        default:
            raw = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "empty clip" }
        return collapsed.count > 80 ? String(collapsed.prefix(80)) + "…" : collapsed
    }
}

/// The panel's three filters (search text, content type, source app) as one
/// value. Pure: no SwiftUI, no model context.
struct ClipFilter: Equatable {
    var search: String = ""
    var type: TypeFilter = .all
    var source: String?

    /// True when nothing is being narrowed down.
    var isIdentity: Bool { search.isEmpty && type == .all && source == nil }

    func matchesType(_ item: some ClipDisplayable) -> Bool {
        type.matches(item.kind)
    }

    func matchesSource(_ item: some ClipDisplayable) -> Bool {
        guard let source else { return true }
        return item.sourceAppName == source
    }

    func matchesSearch(_ item: some ClipDisplayable) -> Bool {
        guard !search.isEmpty else { return true }
        if item.text?.localizedStandardContains(search) == true { return true }
        // Image clips are searchable through their extracted text.
        if item.ocrText?.localizedStandardContains(search) == true { return true }
        // …and through what the local model made of it. Note the asymmetry
        // with `predicate` below, which does NOT carry these two clauses:
        // that expression is at the documented limit of what the Swift type
        // checker will compile in reasonable time, and the clips this
        // actually matters for — screenshots, which are `.file` kind — are
        // admitted by the predicate wholesale and re-checked here by
        // `refine(_:)` regardless. The cost is that a pasteboard IMAGE clip
        // is not searchable by a word that appears only in its refined text,
        // which is close to no cost at all: refinement is derived from
        // `ocrText`, and that is indexed.
        if item.refinedText?.localizedStandardContains(search) == true { return true }
        if item.refinedTitle?.localizedStandardContains(search) == true { return true }
        if item.colorHex?.localizedStandardContains(search) == true { return true }
        if ClipDisplay.fileURLsMatch(item.fileURLStrings, search: search) { return true }
        if item.sourceAppName?.localizedStandardContains(search) == true { return true }
        return false
    }

    func matches(_ item: some ClipDisplayable) -> Bool {
        matchesType(item) && matchesSource(item) && matchesSearch(item)
    }

    func apply<T: ClipDisplayable>(to items: [T]) -> [T] {
        items.filter { matches($0) }
    }
}

// MARK: - Filtering in SQL

/// Hand-built `#Predicate` fragments.
///
/// Each returns an opaque (so: concrete, so: composable) expression node of
/// exactly the shape the `#Predicate` macro emits, which is what lets
/// SwiftData turn the result into SQL. See `ClipFilter.predicate` for why the
/// macro is not used.
private typealias ClipVariable = PredicateExpressions.Variable<ClipItem>

private func clipConstant(_ value: Bool) -> some StandardPredicateExpression<Bool> {
    PredicateExpressions.build_Arg(value)
}

/// `values.contains(item[keyPath:])` — an SQL `IN (…)`.
private func clipOneOf(
    _ item: ClipVariable,
    _ keyPath: any KeyPath<ClipItem, String> & Sendable,
    _ values: [String]
) -> some StandardPredicateExpression<Bool> {
    PredicateExpressions.build_contains(
        PredicateExpressions.build_Arg(values),
        PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg(item), keyPath: keyPath)
    )
}

private func clipEquals(
    _ item: ClipVariable,
    _ keyPath: any KeyPath<ClipItem, String?> & Sendable,
    _ value: String?
) -> some StandardPredicateExpression<Bool> {
    PredicateExpressions.build_Equal(
        lhs: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg(item), keyPath: keyPath),
        rhs: PredicateExpressions.build_Arg(value)
    )
}

/// `item[keyPath:]?.localizedStandardContains(needle) == true` — case- and
/// diacritic-insensitive, and the one form CoreData can compile. The
/// tempting `(item.foo ?? "").localizedStandardContains(…)` throws an
/// uncaught "unimplemented SQL generation" exception at fetch time.
private func clipContains(
    _ item: ClipVariable,
    _ keyPath: any KeyPath<ClipItem, String?> & Sendable,
    _ needle: String
) -> some StandardPredicateExpression<Bool> {
    PredicateExpressions.build_Equal(
        lhs: PredicateExpressions.build_flatMap(
            PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg(item), keyPath: keyPath)
        ) {
            PredicateExpressions.build_localizedStandardContains(
                PredicateExpressions.build_Arg($0),
                PredicateExpressions.build_Arg(needle)
            )
        },
        rhs: PredicateExpressions.build_Arg(true)
    )
}

private func clipOr<L: StandardPredicateExpression<Bool>, R: StandardPredicateExpression<Bool>>(
    _ lhs: L,
    _ rhs: R
) -> some StandardPredicateExpression<Bool> {
    PredicateExpressions.build_Disjunction(lhs: lhs, rhs: rhs)
}

private func clipAnd<L: StandardPredicateExpression<Bool>, R: StandardPredicateExpression<Bool>>(
    _ lhs: L,
    _ rhs: R
) -> some StandardPredicateExpression<Bool> {
    PredicateExpressions.build_Conjunction(lhs: lhs, rhs: rhs)
}

extension ClipFilter {
    /// How many clips one page of the panel list holds.
    ///
    /// The list is paged rather than unbounded: fetching every row of a
    /// 50k-clip store costs ~1.8 s before a single pixel is drawn, while a
    /// predicate-side fetch with this limit is flat in store size (~8 ms).
    static let pageSize = 200

    /// The panel's query: type, source and (most of) search pushed into
    /// SQLite, newest first, capped at `limit` rows.
    ///
    /// What is *not* expressible here is the file-path search: SwiftData
    /// stores `fileURLStrings` as one opaque blob, so no predicate can look
    /// inside it. File clips are therefore let through the search clause
    /// wholesale and re-checked in Swift by `refine(_:)` — a Swift-side pass
    /// over at most `limit` rows instead of the whole store.
    ///
    /// Every clause is written in the forms CoreData can actually compile.
    /// In particular `optional?.localizedStandardContains(x) == true`, and
    /// *not* `(optional ?? "").localizedStandardContains(x)`, which throws an
    /// uncaught "unimplemented SQL generation" exception at fetch time.
    func fetchDescriptor(limit: Int = ClipFilter.pageSize) -> FetchDescriptor<ClipItem> {
        var descriptor = FetchDescriptor<ClipItem>(
            predicate: predicate,
            sortBy: [SortDescriptor(\ClipItem.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// The filter as a SwiftData predicate.
    ///
    /// Built out of `PredicateExpressions` by hand rather than with the
    /// `#Predicate` macro. The macro's type-checking cost explodes with the
    /// number of clauses — measured on this expression, three OR terms
    /// type-check in 0.4 s, four in 6.5 s and five fail outright with
    /// "unable to type-check in reasonable time". The tree below is the same
    /// thing the macro would expand to, is what SwiftData translates to SQL,
    /// and type-checks in well under a second.
    ///
    /// Constant clauses (`anyKind`, `anySource`, `!searching`) rather than a
    /// separate predicate per case: the shape stays fixed, and a leading
    /// constant `true` short-circuits its whole branch inside SQLite. That is
    /// not cosmetic — at 50k clips an unguarded `kindRaw IN (…)` costs 10 ms
    /// on every fetch, a guarded one nothing.
    var predicate: Predicate<ClipItem> {
        let needle = search
        let searching = !search.isEmpty
        let source = source
        let anySource = source == nil
        let kinds = type.kindRawValues
        let anyKind = kinds.isEmpty
        let fileKind = [ClipKind.file.rawValue]

        return Predicate<ClipItem> { item in
            clipAnd(
                clipAnd(
                    clipOr(clipConstant(anyKind), clipOneOf(item, \.kindRaw, kinds)),
                    clipOr(clipConstant(anySource), clipEquals(item, \.sourceAppName, source))
                ),
                clipOr(
                    clipConstant(!searching),
                    clipOr(
                        clipOr(
                            // File clips carry their searchable content in
                            // `fileURLStrings`, which SwiftData stores as one
                            // opaque blob; they are admitted here and sifted
                            // by `refine(_:)`.
                            clipOneOf(item, \.kindRaw, fileKind),
                            clipContains(item, \.text, needle)
                        ),
                        clipOr(
                            clipOr(
                                clipContains(item, \.ocrText, needle),
                                clipContains(item, \.colorHex, needle)
                            ),
                            clipContains(item, \.sourceAppName, needle)
                        )
                    )
                )
            )
        }
    }

    /// The part of the filter the predicate could not express, applied to
    /// rows the predicate already returned.
    ///
    /// Only file clips need re-checking: they are the ones `predicate` waves
    /// through unconditionally while a search is active. Everything else
    /// already matched in SQL.
    func refine<T: ClipDisplayable>(_ items: [T]) -> [T] {
        guard !search.isEmpty else { return items }
        return items.filter { $0.kind != .file || matchesSearch($0) }
    }
}

// MARK: - Selection (pure, testable)

/// The panel's selection, tracked by clip `uuid` rather than by row index.
///
/// The list mutates underneath the panel — the watcher keeps capturing while
/// it is open and new clips insert at index 0 — so an index-based selection
/// silently slides onto a different clip. Storing the uuid and re-deriving
/// the index each render keeps the highlight on the clip the user picked.
struct ClipSelection: Equatable {
    /// The selected clip, or nil for "nothing chosen yet" (which means the
    /// top row: the panel opens with the newest clip ready to paste).
    private(set) var id: UUID?

    init(id: UUID? = nil) {
        self.id = id
    }

    /// Row index of the selection in the current list.
    ///
    /// - nil when the list is empty, or when the selected clip is no longer
    ///   in the list (deleted or filtered away) — the caller must then do
    ///   nothing rather than fall back to row 0 and act on the wrong clip.
    /// - 0 when no clip has been chosen yet.
    func index(in ids: [UUID]) -> Int? {
        guard !ids.isEmpty else { return nil }
        guard let id else { return 0 }
        return ids.firstIndex(of: id)
    }

    /// Index used as the origin of a movement: a stale selection moves from
    /// the top rather than refusing to move at all.
    func movementOrigin(in ids: [UUID]) -> Int {
        index(in: ids) ?? 0
    }

    mutating func clear() {
        id = nil
    }

    /// Select a row by index, clamped into the list.
    mutating func select(index: Int, in ids: [UUID]) {
        guard !ids.isEmpty else {
            id = nil
            return
        }
        id = ids[min(max(index, 0), ids.count - 1)]
    }

    /// Move by `delta` rows from the current position, clamped.
    mutating func move(by delta: Int, in ids: [UUID]) {
        guard !ids.isEmpty else {
            id = nil
            return
        }
        select(index: movementOrigin(in: ids) + delta, in: ids)
    }

    /// Pick the neighbour that should inherit the selection when `removed`
    /// is deleted. `ids` is the list *before* the deletion, so the new
    /// selection is valid the moment the query refreshes.
    mutating func selectNeighbour(of removed: UUID, in ids: [UUID]) {
        guard let index = ids.firstIndex(of: removed) else { return }
        var remaining = ids
        remaining.remove(at: index)
        guard !remaining.isEmpty else {
            id = nil
            return
        }
        id = remaining[min(index, remaining.count - 1)]
    }
}

// MARK: - Input mode

/// Which mode the panel's keyboard is in while vim navigation is enabled.
///
/// Without this the panel used "the search field is empty" as a proxy for
/// "the user means navigation", which ate the first letters of any query
/// starting with a vim binding (`google` pasted, `ddos` deleted).
enum PanelInputMode: Equatable {
    /// Keys are vim commands; typing does not reach the search field.
    case normal
    /// Keys type into the search field.
    case insert

    var badge: String {
        switch self {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        }
    }

    var announcement: String {
        switch self {
        case .normal: return "Normal mode. Slash to search."
        case .insert: return "Search mode. Escape to return to normal mode."
        }
    }

    /// Whether plain characters are read as vim commands rather than typed.
    ///
    /// The whole reason the bare-letter bindings can exist: in insert mode
    /// every character belongs to the query, so `n` types an `n` and only
    /// normal mode may claim it. The modified shortcuts (⌘S, ⌘1–⌘9) run in
    /// both modes precisely because they are unreachable by typing.
    var readsVimKeys: Bool { self == .normal }
}

/// Callbacks the panel UI uses to talk back to controllers.
struct PanelActions {
    var paste: (ClipItem, Bool) -> Void
    var copyOnly: (ClipItem) -> Void
    /// Copy an image clip's OCR text (Phase 3 made it searchable; this makes
    /// it reachable).
    var copyExtractedText: (ClipItem) -> Void
    /// Copy an arbitrary string derived from a clip (the preview pane's
    /// right-click menu).
    var copyText: (ClipItem, String) -> Void
    var close: () -> Void
    var applyTransform: (ClipItem, Transform) -> Void
    var showQR: (ClipItem) -> Void
    /// Add/remove a clip from the paste queue (Phase 3).
    var toggleQueue: (ClipItem) -> Void
    /// Paste every queued clip, in order, into the previous app.
    var pasteQueue: () -> Void
    /// Write (or rewrite) this clip's note at the configured destination.
    var saveNote: (ClipItem) -> Void
    /// Open the note already written for this clip.
    var openNote: (ClipItem) -> Void
    /// Show a screenshot clip's file in the Finder.
    var revealInFinder: (ClipItem) -> Void
    /// Show a run of clips full size in Quick Look, opening on `index`.
    ///
    /// The completion carries the clip Quick Look was showing when it closed,
    /// so the panel's selection can follow wherever the arrows ended up.
    var quickLook: ([ClipItem], Int, @escaping (UUID) -> Void) -> Void
}

/// The main clip-panel view.
///
/// A thin shell around `PanelContentView`: it owns the two values the clip
/// query is built from (the filter and how many rows are paged in) because a
/// `@Query`'s descriptor has to be handed to the view's initialiser, and a
/// view cannot read its own `@State` there. Everything else lives in the
/// child, whose `@State` survives the re-initialisations that a filter change
/// causes.
struct PanelView: View {
    @ObservedObject private var uiState: PanelUIState
    @ObservedObject private var queue: QueueService
    private let actions: PanelActions

    @State private var filter = ClipFilter()
    @State private var pageLimit = ClipFilter.pageSize

    init(uiState: PanelUIState, queue: QueueService, actions: PanelActions) {
        self.uiState = uiState
        self.queue = queue
        self.actions = actions
    }

    var body: some View {
        PanelContentView(
            filter: $filter,
            pageLimit: $pageLimit,
            uiState: uiState,
            queue: queue,
            actions: actions
        )
    }
}

/// The panel proper: search, filters, clip list.
struct PanelContentView: View {
    @Environment(\.modelContext) private var modelContext
    /// Drives the higher-contrast variants of the chip and row treatments.
    @Environment(\.colorSchemeContrast) private var contrast

    /// Clips matching the current filter, newest first, capped at
    /// `pageLimit`. The filtering happens in SQLite (see
    /// `ClipFilter.fetchDescriptor`), so this array is small no matter how
    /// large the store is.
    @Query private var items: [ClipItem]

    @Binding private var filter: ClipFilter
    @Binding private var pageLimit: Int
    @ObservedObject private var uiState: PanelUIState
    @ObservedObject private var queue: QueueService
    private let actions: PanelActions

    @AppStorage(SettingsKeys.vimMode) private var vimModeEnabled = false
    @AppStorage(NoteSettingsKeys.previewPaneHeight)
    private var storedPreviewHeight = Double(Design.Size.previewPaneHeight)

    @State private var selection = ClipSelection()
    @State private var inputMode: PanelInputMode = .normal
    @State private var showNukeConfirmation = false
    @State private var pendingDelete: ClipItem?
    @State private var previewVisible = false
    @State private var previewItem: ClipItem?
    @State private var vim = VimNavigator()
    /// Paces the movement keys while one is held down, and says when the
    /// preview pane is allowed to follow — see `HeldKeyPacer`.
    @State private var pacer = HeldKeyPacer()
    /// Bumped by every accepted movement step. The settle task in `body` is
    /// keyed on it, so each step cancels the previous wait and only the clip
    /// the movement ends on reaches the preview pane.
    @State private var previewSettleToken = 0
    /// Cached choices for the source-app menu. Derived from the whole store,
    /// so it is refreshed when the panel opens rather than per render.
    @State private var sourceAppNames: [String] = []
    @FocusState private var searchFocused: Bool

    init(
        filter: Binding<ClipFilter>,
        pageLimit: Binding<Int>,
        uiState: PanelUIState,
        queue: QueueService,
        actions: PanelActions
    ) {
        _filter = filter
        _pageLimit = pageLimit
        self.uiState = uiState
        self.queue = queue
        self.actions = actions
        _items = Query(filter.wrappedValue.fetchDescriptor(limit: pageLimit.wrappedValue))
    }

    // MARK: Derived list state

    /// The fetched page minus the part of the filter SQL could not express.
    ///
    /// Cheap — at most `pageLimit` rows — but still evaluated once per body
    /// pass and threaded down, rather than recomputed at every use site.
    private var visibleItems: [ClipItem] {
        filter.refine(items)
    }

    private var visibleIDs: [UUID] {
        visibleItems.map(\.uuid)
    }

    /// True when the fetch came back full, i.e. the store may hold further
    /// matches beyond the current page.
    private var hasMorePages: Bool {
        items.count >= pageLimit
    }

    /// Row index of the selection, re-derived from the current list on every
    /// render; nil when there is nothing valid to act on.
    private var selectedIndex: Int? {
        selection.index(in: visibleIDs)
    }

    private var selectedItem: ClipItem? {
        guard let index = selectedIndex, visibleItems.indices.contains(index) else { return nil }
        return visibleItems[index]
    }

    /// True while keystrokes should be read as vim commands.
    private var isNormalMode: Bool {
        vimModeEnabled && inputMode.readsVimKeys
    }

    /// The stored preview height, held to what the panel's screen allows.
    private var resolvedPreviewHeight: CGFloat {
        PanelGeometry.clampPreviewHeight(
            CGFloat(storedPreviewHeight),
            ceiling: uiState.maxPreviewHeight
        )
    }

    // MARK: Paging

    /// Widen the page. Called when the user reaches the end of the list, and
    /// when a page came back full but was thinned out by the Swift-side
    /// remainder (a search over a store full of file clips).
    ///
    /// Doubling rather than adding a page keeps the pathological case — a
    /// query that matches nothing in a 50k store — to a handful of fetches.
    private func loadMore() {
        guard hasMorePages else { return }
        pageLimit *= 2
    }

    private func resetPaging() {
        pageLimit = ClipFilter.pageSize
    }

    /// The distinct source apps across the *whole* store, for the footer
    /// menu, found by asking repeatedly for one clip from an app not seen
    /// yet — SwiftData has no `SELECT DISTINCT`.
    ///
    /// One query per distinct app rather than one pass over the store:
    /// measured at 50k clips, 11 ms against 2,182 ms for reading the
    /// attribute off every row (which is what the old computed property did,
    /// on every render). The cap stops a store full of one-off app names
    /// from turning this into a scan.
    private func refreshSourceAppNames() {
        var found: [String?] = []
        while found.count < Self.sourceAppLimit {
            let seen = found
            var descriptor = FetchDescriptor<ClipItem>(
                predicate: #Predicate<ClipItem> { !seen.contains($0.sourceAppName) }
            )
            descriptor.fetchLimit = 1
            descriptor.propertiesToFetch = [\.sourceAppName]
            guard let next = try? modelContext.fetch(descriptor).first else { break }
            found.append(next.sourceAppName)
        }
        sourceAppNames = found
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// How many distinct source apps the footer menu will list.
    private static let sourceAppLimit = 50

    // MARK: Body

    var body: some View {
        // Evaluated once and passed down: the list, the footer count and the
        // scroll sync all read the same array.
        let visible = visibleItems
        return panelKeys(
            VStack(spacing: 0) {
                topBar
                    .frame(height: Design.Size.topBarHeight)
                    .padding(.top, Design.Size.panelTopPadding)
                    .padding(.horizontal, Design.Space.loose)

                cardStrip(visible)

                if previewVisible, let item = previewItem, !item.isDeleted {
                    PreviewResizeHandle(
                        height: resolvedPreviewHeight,
                        ceiling: uiState.maxPreviewHeight
                    ) { height in
                        storedPreviewHeight = Double(height)
                        uiState.previewHeight = height
                    }
                    PreviewView(
                        item: item,
                        onTransform: { actions.applyTransform(item, $0) },
                        onCopy: { actions.copyText(item, $0) }
                    )
                    .frame(height: resolvedPreviewHeight)
                }

                footer(visible)
                    .frame(height: Design.Size.panelFooterHeight)
                    .padding(.horizontal, Design.Space.loose)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // The panel is a slab floating over the desktop: a material, a
            // tint that makes text legible over an arbitrary wallpaper, and a
            // single large continuous corner radius. Not a window.
            .background(Design.Palette.panelOverlay)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
                    .strokeBorder(Design.Palette.hairline, lineWidth: Design.Stroke.hairline)
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            searchFocused = true
            refreshSourceAppNames()
        }
        // The panel window grows upward from its anchored bottom edge to make
        // room for the preview; the controller does the resizing.
        .onChange(of: previewVisible) { uiState.isExpanded = previewVisible }
        // The settle timer behind `refreshPreview(settling:)`. Keying the task
        // on the token is what makes this a debounce rather than a queue of
        // delayed updates: a further step cancels this wait before it can
        // load anything, so only the clip the movement comes to rest on is
        // ever handed to the pane.
        .task(id: previewSettleToken) {
            guard previewSettleToken > 0 else { return }
            try? await Task.sleep(for: .seconds(HeldKeyPacer.previewSettleDelay))
            guard !Task.isCancelled else { return }
            syncPreviewItem()
        }
        .defaultFocus($searchFocused, true)
        .onChange(of: uiState.focusToken) {
            filter = ClipFilter()
            resetPaging()
            selection.clear()
            previewVisible = false
            previewItem = nil
            vim.reset()
            pacer.reset()
            inputMode = .normal
            searchFocused = true
            refreshSourceAppNames()
        }
        .onChange(of: filter) {
            resetPaging()
            selection.clear()
            syncPreviewItem()
        }
        .onChange(of: selection) {
            announceSelection()
        }
        .confirmationDialog(
            "Delete this clip?",
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Delete Clip", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Deleting a clip cannot be undone.")
        }
    }

    /// `dd` is destructive and has no undo, so it routes through the same kind
    /// of confirmation as the footer's nuke-all button.
    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    // MARK: Top bar

    /// One 44-point bar across the top of the panel: a magnifier glyph, the
    /// search field, then the type-filter pills.
    ///
    /// Deck puts the magnifier and the pills on this line and nothing else.
    /// MemoryClip keeps a visible search field there too — it is always focused when
    /// the panel opens, so hiding it behind the glyph would hide the panel's
    /// primary affordance.
    private var topBar: some View {
        HStack(spacing: Design.Space.roomy) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .accessibilityHidden(true)

            panelKeys(
                TextField(searchPlaceholder, text: $filter.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .font(.system(size: Design.Typography.bodySize))
            )
            .frame(width: Design.Size.searchFieldWidth)

            filterChips

            Spacer(minLength: Design.Space.tight)

            if vimModeEnabled {
                modeBadge
            }
        }
    }

    private var searchPlaceholder: String {
        isNormalMode ? "Press / to search" : "Search clips"
    }

    /// Makes the vim mode visible instead of leaving it as invisible state.
    ///
    /// The label colour is deliberately NOT the accent colour: accent-on-tint
    /// is around 3:1 for several system accents, and this is 10-point text.
    private var modeBadge: some View {
        Text(inputMode.badge)
            .font(Design.Typography.keycap)
            .padding(.horizontal, Design.Space.snug)
            .padding(.vertical, Design.Space.hair)
            .background(
                Capsule(style: .continuous).fill(
                    inputMode == .normal
                        ? Color.primary.opacity(0.10)
                        : Design.Palette.accent.opacity(0.28)
                )
            )
            .foregroundStyle(Color(nsColor: inputMode == .normal ? .secondaryLabelColor : .labelColor))
            .accessibilityLabel(inputMode == .normal ? "Normal mode" : "Search mode")
            .help(inputMode == .normal
                  ? "Vim normal mode — press / or i to search"
                  : "Search mode — press Esc for vim navigation")
    }

    // MARK: Quick filters

    /// The content-type filter, promoted out of the footer menu into a row of
    /// chips. Same binding, same six cases — but the current filter is now
    /// visible at rest instead of hidden one click deep, which is the single
    /// biggest legibility win available in this panel.
    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Design.Space.snug) {
                ForEach(TypeFilter.allCases) { typeFilter in
                    filterChip(typeFilter)
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
        // `.contain`, not `.combine`: the chips stay individually reachable
        // and each keeps its own selected trait — they are just grouped
        // under one name.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter by type")
    }

    private func filterChip(_ typeFilter: TypeFilter) -> some View {
        let isOn = filter.type == typeFilter
        return Button {
            filter.type = typeFilter
        } label: {
            HStack(spacing: Design.Space.snug) {
                Circle()
                    .fill(typeFilter.dotColor)
                    .frame(width: Design.Size.chipDot, height: Design.Size.chipDot)
                    .accessibilityHidden(true)
                Text(typeFilter.label)
                    .font(Design.Typography.chip)
            }
            .foregroundStyle(Design.Palette.chipText(isOn: isOn))
            .padding(.horizontal, Design.Space.roomy)
            .padding(.vertical, Design.Space.snug)
            .background(
                Capsule(style: .continuous)
                    .fill(Design.Palette.chipFill(isOn: isOn, increasedContrast: contrast == .increased))
            )
            .overlay(
                Capsule(style: .continuous).strokeBorder(
                    isOn ? Design.Palette.chipSelectedBorder(increasedContrast: contrast == .increased)
                         : Design.Palette.hairline,
                    lineWidth: isOn ? Design.Stroke.selection : Design.Stroke.hairline
                )
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Show only \(typeFilter.label.lowercased())")
        .accessibilityLabel(typeFilter.label)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Key handling

    /// The panel-level key handlers.
    ///
    /// Applied both to the search field and to the outer container, so the
    /// panel still responds when focus is somewhere else (Full Keyboard
    /// Access, a footer menu, VoiceOver). Whichever copy sees the event first
    /// consumes it; the other never fires for the same keystroke.
    private func panelKeys(_ content: some View) -> some View {
        content
            // The strip runs left-to-right, so LEFT/RIGHT are now the natural
            // movement keys. Up/down keep working: they were the panel's only
            // navigation for its whole life, and existing muscle memory (and
            // VimNavigator's `.up`/`.down`) should not be broken by a change
            // of axis.
            // `.repeat` as well as `.down`, so that holding a movement key
            // keeps walking the strip: macOS delivers a held key as a stream
            // of repeat events, and a handler listening only for `.down`
            // never hears them. How fast those repeats are allowed to move
            // the selection is `HeldKeyPacer`'s business, not the system
            // key-repeat slider's.
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                moveSelection(press.key == .downArrow ? 1 : -1, phase: press.phase)
                return .handled
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
                // While there is a query to edit, the arrows belong to the
                // caret — swallowing them would make the search field
                // impossible to correct. With an empty field (the state the
                // panel opens in) they move the selection.
                guard isNormalMode || filter.search.isEmpty else { return .ignored }
                moveSelection(press.key == .rightArrow ? 1 : -1, phase: press.phase)
                return .handled
            }
            .onKeyPress(keys: [.return], phases: .down) { press in
                pasteSelected(plainOnly: press.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(.space, phases: .down) { _ in
                if isNormalMode {
                    escalatePreview()
                    return .handled
                }
                guard !vimModeEnabled, filter.search.isEmpty else { return .ignored }
                escalatePreview()
                return .handled
            }
            .onKeyPress(.escape, phases: .down) { _ in
                handleEscape()
                return .handled
            }
            // Repeats reach this handler so that the vim movement letters can
            // be held like the arrows; `handleVimKey` drops every other key's
            // repeats rather than running its command again.
            .onKeyPress(phases: [.down, .repeat]) { press in
                // The ⌘ shortcuts act on the press alone: a held ⌘1 should
                // paste one clip, not one per repeat event.
                if press.modifiers.contains(.command), !press.phase.contains(.repeat) {
                    if let digit = press.characters.first?.wholeNumberValue,
                       (1...9).contains(digit) {
                        quickPaste(digit)
                        return .handled
                    }
                    // ⌘S rather than a bare letter, because the panel's search
                    // field is live: outside vim normal mode every plain key
                    // belongs to the query. ⌘S is free here — the app owns no
                    // Save menu item, and the Edit menu only claims the
                    // standard ⌘Z/X/C/V/A — and it is the gesture every other
                    // Mac app uses to write the thing in front of you to disk,
                    // which is exactly what this does.
                    if press.characters.lowercased() == "s" {
                        saveSelectedNote()
                        return .handled
                    }
                }
                return handleVimKey(press)
            }
    }

    /// Esc unwinds one layer at a time: pending vim sequence → search mode →
    /// preview → panel.
    private func handleEscape() {
        if vim.hasPending {
            vim.reset()
            return
        }
        if vimModeEnabled, inputMode == .insert {
            setMode(.normal)
            return
        }
        if previewVisible {
            closePreview()
            return
        }
        actions.close()
    }

    // MARK: Card strip

    /// The panel's content: one horizontally scrolling row of square cards.
    ///
    /// This is the layout change. The list used to be a `LazyVStack` inside a
    /// vertical `ScrollView`; it is now a `LazyHStack` inside a horizontal
    /// one, which is what makes the panel read as a deck rather than a menu.
    /// Everything hung off the old list — selection scrolling, the paging
    /// sentinel, the empty states — moved with it and changed axis.
    @ViewBuilder
    private func cardStrip(_ visible: [ClipItem]) -> some View {
        if visible.isEmpty {
            if filter.isIdentity {
                // Nothing filtered anything out, so the store really is empty.
                ContentUnavailableView {
                    Label("No Clips Yet", systemImage: "clipboard")
                } description: {
                    Text("Copy something anywhere in macOS and it will appear here.")
                }
                .frame(maxWidth: .infinity)
                .frame(height: Design.Size.cardStripHeight)
            } else {
                ContentUnavailableView {
                    Label("No Matches", systemImage: "magnifyingglass")
                } description: {
                    Text("Try a different search or filter.")
                }
                .frame(maxWidth: .infinity)
                .frame(height: Design.Size.cardStripHeight)
                // A full page that the Swift-side remainder emptied out (a
                // search over a store dominated by file clips): keep widening
                // rather than claiming there are no matches. Re-runs on every
                // page change, so it converges instead of stopping after one.
                .task(id: pageLimit) { loadMore() }
            }
        } else {
            // Resolved once for the whole strip rather than per card.
            let selected = selection.index(in: visible.map(\.uuid))
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: Design.Size.cardSpace) {
                        ForEach(Array(visible.enumerated()), id: \.element.uuid) { index, item in
                            ClipCardView(
                                item: item,
                                index: index,
                                isSelected: index == selected,
                                queuePosition: queue.position(of: item),
                                onPaste: { plain in actions.paste(item, plain) },
                                onCopyOnly: { actions.copyOnly(item) },
                                onCopyExtractedText: { actions.copyExtractedText(item) },
                                onTransform: { transform in
                                    actions.applyTransform(item, transform)
                                },
                                onShowQR: { actions.showQR(item) },
                                onToggleQueue: { actions.toggleQueue(item) },
                                onSaveNote: { actions.saveNote(item) },
                                onOpenNote: { actions.openNote(item) },
                                onRevealInFinder: { actions.revealInFinder(item) }
                            )
                            .id(item.uuid)
                            .contentShape(Rectangle())
                            .onTapGesture { actions.paste(item, false) }
                        }
                        if hasMorePages {
                            // The paging sentinel, moved from the BOTTOM of
                            // the old vertical list to the TRAILING end of the
                            // strip. It is the last child of the LazyHStack,
                            // so the lazy stack only instantiates it — and
                            // therefore only fires `onAppear` — once the user
                            // has scrolled the strip to its trailing edge.
                            // Same contract as before, one axis over.
                            Color.clear
                                .frame(width: 1, height: 1)
                                // A fresh identity per page, so reaching the
                                // end again after a page has loaded fires
                                // this once more.
                                .id(pageLimit)
                                .onAppear { loadMore() }
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, Design.Space.loose)
                    .padding(.top, Design.Space.normal)
                    .padding(.bottom, Design.Size.cardBottomPadding)
                }
                .scrollIndicators(.never)
                .frame(height: Design.Size.cardStripHeight)
                .onChange(of: selection) {
                    // Re-resolved rather than reusing `selected`: the action
                    // must see the selection it is reacting to.
                    guard let index = selection.index(in: visible.map(\.uuid)),
                          visible.indices.contains(index) else { return }
                    withAnimation(Design.Motion.quick) {
                        // `.center` rather than the default: on a horizontal
                        // axis the leading anchor parks the selected card
                        // against the panel's left edge with its neighbours
                        // off-screen, which loses the sense of a deck.
                        proxy.scrollTo(visible[index].uuid, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private func footer(_ visible: [ClipItem]) -> some View {
        HStack(spacing: Design.Space.normal) {
            // The type filter now lives in the chip row under the search
            // field; the source-app filter stays a menu because it is an
            // open-ended list.
            Menu {
                Picker("Source App", selection: $filter.source) {
                    Text("All Apps").tag(String?.none)
                    ForEach(sourceAppNames, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
            } label: {
                Label(filter.source ?? "All Apps", systemImage: "app.badge")
                    .font(Design.Typography.footnote)
                    .lineLimit(1)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            // Deliberately NOT `.fixedSize()`: a long app name has to be
            // allowed to truncate rather than push the footer's clip count
            // off the panel.
            .layoutPriority(0)

            if uiState.isPaused {
                Label("Capture paused", systemImage: "pause.circle.fill")
                    .font(Design.Typography.footnote)
                    .foregroundStyle(Design.Palette.warning)
                    .lineLimit(1)
            }

            if !queue.isEmpty {
                Button {
                    actions.pasteQueue()
                } label: {
                    Label("Paste \(queue.count)", systemImage: "list.number")
                        .font(Design.Typography.footnote)
                }
                .buttonStyle(.borderless)
                .disabled(queue.isPasting)
                .help("Paste queued clips in order (⇧Q in vim normal mode)")

                Button("Clear") { queue.clear() }
                    .buttonStyle(.borderless)
                    .font(Design.Typography.footnote)
                    .help("Empty the paste queue")
            }

            Spacer(minLength: Design.Space.tight)

            // "200+" rather than a plain count: the list is paged, so the
            // number shown is what has been loaded, not the whole store.
            Text(hasMorePages ? "\(visible.count)+ clips" : "\(visible.count) clips")
                .font(Design.Typography.footnote)
                .monospacedDigit()
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
                .fixedSize()
                .help(hasMorePages
                      ? "Showing the newest \(visible.count) matches — scroll for more"
                      : "All matching clips are shown")

            Button(role: .destructive) {
                showNukeConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: Design.Size.rowActionButton, height: Design.Size.rowActionButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Delete entire history")
        }
        .confirmationDialog(
            "Delete entire clipboard history?",
            isPresented: $showNukeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                // A batch delete, not a loop over `items` — the query only
                // holds the current page, and deleting that would leave the
                // rest of the history behind.
                try? modelContext.delete(model: ClipItem.self)
                try? modelContext.save()
                sourceAppNames = []
            }
        } message: {
            Text("This permanently removes all clips, including pinned ones.")
        }
    }

    // MARK: Accessibility

    private func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }

    /// VoiceOver's cursor stays in the search field while the arrow keys move
    /// the highlight, so the selection has to be spoken explicitly.
    private func announceSelection() {
        guard let index = selectedIndex, let item = selectedItem else { return }
        announce("\(index + 1) of \(visibleItems.count), \(item.announcementSummary)")
    }

    // MARK: Preview

    /// Space escalates rather than toggling.
    ///
    /// The first press opens the preview pane, as it always did. A second
    /// press on a clip Quick Look can show — a screenshot, a file, a pasted
    /// picture — hands it to Quick Look full size, which is the Finder gesture
    /// applied to the clip already in front of you. On a clip Quick Look has
    /// nothing to do with (text, rich text, a colour, a link) the second press
    /// closes the pane, exactly as before. Escape is untouched and still
    /// unwinds pane then panel, so nothing is trapped by the extra rung.
    private func escalatePreview() {
        let target = previewVisible ? previewItem ?? selectedItem : nil
        switch QuickLook.spaceAction(
            previewVisible: previewVisible,
            canQuickLook: target.map { QuickLook.canPreview($0) } ?? false
        ) {
        case .openPreview:
            openPreview()
        case .closePreview:
            closePreview()
        case .openQuickLook:
            guard let target else { return }
            showQuickLook(from: target)
        }
    }

    /// Open the preview pane on the currently selected clip (or the first
    /// visible one when the selection is out of range).
    private func openPreview() {
        guard let item = selectedItem ?? visibleItems.first else { return }
        previewItem = item
        previewVisible = true
        announce("Preview shown, \(item.announcementSummary)")
    }

    /// Hand the panel's whole filtered list to Quick Look, positioned on the
    /// clip the pane is showing.
    ///
    /// The list rather than the one clip, so ← and → walk the history full
    /// size the way arrowing through a Finder folder does. The preview pane
    /// is deliberately left open underneath: Escape closes Quick Look, and a
    /// second Escape then closes the pane, so the way out retraces the way in.
    private func showQuickLook(from item: ClipItem) {
        guard let plan = QuickLook.plan(for: visibleItems, startingAt: item.uuid) else { return }
        announce("Quick Look, \(item.announcementSummary)")
        actions.quickLook(plan.items, plan.index) { uuid in
            // Quick Look leaves the panel on whichever clip the user landed
            // on, not the one they started from. A clip that was deleted or
            // filtered away meanwhile resolves to no row, which the panel
            // already treats as "nothing to act on" rather than falling back
            // to the newest clip.
            selection = ClipSelection(id: uuid)
            syncPreviewItem()
        }
    }

    private func closePreview() {
        guard previewVisible else { return }
        previewVisible = false
        previewItem = nil
        announce("Preview hidden")
    }

    /// Keep the open preview in sync with the selection / visible items.
    ///
    /// When nothing is left to preview the pane is closed outright — leaving
    /// `previewVisible` true with a nil item made the next Space look dead.
    private func syncPreviewItem() {
        guard previewVisible else { return }
        guard let item = selectedItem ?? visibleItems.first else {
            previewVisible = false
            previewItem = nil
            return
        }
        previewItem = item
    }

    // MARK: Vim mode

    private func setMode(_ mode: PanelInputMode) {
        guard inputMode != mode else { return }
        inputMode = mode
        vim.reset()
        if mode == .insert { searchFocused = true }
        announce(mode.announcement)
    }

    /// Route a keystroke through the vim state machine.
    ///
    /// Only active in vim normal mode — an explicit state, not "the search
    /// field happens to be empty". In normal mode every plain character is
    /// consumed (bound or not) so nothing leaks into the search field; in
    /// insert mode nothing is consumed and typing works normally.
    private func handleVimKey(_ press: KeyPress) -> KeyPress.Result {
        guard isNormalMode else { return .ignored }
        // Keys with dedicated handlers above must never be swallowed here.
        guard !Self.reservedCharacters.contains(press.key.character) else { return .ignored }
        guard let key = press.characters.first else { return .ignored }

        // `h`/`l` — vim's horizontal pair — move along the strip, and `j`/`k`
        // keep doing the same thing so the old muscle memory survives the
        // change of axis. Handled here rather than in `VimNavigator` because
        // that type is a shared, separately tested contract; a pending `d`/`g`
        // sequence still gets first refusal, so `dl` aborts as vim expects.
        if !vim.hasPending, !press.modifiers.contains(.control) {
            switch key {
            case "l": perform(.down, phase: press.phase); return .handled
            case "h": perform(.up, phase: press.phase); return .handled
            default: break
            }
        }

        // Past this point a keystroke does something rather than going
        // somewhere: it pastes, pins, deletes, toggles the queue, changes
        // mode. None of that may be driven by auto-repeat — a held `d` would
        // walk a confirmation sheet and a held `o` would paste the same clip
        // twenty times — so a repeat of anything but the movement letters is
        // swallowed here. `j`/`k` fall through to the navigator below, which
        // is where their pacing is decided.
        if press.phase.contains(.repeat), !Self.repeatableCharacters.contains(key) {
            return .handled
        }

        var modifiers: VimModifiers = []
        if press.modifiers.contains(.control) { modifiers.insert(.control) }

        guard let command = vim.command(for: key, modifiers: modifiers) else {
            // Unbound keys and half-typed sequences are consumed too: in
            // normal mode, typing never edits the query.
            return .handled
        }
        perform(command)
        return .handled
    }

    /// Keys owned by the dedicated handlers in `panelKeys`.
    private static let reservedCharacters: Set<Character> = [
        KeyEquivalent.escape.character,
        KeyEquivalent.return.character,
        KeyEquivalent.space.character,
        KeyEquivalent.upArrow.character,
        KeyEquivalent.downArrow.character,
        KeyEquivalent.leftArrow.character,
        KeyEquivalent.rightArrow.character,
        KeyEquivalent.tab.character,
        KeyEquivalent.delete.character
    ]

    /// The vim keys that may be held down.
    ///
    /// Movement only, and the same four the arrows shadow, so that the panel
    /// has one answer to "what happens when I hold this": → and `l` walk the
    /// strip at the same pace, and neither `d` nor `q` walks anywhere.
    private static let repeatableCharacters: Set<Character> = ["h", "j", "k", "l"]

    private func perform(_ command: VimCommand, phase: KeyPress.Phases = .down) {
        switch command {
        case .down, .up, .top, .bottom, .halfPageDown, .halfPageUp:
            let step = pacer.step(isRepeat: phase.contains(.repeat), now: Self.now())
            guard step != .drop else { return }
            let ids = visibleIDs
            let index = VimNavigator.newIndex(
                for: command,
                index: selection.movementOrigin(in: ids),
                count: ids.count
            )
            selection.select(index: index, in: ids)
            refreshPreview(settling: step == .moveSettlingPreview)
        case .paste:
            pasteSelected(plainOnly: false)
        case .pastePlain:
            pasteSelected(plainOnly: true)
        case .pin:
            guard let item = selectedItem else { return }
            item.isPinned.toggle()
            try? modelContext.save()
        case .delete:
            guard let item = selectedItem else { return }
            pendingDelete = item
        case .queueToggle:
            guard let item = selectedItem else { return }
            actions.toggleQueue(item)
            let ids = visibleIDs
            selection.select(
                index: VimNavigator.newIndex(
                    for: .down,
                    index: selection.movementOrigin(in: ids),
                    count: ids.count
                ),
                in: ids
            )
        case .queuePaste:
            guard !queue.isEmpty else { return }
            actions.pasteQueue()
        case .enterSearch:
            filter.search = ""
            setMode(.insert)
        case .enterInsert:
            setMode(.insert)
        case .saveNote:
            saveSelectedNote()
        }
    }

    /// Delete the clip `dd` asked about, once confirmed, and move the
    /// selection to its neighbour by uuid (no index arithmetic that assumes
    /// whether the @Query has refreshed yet).
    private func confirmDelete() {
        guard let item = pendingDelete else { return }
        pendingDelete = nil
        selection.selectNeighbour(of: item.uuid, in: visibleIDs)
        modelContext.delete(item)
        try? modelContext.save()
        if previewItem?.uuid == item.uuid {
            previewItem = nil
        }
        syncPreviewItem()
    }

    // MARK: Selection & paste

    /// Move the selection one step, at the pace `HeldKeyPacer` allows.
    ///
    /// `phase` is the keystroke's phase: a `.down` press always moves, a
    /// `.repeat` from a held key moves only if enough time has passed since
    /// the last step the user saw.
    private func moveSelection(_ delta: Int, phase: KeyPress.Phases = .down) {
        let step = pacer.step(isRepeat: phase.contains(.repeat), now: Self.now())
        guard step != .drop else { return }
        selection.move(by: delta, in: visibleIDs)
        refreshPreview(settling: step == .moveSettlingPreview)
    }

    /// The panel's clock, read in exactly one place so that `HeldKeyPacer`
    /// stays a pure function of the times handed to it and the tests can
    /// drive it without waiting on real ones. Uptime rather than wall time:
    /// it cannot step backwards when the clock is corrected.
    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// Bring the preview pane onto the current selection — now, or once the
    /// movement keys go quiet.
    ///
    /// The pane is expensive per clip: it reads the full-resolution image and
    /// starts an on-device translation, both keyed on the item it is given.
    /// Skimming past forty clips must start neither forty times, so a step
    /// that is part of a run only restarts the settle timer in `body` and
    /// leaves `previewItem` where it was; the clip the run ends on is the one
    /// that loads.
    private func refreshPreview(settling: Bool) {
        previewSettleToken &+= 1
        if !settling { syncPreviewItem() }
    }

    /// Paste the selected clip. Does nothing when the selection no longer
    /// exists — falling back to row 0 would paste the newest clip instead.
    private func pasteSelected(plainOnly: Bool) {
        guard let item = selectedItem else { return }
        actions.paste(item, plainOnly)
    }

    /// Write (or rewrite) the selected clip's note.
    ///
    /// Gated on the same predicate as the card's context-menu item, so the
    /// key and the menu agree about which clips can be noted. The menu hides
    /// the item for the rest; a key has nothing to hide, so a colour swatch
    /// or a screenshot Vision could not read simply does nothing — better
    /// than starting an export that can only end in a failure alert.
    private func saveSelectedNote() {
        guard let item = selectedItem, ClipDisplay.canSaveNote(item) else { return }
        actions.saveNote(item)
    }

    private func quickPaste(_ digit: Int) {
        let visible = visibleItems
        guard digit >= 1, digit <= visible.count else { return }
        actions.paste(visible[digit - 1], false)
    }
}

/// The divider between the card strip and the preview pane, as a drag target:
/// up makes the pane taller, down shorter.
///
/// Its own view so hover and drag state do not re-render the panel around it.
private struct PreviewResizeHandle: View {
    let height: CGFloat
    let ceiling: CGFloat
    let onResize: (CGFloat) -> Void

    /// The height the current drag started from; nil between drags.
    @State private var startHeight: CGFloat?
    /// The pointer's screen y when the drag started; nil between drags.
    @State private var startPointerY: CGFloat?
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Divider().opacity(0.5)
            Capsule(style: .continuous)
                .fill(Color(nsColor: .tertiaryLabelColor))
                .frame(width: Design.Size.previewResizeGripWidth, height: Design.Space.hair)
                .opacity(isHovering ? 1 : 0.6)
        }
        .frame(height: Design.Size.previewResizeHandleHeight)
        .contentShape(Rectangle())
        .onHover { hovering in
            guard hovering != isHovering else { return }
            isHovering = hovering
            hovering ? NSCursor.resizeUpDown.push() : NSCursor.pop()
        }
        .onDisappear {
            guard isHovering else { return }
            isHovering = false
            NSCursor.pop()
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                // Measured from the pointer's screen position, not the
                // gesture's translation: the handle moves as the pane resizes,
                // so a view-relative translation feeds its own result back in
                // and the drag oscillates.
                .onChanged { _ in
                    let start = startHeight ?? height
                    let anchor = startPointerY ?? NSEvent.mouseLocation.y
                    startHeight = start
                    startPointerY = anchor
                    onResize(PanelGeometry.clampPreviewHeight(
                        start + (NSEvent.mouseLocation.y - anchor),
                        ceiling: ceiling
                    ))
                }
                .onEnded { _ in
                    startHeight = nil
                    startPointerY = nil
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Preview height")
        .accessibilityValue("\(Int(height)) points")
        .accessibilityHint("Drag up for a taller preview")
        .accessibilityAdjustableAction { direction in
            let step = Design.Space.vast
            let target = direction == .increment ? height + step : height - step
            onResize(PanelGeometry.clampPreviewHeight(target, ceiling: ceiling))
        }
    }
}
