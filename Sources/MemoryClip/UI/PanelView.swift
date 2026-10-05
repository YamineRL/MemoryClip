import AppKit
import NaturalLanguage
import SwiftUI
import SwiftData

/// Content-type filter chips for the panel search row.
enum TypeFilter: String, CaseIterable, Identifiable {
    case all, text, image, link, file, color

    var id: String { rawValue }

    /// Human-readable label for menus and chips.
    var label: String {
        switch self {
        case .all: return loc("All")
        case .text: return loc("Text")
        case .image: return loc("Images")
        case .link: return loc("Links")
        case .file: return loc("Files")
        case .color: return loc("Colors")
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

    /// Whether a clip belongs under this chip.
    ///
    /// A screenshot is stored as a `.file` clip, because that is what it is:
    /// a file on disk, which is why pasting one pastes the file and Reveal in
    /// Finder can find it. It is a *picture* to the person who took it,
    /// though, and someone filtering Images and not seeing their screenshots
    /// has been told something false about their own history. So the two
    /// chips read `isScreenshot` rather than the kind alone: screenshots are
    /// images here, and Files is what is left — the documents dragged or
    /// copied in Finder, which is what anyone picking that chip is after.
    func matches(_ kind: ClipKind, isScreenshot: Bool = false) -> Bool {
        switch self {
        case .all: return true
        case .text: return kind == .text || kind == .richText
        case .image: return kind == .image || isScreenshot
        case .link: return kind == .link
        case .file: return kind == .file && !isScreenshot
        case .color: return kind == .color
        }
    }

    /// The clip kinds this chip admits *in SQL*, or nil for "everything".
    ///
    /// Wider than `matches` for Images, and only there: a screenshot's row
    /// says `file`, so the fetch has to admit file rows and let `refine(_:)`
    /// drop the ones that are not screenshots. The predicate cannot do that
    /// narrowing itself — every clause added to it costs type-checking time
    /// the expression does not have (see `ClipFilter.predicate`) — and the
    /// panel already re-checks and re-pages the remainder in Swift.
    var kinds: Set<ClipKind>? {
        switch self {
        case .all:
            return nil
        case .text:
            // Rich text is text as far as the filter is concerned; links are
            // deliberately *not* folded in (they have their own chip).
            return [.text, .richText]
        case .image:
            return [.image, .file]
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

/// Which pinned subset the panel is scoped to (PRD 06).
///
/// `.all` is every clip; boards narrow nothing. `.pinned` is the board-less
/// pins, the set the old flat "pinned" list was and the place a clip lands
/// when it is filed to no board. `.board` is one pinboard's contents in its
/// manual order.
enum PinboardScope: Equatable {
    case all
    case pinned
    case board(UUID)

    /// Whether the scope is a single board. That case switches the list to
    /// the board's manual order, which SQLite cannot express (the order is a
    /// `Double?` midpoints renumber only when they collide), so the fetch
    /// runs unbounded and `refine(_:)` sorts what it gets. A board is a
    /// curated set, small by definition; the unbounded fetch is bounded by
    /// design.
    var isBoardScoped: Bool {
        if case .board = self { return true }
        return false
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
    /// `is:pinned` reads it; `-is:pinned` is the one state clause the SQL
    /// predicate can also carry, since it is a stored Bool. The pinboard
    /// scopes (PRD 06) read the same flag.
    var isPinned: Bool { get }
    /// `is:noted` reads it: a clip has a note exactly when `notePath` was
    /// filled in.
    var notePath: String? { get }
    /// `is:event` reads it.
    var calendarEventID: String? { get }
    /// `after:`/`before:`/`on:` filter on it.
    var createdAt: Date { get }
    /// The local model's title for the clip, when one was produced.
    var refinedTitle: String? { get }
    /// The local model's cleaned-up version of `ocrText`, when one was
    /// produced.
    var refinedText: String? { get }
    /// The local model's one- or two-sentence summary of the clip.
    var refinedSummary: String? { get }
    /// The topic tags the local model suggested for the clip.
    var refinedTags: [String] { get }
    /// `ocrText` rendered into English by the on-device translator, for a
    /// clip that arrived in another language.
    var translatedText: String? { get }
    /// The preview pane's own translation, into whatever language this Mac
    /// reads rather than into English.
    var clipTranslationText: String? { get }
    /// Whether this file clip is a screenshot picked up from the screenshot
    /// folder.
    var isScreenshot: Bool { get }
    /// Whether the row is a sealed secret. Its plaintext fields are nil by
    /// construction, so a filter asking about `text` never finds it — only
    /// the label and mask below are searchable.
    var isSecret: Bool { get }
    /// The detector's fixed catalogue label ("AWS access key"). Storing the
    /// English string is what makes `aws` find the clip in SQL without the
    /// row holding any plaintext.
    var secretLabel: String? { get }
    /// The stored mask ("AKIA••••••••••••7Q2X"): the only plaintext-derived
    /// characters a secret row keeps.
    var secretMasked: String? { get }
    /// When a one-time code is deleted; nil for anything else.
    var expiresAt: Date? { get }
    /// The pinboard the clip is filed in, by identifier (PRD 06).
    var pinboardUUID: UUID? { get }
    /// The clip's spot in its board's manual order, when filed.
    var pinboardOrder: Double? { get }
}

extension ClipItem: ClipDisplayable {}

extension ClipDisplayable {
    // Defaults for the properties above, so the test doubles that conform to
    // this protocol (and predate the note pipeline) keep compiling.
    // `ClipItem`'s stored properties satisfy the requirements directly and
    // shadow these.
    var refinedTitle: String? { nil }
    var refinedText: String? { nil }
    var refinedSummary: String? { nil }
    var refinedTags: [String] { [] }
    var translatedText: String? { nil }
    var clipTranslationText: String? { nil }
    var isScreenshot: Bool { false }
    var isSecret: Bool { false }
    var secretLabel: String? { nil }
    var secretMasked: String? { nil }
    var expiresAt: Date? { nil }

    // Board scope defaults (PRD 06): `ClipItem` witnesses the real values
    // the stored `isPinned` and `pinboardOrder`, and `pinboardUUID` derived
    // from the relationship, while a test double that never boards a clip
    // reads as unpinned and unfiled.
    var isPinned: Bool { false }
    var pinboardUUID: UUID? { nil }
    var pinboardOrder: Double? { nil }
    var notePath: String? { nil }
    var calendarEventID: String? { nil }
    /// A double that never set it is old rather than undated: a date
    /// operator excludes it, which is what "no date known" means.
    var createdAt: Date { .distantPast }

    /// One-line description used for VoiceOver announcements.
    var announcementSummary: String {
        // A secret row says what it is, never what it holds: the label is a
        // catalogue string, and the mask's bullets speak as noise.
        if isSecret {
            let name = secretLabel.flatMap { $0.isEmpty ? nil : loc($0) } ?? loc("Token")
            return loc("Secret, %@", name)
        }
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
            raw = colorHex ?? loc("colour")
        case .image:
            let ocr = ocrText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            raw = ocr.isEmpty ? loc("image") : loc("image, %@", ocr)
        default:
            raw = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return loc("empty clip") }
        return collapsed.count > 80 ? String(collapsed.prefix(80)) + "…" : collapsed
    }
}

/// What was typed into the search box, read as terms rather than as one
/// string.
///
/// People type sentences at a search box — "that error about the deploy
/// failing" — and testing that whole string as a substring finds nothing,
/// because no clip contains the sentence. The words are what was meant, and
/// the clip carrying all of them is the one being looked for. So the string
/// is split, the words that carry no signal are dropped, and what is left is
/// required together.
///
/// Each word is then reduced to what it shares with its lemma, which is what
/// lets "failing" find "failed" and "copiés" find "copier". The shared prefix
/// rather than the lemma itself: a lemma can be a different word ("ran" →
/// "run", "mice" → "mouse"), and searching for that in place of what was
/// typed would lose the clips holding the typed form. A prefix can only widen
/// the search — whatever contains the word contains the prefix — and that is
/// the property `ClipFilter.predicate` leans on to push one term into SQL.
///
/// Split on whitespace and nothing finer. `%20` stays one term rather than
/// becoming a `20` that finds every clip from 2026, and `#FF00AA` stays a
/// colour rather than a hex fragment.
struct ClipQuery: Equatable {
    /// The terms a clip has to carry, all of them. Empty when nothing has
    /// been typed, or when the query is operators alone.
    let terms: [String]

    /// The `key:value` operators, resolved into bounds - see
    /// `SearchOperators.swift` for the grammar they were read with.
    let constraints: ClipConstraints

    /// Every operator-shaped span of the query, valid or not, for the
    /// search field's pill styling and the empty state's "Clear filters".
    let operatorTokens: [SearchOperatorToken]

    /// `now` and `calendar` are what `after:7d` and `on:today` resolve
    /// against. Injecting them keeps date parsing testable and freezes a
    /// relative bound at the moment the query was typed instead of letting
    /// it slide while the user edits.
    init(_ search: String, now: Date = .now, calendar: Calendar = .current) {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            terms = []
            constraints = ClipConstraints()
            operatorTokens = []
            return
        }
        var constraints = ClipConstraints()
        var operators: [SearchOperatorToken] = []
        var words: [Substring] = []
        for token in ClipQuery.scan(trimmed) {
            if let key = token.key, let value = token.value, let head = token.head {
                // An operator with a value its key does not know contributes
                // nothing - the token is kept for styling, not narrowed on.
                let known = constraints.apply(
                    key, value: value, negated: token.negated, now: now, calendar: calendar
                )
                operators.append(SearchOperatorToken(
                    range: token.range, head: head, key: key, value: value,
                    negated: token.negated, valueIsKnown: known
                ))
            } else {
                words.append(trimmed[token.range])
            }
        }
        let parsed = ClipQuery.parse(words)
        self.constraints = constraints
        operatorTokens = operators
        // A query that is nothing but stop words is a query for those words:
        // someone who types "the" and nothing else means the letters, not
        // "show me everything". The fallback only fires when there were no
        // operators either - `is:pinned` alone means exactly that.
        terms = parsed.isEmpty && operators.isEmpty ? [trimmed] : parsed
    }

    /// The one term the SQL predicate narrows on: the longest, and so the
    /// most selective of them.
    var narrowing: String { terms.max { $0.count < $1.count } ?? "" }

    /// Words that carry no signal in a clipboard search, in the two languages
    /// the app speaks. Dropped so that the sentence built around the words
    /// that matter does not have to appear in the clip as well.
    private static let stopWords: Set<String> = [
        "a", "about", "all", "an", "and", "any", "are", "as", "at", "be", "been", "but", "by",
        "for", "from", "had", "has", "have", "i", "in", "into", "is", "it", "its", "me", "my",
        "of", "on", "or", "so", "some", "that", "the", "their", "them", "then", "there", "these",
        "they", "this", "to", "was", "were", "what", "when", "which", "with", "you", "your",
        "à", "au", "aux", "avec", "ce", "ces", "cet", "cette", "dans", "de", "des", "du", "elle",
        "en", "est", "et", "il", "ils", "je", "la", "le", "les", "ma", "mes", "mon", "ne", "par",
        "pas", "pour", "que", "qui", "sa", "se", "ses", "son", "sont", "sur", "un", "une"
    ]

    /// The scanned words, minus the stop words, each reduced to its stem.
    /// `words` are the non-operator tokens of the query, rejoined for the
    /// tagger: left in place they keep their operators as sentence context,
    /// which changes what the tagger reads ("deploy failing is:pinned"
    /// lemmatizes "failing" to itself, a gerund ahead of "is"), and operator
    /// text has no lemma worth knowing anyway.
    private static func parse(_ words: [Substring]) -> [String] {
        // Operators alone leave no words to stem - and no reason to build a
        // tagger, which costs a millisecond for nothing.
        guard !words.isEmpty else { return [] }
        var joined = ""
        var wordRanges: [Range<String.Index>] = []
        for word in words {
            if !joined.isEmpty { joined.append(" ") }
            let start = joined.endIndex
            joined.append(contentsOf: word)
            wordRanges.append(start..<joined.endIndex)
        }
        var lemmas: [Range<String.Index>: String] = [:]
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = joined
        tagger.enumerateTags(
            in: joined.startIndex..<joined.endIndex,
            unit: .word,
            scheme: .lemma,
            options: [.omitPunctuation, .omitWhitespace]
        ) { tag, range in
            if let lemma = tag?.rawValue, !lemma.isEmpty { lemmas[range] = lemma }
            return true
        }
        return zip(words, wordRanges).compactMap { word, range in
            guard !stopWords.contains(word.lowercased()) else { return nil }
            // Only a word the tagger read whole has a lemma to offer. A term
            // it read in pieces — `hello.example`, `%20` — is taken as typed,
            // which is the same thing as having no lemma for it.
            return stem(String(word), lemma: lemmas[range])
        }
    }

    /// A word cut back to what it and its lemma agree on.
    ///
    /// Below three characters there is nothing left worth searching for and
    /// the word stands as typed — which is also what happens to an irregular
    /// form, whose lemma shares no useful prefix with it.
    private static func stem(_ word: String, lemma: String?) -> String {
        guard let lemma else { return word }
        let shared = word.commonPrefix(with: lemma, options: [.caseInsensitive, .diacriticInsensitive])
        return shared.count >= 3 && shared.count < word.count ? shared : word
    }
}

/// The panel's filters (search text, content type, operators) as one value.
/// Pure: no SwiftUI, no model context.
struct ClipFilter: Equatable {
    var search: String = "" {
        didSet { query = ClipQuery(search, now: now, calendar: calendar) }
    }

    var type: TypeFilter = .all
    /// The pinned subset the panel is scoped to (PRD 06).
    var board: PinboardScope = .all
    /// The store's pinboards as `(name, uuid)` pairs: what `in:` resolves
    /// board-name prefixes against. Fed by the panel's `pinboards` query;
    /// empty in a context that never showed boards, where every `in:`
    /// except `in:pinned` simply matches nothing.
    var boardIndex: [(name: String, uuid: UUID)] = []

    /// The instant and calendar the query's `after:`/`before:`/`on:` values
    /// resolve against - what `ClipQuery.init` documents. Readable so the
    /// panel can hand the same resolution to the suggestion details.
    let now: Date
    let calendar: Calendar

    /// `search`, parsed. Held rather than derived on demand: the panel
    /// rebuilds this filter on every keystroke and then matches it against a
    /// whole page of clips, so the tagger runs once per edit (0.3 ms) instead
    /// of once per row.
    private(set) var query: ClipQuery

    init(
        search: String = "",
        type: TypeFilter = .all,
        source: String? = nil,
        board: PinboardScope = .all,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        self.search = search
        self.type = type
        self.board = board
        self.now = now
        self.calendar = calendar
        query = ClipQuery(search, now: now, calendar: calendar)
        // Set after the rest so the setter's `search` rewrite lands on a
        // fully initialised filter - and only when a source was asked for,
        // since nil means "leave whatever the query typed alone".
        if let source { self.source = source }
    }

    /// Two filters are the same filter when they would produce the same
    /// list: `now`/`calendar` are the clock `after:7d` was resolved against,
    /// not part of what was asked.
    static func == (lhs: ClipFilter, rhs: ClipFilter) -> Bool {
        lhs.search == rhs.search && lhs.type == rhs.type
            && lhs.board == rhs.board && lhs.query == rhs.query
            && lhs.boardIndex.map(\.uuid) == rhs.boardIndex.map(\.uuid)
            && lhs.boardIndex.map(\.name) == rhs.boardIndex.map(\.name)
    }

    /// The source-app constraint the footer menu binds to.
    ///
    /// `app:` and the menu are one code path: writing this rewrites the
    /// query's `app:` token - picking "Safari" is the same constraint as
    /// typing `app:Safari` - and reading it reports back whatever the query
    /// constrains to, so a typed `app:saf` shows in the menu too.
    var source: String? {
        get {
            let apps = query.constraints.apps
            return apps.count == 1 ? apps[0] : nil
        }
        set {
            search = ClipQuery.settingApp(newValue, in: search)
        }
    }

    /// True when nothing is being narrowed down.
    var isIdentity: Bool {
        search.isEmpty && type == .all && board == .all
    }

    /// The active constraints in words - "from Slack, before 1 September" -
    /// for the empty state's "No clips …" sentence. Nil when only words are
    /// filtering, which keeps the generic "No Matches" copy for them.
    var constraintSummary: String? {
        var parts: [String] = []
        // The words as typed rather than their stems: the sentence is for
        // reading, and "matching \"fail\"" is a worse echo of "failing".
        let words = ClipQuery.clearingOperators(from: search)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty {
            parts.append(loc("matching \"%@\"", words))
        }
        parts += query.constraints.phrases
        if type != .all { parts.append(type.phrase) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Whether a clip survives the board scope alone. `nil` board membership
    /// answers `.pinned`, the matching identifier answers `.board`; `.all`
    /// asks nothing.
    func matchesBoard(_ item: some ClipDisplayable) -> Bool {
        switch board {
        case .all: return true
        case .pinned: return item.isPinned && item.pinboardUUID == nil
        case .board(let uuid): return item.pinboardUUID == uuid
        }
    }

    /// Whether `refine(_:)` can still drop rows the predicate returned.
    ///
    /// The two places the predicate is deliberately wider than the filter:
    /// Images admits every file row in order to reach the screenshots among
    /// them, and a search admits every file row — their searchable content
    /// is a blob SQL cannot look inside — as well as clips carrying only the
    /// one term of a multi-word query that the expression had room for.
    /// Everywhere else the predicate is the whole question, and a COUNT of
    /// it is the answer.
    var needsSwiftSideRefinement: Bool { type == .image || !query.terms.isEmpty }

    func matchesType(_ item: some ClipDisplayable) -> Bool {
        type.matches(item.kind, isScreenshot: item.isScreenshot)
    }

    /// Whether the clip's source app satisfies the `app:` operators - the
    /// one code path the footer menu and a typed `app:saf` share.
    /// `matchesConstraints(_:)` asks the same question as part of the whole
    /// constraint set; this is the single-aspect form the tests pin.
    func matchesSource(_ item: some ClipDisplayable) -> Bool {
        let constraints = query.constraints
        return constraints.apps
            .allSatisfy { ClipConstraints.hasAppPrefix(item.sourceAppName, $0) }
            && constraints.notApps
                .allSatisfy { !ClipConstraints.hasAppPrefix(item.sourceAppName, $0) }
    }

    /// Whether the clip satisfies every `key:value` constraint.
    func matchesConstraints(_ item: some ClipDisplayable) -> Bool {
        query.constraints.matches(item, boards: boardIndex)
    }

    /// Whether a clip carries every term of the query.
    ///
    /// AND across the terms, OR across the fields: the words are allowed to
    /// be spread over the text, the model's summary of it and the app it came
    /// from, which is how "invoice safari" finds the invoice copied out of
    /// Safari.
    func matchesSearch(_ item: some ClipDisplayable) -> Bool {
        guard !query.terms.isEmpty else { return true }
        return query.terms.allSatisfy { carries(item, $0) }
    }

    /// Every place one term can be found in a clip.
    ///
    /// Note the asymmetry with `predicate` below, which carries only `text`,
    /// `ocrText`, `colorHex` and `sourceAppName`: that expression is at the
    /// documented limit of what the Swift type checker will compile in
    /// reasonable time, and the clips the rest of these matter for —
    /// screenshots, which are `.file` kind — are admitted by the predicate
    /// wholesale and re-checked here by `refine(_:)` regardless. The cost is
    /// that a pasteboard IMAGE clip is not searchable by a word that appears
    /// only in what the local model made of it, which is close to no cost at
    /// all: all of that is derived from `ocrText`, and that is indexed.
    private func carries(_ item: some ClipDisplayable, _ term: String) -> Bool {
        if item.text?.localizedStandardContains(term) == true { return true }
        // Image clips are searchable through their extracted text…
        if item.ocrText?.localizedStandardContains(term) == true { return true }
        // …and through everything the local model made of it: the tidied
        // text, the title, the summary, the tags, and the English rendering
        // of a screenshot that was not in English. That is a second telling
        // of the clip in other words — already written, already stored — and
        // it is what lets a clip be found by a word that was never on the
        // screen it came from.
        if item.refinedText?.localizedStandardContains(term) == true { return true }
        if item.refinedTitle?.localizedStandardContains(term) == true { return true }
        if item.refinedSummary?.localizedStandardContains(term) == true { return true }
        if item.translatedText?.localizedStandardContains(term) == true { return true }
        if item.clipTranslationText?.localizedStandardContains(term) == true { return true }
        if item.refinedTags.contains(where: { $0.localizedStandardContains(term) }) { return true }
        if item.colorHex?.localizedStandardContains(term) == true { return true }
        if ClipDisplay.fileURLsMatch(item.fileURLStrings, search: term) { return true }
        // A secret is findable by its label and mask — "aws", "token", the
        // vendor prefix it shows — never by its content, which no field on
        // the row holds.
        if item.secretLabel?.localizedStandardContains(term) == true { return true }
        if item.secretMasked?.localizedStandardContains(term) == true { return true }
        if item.sourceAppName?.localizedStandardContains(term) == true { return true }
        return false
    }

    func matches(_ item: some ClipDisplayable) -> Bool {
        matchesBoard(item) && matchesType(item) && matchesConstraints(item) && matchesSearch(item)
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

/// `item[keyPath:] == value` for a stored Bool — `is:pinned`, the pinboard
/// scope's pin test and the search clause's secret admission all emit their
/// flag through this.
private func clipFlag(
    _ item: ClipVariable,
    _ keyPath: any KeyPath<ClipItem, Bool> & Sendable,
    _ value: Bool
) -> some StandardPredicateExpression<Bool> {
    PredicateExpressions.build_Equal(
        lhs: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg(item), keyPath: keyPath),
        rhs: PredicateExpressions.build_Arg(value)
    )
}

/// `item[keyPath:] <op> value` - `after:`/`before:`'s `createdAt` bounds.
private func clipCompare(
    _ item: ClipVariable,
    _ keyPath: any KeyPath<ClipItem, Date> & Sendable,
    _ op: PredicateExpressions.ComparisonOperator,
    _ value: Date
) -> some StandardPredicateExpression<Bool> {
    PredicateExpressions.build_Comparison(
        lhs: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg(item), keyPath: keyPath),
        rhs: PredicateExpressions.build_Arg(value),
        op: op
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

/// The free-text clause of `ClipFilter.predicate`: everything but the
/// constant guard is skipped when no words are typed.
private func clipSearch(
    _ item: ClipVariable,
    searching: Bool,
    needle: String,
    fileKind: [String]
) -> some StandardPredicateExpression<Bool> {
    clipOr(
        clipConstant(!searching),
        clipOr(
            clipOr(
                // File clips carry their searchable content in
                // `fileURLStrings`, which SwiftData stores as one opaque
                // blob; they are admitted here and sifted by `refine(_:)`.
                // Secret rows likewise: their searchable part is the
                // label/mask pair `refine` checks — their `text` is nil
                // by construction.
                clipOr(
                    clipOneOf(item, \.kindRaw, fileKind),
                    clipFlag(item, \.isSecret, true)
                ),
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

    /// The panel's query: type (chip and `type:` together), the first `app:`
    /// prefix, `is:pinned`, the `createdAt` bounds and (most of) search
    /// pushed into SQLite, newest first, capped at `limit` rows.
    ///
    /// What is *not* expressible here is the file-path search: SwiftData
    /// stores `fileURLStrings` as one opaque blob, so no predicate can look
    /// inside it. File clips are therefore let through the search clause
    /// wholesale and re-checked in Swift by `refine(_:)` — a Swift-side pass
    /// over at most `limit` rows instead of the whole store. Everything else
    /// `refine(_:)` re-checks is in `predicate`'s doc: the anchored `app:`
    /// prefix rule, and the states and exclusions no column answers.
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
        // A board scope fetches unbounded: the manual order is a `Double?`
        // of midpoints Swift-side, which no SortDescriptor can express, so
        // `refine(_:)` gets every member to sort. `in:` widens for the same
        // reason - a board is a curated set, small by definition, and a
        // page of 200 could clip it.
        descriptor.fetchLimit = (board.isBoardScoped || !query.constraints.boards.isEmpty) ? nil : limit
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
    ///
    /// A multi-word query puts only ONE of its terms in here — the longest,
    /// and so the most selective — for the same reason: a term is four more
    /// clauses, and the expression has no room for them. That is a widening
    /// and never a narrowing, so nothing findable is lost. A clip carrying
    /// every term carries that one, so the fetch returns a superset of the
    /// answer and `refine(_:)` asks the rest of the question over the page.
    ///
    /// The same superset rule decides where each operator lives. Into SQL:
    /// `type:` (folded into the kind set the chips already feed), one `app:`
    /// value as a CONTAINS that the anchored prefix rule narrows from, the
    /// `createdAt` bounds of `after:`/`before:`/`on:` and `-on:`'s inverse,
    /// and `isPinned` for either sign of `is:pinned` - all exact or strictly
    /// widening over stored columns. Left for `refine(_:)`: the second and
    /// later `app:` prefixes, every `-app:`, the prefix anchor itself, the
    /// `is:` states that are nil-checks, every `-on:` day, and the semantic
    /// difference between `type:image` (a file row that is a screenshot) and
    /// `type:file` - all of which are cheap over one bounded page and
    /// impossible or clause-hungry in SQL.
    /// The clip kinds the fetch may return: the chip and every `type:`
    /// constraint folded into one set of `kindRaw` values, since both name
    /// the same column. `nil` is unrestricted; empty means the constraints
    /// contradict each other - `type:text` with the Images chip, or
    /// `-type:text -type:image -type:link -type:file -type:color` - and the
    /// predicate is written to return nothing rather than widen into all.
    private var effectiveKindRaws: (all: Bool, raws: [String]) {
        var allowed: Set<ClipKind> = Set(ClipKind.allCases)
        if let chip = type.kinds { allowed.formIntersection(chip) }
        for constraint in query.constraints.types {
            allowed.formIntersection(constraint.kinds ?? Set(ClipKind.allCases))
        }
        for constraint in query.constraints.notTypes {
            // Only a kind the constraint rejects either way may leave the
            // SQL set: `-type:file` still owes the fetch the screenshot
            // rows, which `matches` keeps and `refine(_:)` alone can tell
            // apart from the other files.
            allowed.subtract(
                (constraint.kinds ?? []).filter {
                    constraint.matches($0, isScreenshot: true)
                        && constraint.matches($0, isScreenshot: false)
                }
            )
        }
        return (allowed.count == ClipKind.allCases.count,
                allowed.map(\.rawValue).sorted())
    }

    var predicate: Predicate<ClipItem> {
        let needle = query.narrowing
        let searching = !query.terms.isEmpty
        let constraints = query.constraints
        // `app:`'s real rule is an anchored prefix. SQL has no case-folding
        // anchored form (`starts(with:)` compares case-sensitively, which
        // would drop `Safari` for `app:saf`), so the predicate widens to a
        // case-folding CONTAINS and `refine(_:)` re-anchors it over the
        // rows it got back.
        // Only the first value is pushed: a match satisfies them all, so
        // the fetch stays a superset, and each extra clause is one the
        // expression does not have room for.
        let appNeedle = constraints.apps.first ?? ""
        let anyApp = constraints.apps.isEmpty
        // Date bounds and `is:pinned` are exact: they read stored columns.
        let after = constraints.after
        let before = constraints.before
        let pinned: Bool? = constraints.states.contains(.pinned) ? true
            : constraints.notStates.contains(.pinned) ? false : nil
        let secret: Bool? = constraints.states.contains(.secret) ? true
            : constraints.notStates.contains(.secret) ? false : nil
        let kinds = effectiveKindRaws
        let fileKind = [ClipKind.file.rawValue]
        // Both pinned scopes (Pinned proper and a board) are subsets of
        // `isPinned`, which SQL CAN ask about. Which subset is the Swift-side
        // `refine(_:)`'s question: `pinboard == nil` is a relationship test
        // no predicate can express.
        let anyScope = board == .all

        // A contradiction between the chip and `type:` means nothing can
        // match - the predicate says so outright instead of shipping a
        // tautology that `refine(_:)` would still empty.
        guard !kinds.raws.isEmpty || kinds.all else {
            return Predicate<ClipItem> { _ in clipConstant(false) }
        }

        // The common case - chips, the app menu and plain words, with no
        // date or pin operator in play - keeps the shape the filter has
        // always had rather than paying three constant-ORs per row for
        // clauses that are never set.
        if after == nil, before == nil, pinned == nil, secret == nil {
            if !searching {
                // Nothing typed, only the chip, the menu and the scope:
                // bare intersections, with no constant OR to pay per row.
                if anyScope {
                    if kinds.all, anyApp {
                        return Predicate<ClipItem> { _ in clipConstant(true) }
                    }
                    if anyApp {
                        return Predicate<ClipItem> { item in
                            clipOr(clipConstant(kinds.all), clipOneOf(item, \.kindRaw, kinds.raws))
                        }
                    }
                    if kinds.all {
                        return Predicate<ClipItem> { item in
                            clipContains(item, \.sourceAppName, appNeedle)
                        }
                    }
                    return Predicate<ClipItem> { item in
                        clipAnd(
                            clipOneOf(item, \.kindRaw, kinds.raws),
                            clipContains(item, \.sourceAppName, appNeedle)
                        )
                    }
                }
                // A pinned scope adds its flag test to the chip and menu.
                return Predicate<ClipItem> { item in
                    clipAnd(
                        clipAnd(
                            clipOr(clipConstant(kinds.all), clipOneOf(item, \.kindRaw, kinds.raws)),
                            clipOr(clipConstant(anyApp), clipContains(item, \.sourceAppName, appNeedle))
                        ),
                        clipFlag(item, \.isPinned, true)
                    )
                }
            }
            return Predicate<ClipItem> { item in
                clipAnd(
                    clipAnd(
                        clipOr(clipConstant(kinds.all), clipOneOf(item, \.kindRaw, kinds.raws)),
                        clipOr(clipConstant(anyApp), clipContains(item, \.sourceAppName, appNeedle))
                    ),
                    clipAnd(
                        clipOr(clipConstant(anyScope), clipFlag(item, \.isPinned, true)),
                        clipSearch(item, searching: searching, needle: needle, fileKind: fileKind)
                    )
                )
            }
        }
        return Predicate<ClipItem> { item in
            clipAnd(
                clipAnd(
                    clipAnd(
                        clipOr(clipConstant(kinds.all), clipOneOf(item, \.kindRaw, kinds.raws)),
                        clipOr(clipConstant(anyApp), clipContains(item, \.sourceAppName, appNeedle))
                    ),
                    clipOr(clipConstant(anyScope), clipFlag(item, \.isPinned, true))
                ),
                clipAnd(
                    clipAnd(
                        clipOr(
                            clipConstant(after == nil),
                            clipCompare(item, \.createdAt, .greaterThanOrEqual, after ?? .distantPast)
                        ),
                        clipOr(
                            clipConstant(before == nil),
                            clipCompare(item, \.createdAt, .lessThan, before ?? .distantPast)
                        )
                    ),
                    clipAnd(
                        clipAnd(
                            clipOr(
                                clipConstant(pinned == nil),
                                clipFlag(item, \.isPinned, pinned ?? false)
                            ),
                            clipOr(
                                clipConstant(secret == nil),
                                clipFlag(item, \.isSecret, secret ?? false)
                            )
                        ),
                        clipSearch(item, searching: searching, needle: needle, fileKind: fileKind)
                    )
                )
            )
        }
    }

    /// The part of the filter the predicate could not express, applied to
    /// rows the predicate already returned.
    ///
    /// What SQL waved through: the type, because Images admits file rows in
    /// order to reach the screenshots among them and the ones that are not
    /// have to go; every `app:` detail beyond the first widened CONTAINS -
    /// the anchored prefix itself, extra prefixes, every `-app:` - plus the
    /// `is:` states that are nil-checks and `-on:`'s excluded days, all
    /// re-checked by `matchesConstraints`; the search over file clips, whose
    /// searchable content lives in `fileURLStrings` — one opaque blob to
    /// SwiftData — so they are admitted unconditionally while a search is
    /// active and sifted here; and every other term of a multi-word query,
    /// since the predicate only ever asked about one of them.
    ///
    /// A row a single-term search returned is still taken on trust: SQL was
    /// asked the whole question, and the fields `matchesSearch` adds to it
    /// only ever admit more.
    ///
    /// And the pinboard scope, which the predicate never saw: the board a
    /// clip sits in is a to-one relationship, and a `Double?` ordering
    /// invariant is not a thing SQLite can be asked about either. A board
    /// scope also re-orders by `pinboardOrder`, the manual arrangement the
    /// fetch's `createdAt` sort cannot express.
    func refine<T: ClipDisplayable>(_ items: [T]) -> [T] {
        let filtered = items.filter { item in
            guard matchesBoard(item) else { return false }
            guard matchesType(item) else { return false }
            guard matchesConstraints(item) else { return false }
            guard !query.terms.isEmpty else { return true }
            // A single-term non-file row is taken on trust: SQL was asked
            // the whole question. File rows and secret rows still need the
            // Swift-side pass — files for `fileURLStrings`, secrets for the
            // label/mask their nil `text` cannot answer.
            guard query.terms.count > 1 || item.kind == .file || item.isSecret else { return true }
            return matchesSearch(item)
        }
        guard case .board = board else { return filtered }
        // Manual order: a lower `pinboardOrder` comes first, ties break on
        // recency (the order the fetch already gave). A board member without
        // an order is new and sorts to the end by creation, newest first.
        return filtered.enumerated().sorted { lhs, rhs in
            switch (lhs.element.pinboardOrder, rhs.element.pinboardOrder) {
            case let (l?, r?):
                return l != r ? l < r : lhs.offset < rhs.offset
            case (nil, nil):
                return lhs.offset < rhs.offset
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            }
        }.map(\.element)
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
    /// The cursor: the clip the arrows move, and the one every action that
    /// can only mean one clip acts on. Nil for "nothing chosen yet" (which
    /// means the top row: the panel opens with the newest clip ready to
    /// paste).
    private(set) var id: UUID?

    /// The far end of an extended range, or nil while the cursor stands
    /// alone.
    ///
    /// The range between it and the cursor is deliberately NOT stored: it is
    /// re-derived from the current list every time it is asked for, so an
    /// extension that shrinks again leaves nothing behind, and a range whose
    /// middle rows were filtered away closes up instead of holding on to
    /// clips that are no longer on screen.
    private(set) var rangeOrigin: UUID?

    /// Clips picked out one at a time, away from whatever range is live.
    ///
    /// Never holds the cursor — the cursor is a member of the selection by
    /// definition, and storing it twice would let two equal selections
    /// compare unequal.
    private(set) var picked: Set<UUID> = []

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

    /// Every selected clip, in list order.
    ///
    /// The one place the range and the individually picked clips are put back
    /// together, and the one place membership is decided — so a clip that has
    /// left the list cannot be acted on, whatever the selection still
    /// remembers about it.
    func selectedIDs(in ids: [UUID]) -> [UUID] {
        guard !ids.isEmpty else { return [] }
        var members = picked
        members.insert(id ?? ids[0])
        if let rangeOrigin,
           let from = ids.firstIndex(of: rangeOrigin),
           let to = index(in: ids) {
            for step in min(from, to)...max(from, to) { members.insert(ids[step]) }
        }
        return ids.filter { members.contains($0) }
    }

    /// Whether more than the cursor may be selected. Cheap enough to ask
    /// before resolving the whole list against it.
    var isExtended: Bool {
        rangeOrigin != nil || !picked.isEmpty
    }

    mutating func clear() {
        id = nil
        collapse()
    }

    /// Drop everything but the cursor.
    mutating func collapse() {
        rangeOrigin = nil
        picked = []
    }

    /// Select a row by index, clamped into the list.
    ///
    /// A plain movement or click replaces the whole selection, the way it does
    /// in every other list on the system: only the modified gestures below add
    /// to one.
    mutating func select(index: Int, in ids: [UUID]) {
        collapse()
        moveCursor(to: index, in: ids)
    }

    /// Extend the selection to a row, leaving the far end of the range where
    /// it is — ⇧-click, ⇧↑/⇧↓, and the movement keys in visual mode.
    ///
    /// The first extension anchors the range at the cursor, so a run of them
    /// sweeps out from where the user was rather than from the top of the
    /// list.
    mutating func extend(to index: Int, in ids: [UUID]) {
        guard !ids.isEmpty else {
            id = nil
            collapse()
            return
        }
        if rangeOrigin == nil { rangeOrigin = ids[movementOrigin(in: ids)] }
        moveCursor(to: index, in: ids)
    }

    /// Extend by `delta` rows from the cursor.
    mutating func extend(by delta: Int, in ids: [UUID]) {
        extend(to: movementOrigin(in: ids) + delta, in: ids)
    }

    /// Add one clip to the selection, or take it out again — ⌘-click.
    ///
    /// Taking the last clip out is refused rather than honoured: the panel's
    /// keys all act on a cursor, and an empty selection would leave Return,
    /// Space and ⌘C with nothing to do and no way back except the arrows.
    mutating func toggle(index: Int, in ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let target = ids[min(max(index, 0), ids.count - 1)]
        var members = selectedIDs(in: ids)
        if let position = members.firstIndex(of: target) {
            guard members.count > 1 else { return }
            members.remove(at: position)
            setMembers(members, cursor: members[min(position, members.count - 1)])
        } else {
            members.append(target)
            setMembers(members, cursor: target)
        }
    }

    /// Replace the selection with an explicit list of members.
    ///
    /// Flattens whatever range was live into the picked set, which is what
    /// makes ⌘-click able to punch a hole in a range: there is no range left
    /// to re-derive it from.
    private mutating func setMembers(_ members: [UUID], cursor: UUID) {
        id = cursor
        rangeOrigin = nil
        picked = Set(members)
        picked.remove(cursor)
    }

    private mutating func moveCursor(to index: Int, in ids: [UUID]) {
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
        selectNeighbour(ofAll: [removed], in: ids)
    }

    /// The same, for a whole multi-selection going at once.
    ///
    /// The selection lands where the topmost deleted clip was: nothing above
    /// it moved, so that row index is the hole the deletion leaves whichever
    /// of the rows below it also went.
    mutating func selectNeighbour(ofAll removed: [UUID], in ids: [UUID]) {
        guard let slot = removed.compactMap({ ids.firstIndex(of: $0) }).min() else { return }
        let gone = Set(removed)
        let remaining = ids.filter { !gone.contains($0) }
        collapse()
        guard !remaining.isEmpty else {
            id = nil
            return
        }
        id = remaining[min(slot, remaining.count - 1)]
    }

    /// What a run of clips puts on the pasteboard: each one's primary
    /// copyable text, in list order, one per line.
    ///
    /// Built out of the preview pane's copy options rather than a second set
    /// of kind-by-kind rules, so a clip copied on its own and the same clip
    /// copied as part of a run put the same text on the pasteboard. Clips
    /// with nothing to copy — an image Vision could not read, a colour-less
    /// swatch — drop out instead of contributing a blank line.
    static func copyText<T: ClipDisplayable>(for items: [T]) -> String {
        items
            .compactMap { PreviewCopy.options(for: $0).first?.text }
            .joined(separator: "\n")
    }
}

/// What a click on a card means, given the modifiers held with it.
///
/// A plain click has pasted since the panel's first version and still does;
/// the two modified clicks are the mouse's half of the keyboard's ⇧↑/⇧↓ and
/// visual mode. ⌘ wins over ⇧ when both are down, matching the Finder.
enum ClipClick: Equatable {
    case paste
    case extend
    case toggle

    static func intent(for modifiers: NSEvent.ModifierFlags) -> ClipClick {
        if modifiers.contains(.command) { return .toggle }
        if modifiers.contains(.shift) { return .extend }
        return .paste
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
    /// The movement keys drag one end of a range instead of moving the
    /// cursor. Every other vim command still runs, and acts on the whole
    /// range.
    case visual
    /// Keys type into the search field.
    case insert

    var badge: String {
        switch self {
        case .normal: return "NORMAL"
        case .visual: return "VISUAL"
        case .insert: return "INSERT"
        }
    }

    var announcement: String {
        switch self {
        case .normal: return loc("Normal mode. Slash to search.")
        case .visual: return loc("Visual mode. j and k extend the selection.")
        case .insert: return loc("Search mode. Escape to return to normal mode.")
        }
    }

    /// What VoiceOver calls the badge.
    var accessibilityName: String {
        switch self {
        case .normal: return loc("Normal mode")
        case .visual: return loc("Visual mode")
        case .insert: return loc("Search mode")
        }
    }

    /// The badge's tooltip: what this mode is, and the key out of it.
    var help: String {
        switch self {
        case .normal: return loc("Vim normal mode — press / or i to search")
        case .visual: return loc("Vim visual mode — j and k extend the selection, Esc leaves")
        case .insert: return loc("Search mode — press Esc for vim navigation")
        }
    }

    /// Whether plain characters are read as vim commands rather than typed.
    ///
    /// The whole reason the bare-letter bindings can exist: in insert mode
    /// every character belongs to the query, so `n` types an `n` and only
    /// normal mode may claim it. The modified shortcuts (⌘S, ⌘1–⌘9) run in
    /// both modes precisely because they are unreachable by typing.
    var readsVimKeys: Bool { self != .insert }
}

// MARK: - Hints

/// Which hint the panel floats over its content, and when.
///
/// The panel answers to keys that nothing on screen names: the arrows walk
/// the deck while the caret is busy with the query, Escape is the way back
/// out of insert mode, a second Space goes to Quick Look, and Return pastes
/// a whole multi-selection at once. Each is a keystroke away and invisible
/// until someone guesses it, so each gets a bubble for as long as it is the
/// thing the user is reaching for.
///
/// Pure, and here rather than inline in the view, so the precedence between
/// them is something a test can pin down.
enum PanelHint {
    /// The one bubble over the card deck. One at a time, most specific
    /// first: a multi-selection changes what Return does and says so whether
    /// or not the arrows have been found yet; insert mode owns the letters,
    /// so the way back to them outranks the arrows; a query on its own only
    /// has to say which keys walk the matches.
    static func overStrip(
        selectedCount: Int,
        vimInsertMode: Bool,
        hasQuery: Bool,
        dismissed: Bool
    ) -> String? {
        if selectedCount > 1 { return loc("↩ pastes %d clips", selectedCount) }
        guard !dismissed else { return nil }
        if vimInsertMode { return loc("↑ ↓ to pick · esc for h j k l") }
        guard hasQuery else { return nil }
        return loc("↑ ↓ to pick · ⌘Y to preview · ↩ to paste")
    }

    /// Whether a change to the query puts the deck's bubble back.
    ///
    /// Only when a query starts from nothing. Someone who has just asked a
    /// new question is looking at a set of matches they have not walked, so
    /// the keys are worth naming again even if the bubble was answered and
    /// dismissed earlier in the same session; refining a query that is
    /// already there is the same question, and is not asked twice.
    static func asksAgain(previousQuery: String, currentQuery: String) -> Bool {
        previousQuery.isEmpty && !currentQuery.isEmpty
    }

    /// The bubble over the preview pane: the second Space, on the clips that
    /// have somewhere to escalate to.
    static func overPreview(canQuickLook: Bool, dismissed: Bool) -> String? {
        guard canQuickLook, !dismissed else { return nil }
        return loc("space for Quick Look")
    }
}

/// Callbacks the panel UI uses to talk back to controllers.
struct PanelActions {
    var paste: (ClipItem, Bool) -> Void
    /// Paste a run of clips, in the order given.
    ///
    /// Separate from `paste` because pasting several clips is not pasting one
    /// clip several times: each ⌘V has to be seen to land before the
    /// pasteboard is overwritten with the next clip. `QueueService` already
    /// does that, and this routes to it rather than growing a second answer.
    var pasteMany: ([ClipItem], Bool) -> Void
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
    /// Put the appointment this clip describes in the calendar.
    var addToCalendar: (ClipItem) -> Void
    /// Open the note already written for this clip.
    var openNote: (ClipItem) -> Void
    /// Show a screenshot clip's file in the Finder.
    var revealInFinder: (ClipItem) -> Void
    /// Show a run of clips full size in Quick Look, opening on `index`.
    ///
    /// The completion carries the clip Quick Look was showing when it closed,
    /// so the panel's selection can follow wherever the arrows ended up.
    var quickLook: ([ClipItem], Int, @escaping (UUID) -> Void) -> Void
    /// Replace a clip's text with the edited draft, dedup-merging by the new
    /// hash; the returned snapshot is the panel-session undo's record of
    /// what the clip held before. Nil when the clip may not be edited.
    var applyEdit: (ClipItem, String) -> ClipEdit.Snapshot?
    /// Put a clip back the way `applyEdit`'s snapshot remembers it.
    var undoEdit: (ClipEdit.Snapshot) -> Void
    /// Open a secret's cipher; async because the Touch ID prompt blocks.
    /// The vault's `LAContext` reuse window makes reveals within 60 s of
    /// each other a single prompt. `@MainActor` because `ClipItem` is a
    /// main-actor model — the suspend happens inside `SecretsService`'s
    /// detached open, not by crossing actors with the row in hand.
    var revealSecret: @MainActor (ClipItem) async -> Result<String, Error>
    /// "Not a Secret": opens the cipher (the same prompt), then demotes the
    /// row to an ordinary clip and allow-lists its hash so capture never
    /// speaks for the same string again.
    var demoteSecret: @MainActor (ClipItem) async -> Bool
    /// "Mark as Secret" on an ordinary text clip. Sealing touches only the
    /// enclave's public key, so it needs no prompt.
    var promoteSecret: @MainActor (ClipItem) -> Void
    /// Concealed-write a revealed secret's plaintext (whole, or the selected
    /// part) to the pasteboard, armed for the clear-after-paste pass. No
    /// open: the caller already holds the plaintext, which is itself proof
    /// the user authenticated moments ago.
    var copyConcealed: @MainActor (ClipItem, String) -> Void
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
        .onAppear { consumePendingSearch() }
        .onChange(of: uiState.pendingSearch) { _, _ in consumePendingSearch() }
    }

    /// The "Open MemoryClip" intent's prefill: a search the controller asked
    /// for lands here once the panel is shown, becomes the filter, and is
    /// cleared so it fires once per ask — before the panel exists `onAppear`
    /// catches it, once it does `onChange` does.
    private func consumePendingSearch() {
        guard let query = uiState.pendingSearch else { return }
        uiState.pendingSearch = nil
        filter = ClipFilter(search: query)
        pageLimit = ClipFilter.pageSize
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

    /// The pinboards, in chip-strip order (PRD 06).
    @Query(sort: \Pinboard.order) private var pinboards: [Pinboard]

    /// Every pinned clip, for the Pinned chip's count. `pinboard == nil` is
    /// a relationship test no predicate can ask, so the board-less share is
    /// counted in Swift, the same division of labour `refine(_:)` uses.
    @Query(filter: #Predicate<ClipItem> { $0.isPinned })
    private var pinnedClips: [ClipItem]

    @Binding private var filter: ClipFilter
    @Binding private var pageLimit: Int
    @ObservedObject private var uiState: PanelUIState
    @ObservedObject private var queue: QueueService
    private let actions: PanelActions

    @AppStorage(SettingsKeys.vimMode) private var vimModeEnabled = false
    @AppStorage(NoteSettingsKeys.previewPaneHeight)
    private var storedPreviewHeight = Double(Design.Size.previewPaneHeight)

    @State private var selection = ClipSelection()
    /// The card strip's scroll offset, held only so that reopening the panel
    /// can put it back at the newest clip.
    @State private var stripPosition = ScrollPosition()
    @State private var inputMode: PanelInputMode = .normal
    @State private var showNukeConfirmation = false
    @State private var pendingDeletes: [ClipItem] = []
    @State private var previewVisible = false
    @State private var previewItem: ClipItem?
    /// What is selected with the mouse in the open preview pane, so ⌘C can
    /// copy it instead of the whole clip. Nil when nothing is selected.
    @State private var previewSelection: String?
    /// Bumped by ⌘T; the preview's text panel flips between the original and
    /// the translation each time it changes.
    @State private var previewTextTabToggle = 0
    /// The reveal in flight: which clip's plaintext is in the pane and until
    /// when. One slot — the pane shows one clip at a time, so a second
    /// secret's reveal replaces the first rather than stacking on it. Nil
    /// whenever nothing is revealed; the pane reads nil as "locked".
    @State private var secretReveal: (uuid: UUID, text: String, hidesAt: Date)?
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
    /// Clip counts per source app, for the `app:` suggestion ordering.
    /// Filled lazily by `refreshAppCounts` - one `fetchCount` per distinct
    /// app is a full scan each, so it waits until someone actually types
    /// `app:` rather than taxing every panel open.
    @State private var sourceAppCounts: [(name: String, count: Int)] = []
    /// The highlighted suggestion row in the list under the search field.
    @State private var suggestionIndex = 0
    /// The operator key the suggestion list was Esc'd away for. Esc closes
    /// the list, not the context: it reopens on the next context change
    /// rather than on the next keystroke of the same key.
    @State private var suggestionDismissedKey: ClipOperatorKey?
    /// Whether the deck's navigation hint has been answered. Set by the first
    /// movement of any kind, cleared when the query goes and when the panel
    /// reopens: the bubble is there to be dismissed by using the keys it
    /// names, not to be read twice.
    /// How many clips the filter matches across the whole store, or nil
    /// while that is not worth the pass it would cost. Re-counted off the
    /// filter rather than derived from the page, which only ever holds one
    /// page.
    @State private var matchCount: Int?
    @State private var navHintDismissed = false
    /// The same, for the preview pane's Quick Look bubble.
    @State private var quickLookHintDismissed = false
    /// The open in-place edit, or nil. While one is live the preview pane
    /// shows the editor instead of the preview, and the panel's keys are
    /// suspended in favour of the draft.
    @State private var editing: ClipEdit.Session?
    /// Drafts kept for clips whose editor was still dirty when the panel
    /// closed. Memory only, never the store, so they die with the app.
    @State private var editDrafts: [UUID: String] = [:]
    /// The pre-edit snapshot of the last saved edit: the panel-session
    /// undo behind the toast's "Undo (⌘Z)".
    @State private var lastEditUndo: ClipEdit.Snapshot?
    /// The transient line in the footer's status area ("Clip edited · …").
    @State private var statusMessage: String?
    /// Re-triggers the toast's dismiss task whenever a new message arrives.
    @State private var statusToken = 0
    @FocusState private var searchFocused: Bool
    /// The clip the pinboard picker (⌘P, vim `P`) is open for.
    @State private var pinboardPickerItem: ClipItem?
    /// Whether the strip's name field is showing. With `editingPinboard`
    /// set it renames that board; otherwise it names a new one.
    @State private var namingPinboard = false
    @State private var editingPinboard: Pinboard?
    @State private var pinboardName = ""
    /// The scope chip an in-panel clip drag is hovering over, for the
    /// drop highlight.
    @State private var dropTargetScope: PinboardScope?
    /// The board the delete confirmation is asking about.
    @State private var pinboardPendingDelete: Pinboard?
    /// Whether the Control key is held: the board chips badge their
    /// ⌃1…⌃9 jump while it is.
    @State private var controlHeld = false

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
    /// matches beyond the current page. A board scope fetches unbounded,
    /// there is no next page.
    private var hasMorePages: Bool {
        !filter.board.isBoardScoped && items.count >= pageLimit
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

    /// Every selected clip, in list order — one element for the selection the
    /// panel has always had, more once a range or a ⌘-click has widened it.
    private var selectedItems: [ClipItem] {
        let visible = visibleItems
        let chosen = Set(selection.selectedIDs(in: visible.map(\.uuid)))
        return visible.filter { chosen.contains($0.uuid) }
    }

    /// The bubble over the deck, if the keyboard is doing something the
    /// cards do not name. `isExtended` is asked first because resolving the
    /// whole selection is a pass over the page and a lone cursor never
    /// needs one.
    private var stripHint: String? {
        PanelHint.overStrip(
            selectedCount: selection.isExtended ? selectedItems.count : 1,
            vimInsertMode: vimModeEnabled && inputMode == .insert,
            hasQuery: !filter.search.isEmpty,
            dismissed: navHintDismissed
        )
    }

    /// True while keystrokes should be read as vim commands.
    private var readsVimKeys: Bool {
        vimModeEnabled && inputMode.readsVimKeys
    }

    // MARK: Operator suggestions

    /// The operator token being completed at the end of the query, if any -
    /// `app:` just typed, `is:pi` half-finished.
    private var suggestionContext: ClipQuery.SuggestionContext? {
        ClipQuery.suggestionContext(in: filter.search)
    }

    /// The source-app rows for `app:` - most-used first once counts are in,
    /// alphabetical until then.
    private var appSuggestionRows: [(name: String, count: Int)] {
        sourceAppCounts.sorted {
            $0.count != $1.count
                ? $0.count > $1.count
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// The suggestion rows for the token being completed.
    private var suggestionItems: [SearchSuggestion] {
        guard let context = suggestionContext else { return [] }
        return ClipQuery.suggestions(
            for: context,
            apps: appSuggestionRows,
            boards: pinboards.map(\.name),
            now: filter.now,
            calendar: filter.calendar
        )
    }

    /// Whether the list is up. It is a typing aid, so it stands down in vim
    /// normal mode (no keystroke reaches the field anyway) and stays down
    /// for the key it was Esc'd away from.
    private var suggestionsVisible: Bool {
        guard !readsVimKeys,
              let context = suggestionContext,
              context.key != suggestionDismissedKey else { return false }
        return !suggestionItems.isEmpty
    }

    /// The row Return/Tab would accept, clamped to what is shown.
    private var highlightedSuggestion: SearchSuggestion? {
        suggestionItems.indices.contains(suggestionIndex)
            ? suggestionItems[suggestionIndex]
            : suggestionItems.first
    }

    /// The `?` cheat-sheet: a lone `?` as the whole query.
    private var showsCheatSheet: Bool {
        filter.search.trimmingCharacters(in: .whitespaces) == "?"
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
        // Stale counts are worse than none: the `app:` suggestion list
        // orders alphabetically until they are counted again.
        sourceAppCounts = []
    }

    /// How many distinct source apps the footer menu will list.
    private static let sourceAppLimit = 50

    /// Clip counts per source app, for ordering `app:` suggestions
    /// most-used first. One `fetchCount` per distinct name - a scan apiece
    /// on an unindexed column - so this runs only when the `app:` context
    /// appears, and only once per set of names.
    private func refreshAppCounts() {
        var counts: [(name: String, count: Int)] = []
        for name in sourceAppNames {
            // `needle` is lifted to String? so the comparison is the same
            // optional-equals-optional shape `clipEquals` emits.
            let needle: String? = name
            var descriptor = FetchDescriptor<ClipItem>(
                predicate: #Predicate<ClipItem> { $0.sourceAppName == needle }
            )
            descriptor.propertiesToFetch = [\.sourceAppName]
            let count = (try? modelContext.fetchCount(descriptor)) ?? 0
            counts.append((name, count))
        }
        sourceAppCounts = counts
    }

    /// Write the highlighted suggestion into the query - `is:` plus a
    /// choice becomes `is:pinned `, trailing space and all, so the token
    /// closes and the next keystroke starts a fresh one.
    private func acceptSuggestion(_ suggestion: SearchSuggestion) {
        guard let context = suggestionContext else { return }
        filter.search = ClipQuery.accepting(context, suggestion.value, in: filter.search)
        suggestionIndex = 0
        searchFocused = true
    }

    /// ↑/↓ while the suggestion list is up move its highlight instead of
    /// the card selection - the first thing those keys can mean while a
    /// completion is on the table.
    private func moveSuggestion(_ delta: Int) {
        let count = suggestionItems.count
        guard count > 0 else { return }
        suggestionIndex = (suggestionIndex + delta + count) % count
    }

    /// The empty state's "Clear filters": the words stay, the operators and
    /// the chip go - the two things that were narrowing the list.
    private func clearConstraints() {
        filter.search = ClipQuery.clearingOperators(from: filter.search)
        filter.type = .all
    }

    /// `app:` from a preview's source badge. The clicked clip keeps its
    /// place while the constraint lands: the filter change clears the
    /// selection and re-syncs the preview, so both are re-pinned after it
    /// settles.
    private func filterToApp(_ name: String, keeping item: ClipItem) {
        filter.source = name
        Task { @MainActor in
            selection = ClipSelection(id: item.uuid)
            previewItem = item
        }
    }

    /// The whole store's answer to the filter, or nil when finding it would
    /// cost more than a footer number is worth.
    ///
    /// `fetchCount` is a SQL COUNT and flat in store size, so wherever the
    /// predicate *is* the filter that is the end of it. Where it is not —
    /// see `needsSwiftSideRefinement` — the rows have to be looked at, and
    /// that is bounded: a search matching half a 50k store is exactly the
    /// pass the paging exists to avoid, and there the footer goes back to
    /// saying what it has rather than guessing at what it has not.
    private func countMatches() -> Int? {
        let descriptor = FetchDescriptor<ClipItem>(predicate: filter.predicate)
        guard let admitted = try? modelContext.fetchCount(descriptor) else { return nil }
        guard filter.needsSwiftSideRefinement else { return admitted }
        guard admitted <= Self.countScanLimit else { return nil }
        var scan = descriptor
        scan.fetchLimit = Self.countScanLimit
        guard let rows = try? modelContext.fetch(scan) else { return nil }
        return filter.refine(rows).count
    }

    /// How many rows the footer's count may sift before it gives up.
    private static let countScanLimit = 2000

    /// How long the typing has to stop before the count is redone.
    private static let countSettleDelay: TimeInterval = 0.15

    /// What the count is keyed on: the question asked, and the fact that the
    /// store answered differently — a capture or a delete while the panel is
    /// open moves the number without touching the filter.
    private struct MatchCountKey: Equatable {
        let filter: ClipFilter
        let loaded: Int
    }

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

                pinboardStrip
                    .frame(height: Design.Size.pinboardStripHeight)
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
                    // The pane becomes the editor, keeping its frame and its
                    // resize handle. The isDeleted half is for a clip wiped
                    // by Clear All History or a context-menu Delete while it
                    // was being edited: a dead row has nothing left to show.
                    if let editing, !editing.item.isDeleted {
                        ClipEditorView(
                            item: editing.item,
                            draft: Binding(
                                get: { self.editing?.draft ?? "" },
                                set: { self.editing?.draft = $0 }
                            ),
                            discardArmed: editing.discardArmed,
                            onSave: { saveEdit(andPaste: false) },
                            onSaveAndPaste: { saveEdit(andPaste: true) },
                            onCancel: { editEscape() },
                            onEscape: { handleEscape() }
                        )
                        .id(editing.id)
                        .frame(height: resolvedPreviewHeight)
                    } else {
                        PreviewView(
                            item: item,
                            onTransform: { actions.applyTransform(item, $0) },
                            onCopy: { actions.copyText(item, $0) },
                            paneHeight: resolvedPreviewHeight,
                            onEdit: ClipDisplay.canEdit(item) ? { startEditing(item) } : nil,
                            onFilterApp: { name in filterToApp(name, keeping: item) },
                            onSelectionChange: { previewSelection = $0 },
                            // `uuid` is checked so a stale reveal can never be
                            // shown under a different secret's label.
                            secretText: secretReveal?.uuid == item.uuid && item.isSecret
                                ? secretReveal?.text : nil,
                            secretHidesAt: secretReveal?.uuid == item.uuid && item.isSecret
                                ? secretReveal?.hidesAt : nil,
                            secretNotice: uiState.secretNotice,
                            onRevealSecret: { revealSecret(item) },
                            onHideSecret: { concealSecret() },
                            onDemoteSecret: { demoteSecret(item) },
                            onCopySecret: { text in
                                actions.copyConcealed(item, text)
                                announce(loc("Copied"))
                            },
                            textTabToggle: previewTextTabToggle
                        )
                        .frame(height: resolvedPreviewHeight)
                        .overlay(alignment: .bottom) {
                            hintBubble(
                                PanelHint.overPreview(
                                    canQuickLook: QuickLook.canPreview(item),
                                    dismissed: quickLookHintDismissed
                                )
                            )
                        }
                    }
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
            // The suggestion list floats over the card strip, dropped down
            // from the search field it belongs to, rather than growing the
            // top bar or the strip under it.
            .overlay(alignment: .topLeading) {
                suggestionOverlay
                    .padding(.top, Design.Size.panelTopPadding + Design.Size.topBarHeight - Design.Space.snug)
                    .padding(.leading, Design.Space.loose + 26)
            }
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
        // The status line's toast times itself out: bumping the token
        // restarts the wait, so only the latest message's five seconds count.
        .task(id: statusToken) {
            guard statusMessage != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            statusMessage = nil
        }
        // Debounced for the same reason the preview pane is: the filter is
        // rebuilt on every keystroke, and counting once the typing comes to
        // rest is one pass instead of one per character.
        .task(id: MatchCountKey(filter: filter, loaded: items.count)) {
            try? await Task.sleep(for: .seconds(Self.countSettleDelay))
            guard !Task.isCancelled else { return }
            matchCount = countMatches()
        }
        .defaultFocus($searchFocused, true)
        .onChange(of: uiState.focusToken) {
            // Closing the panel with a dirty editor keeps the draft for when
            // the editor is reopened on the same clip: in memory only, so
            // it never survives the app.
            if let editing, editing.hasChanges {
                editDrafts[editing.item.uuid] = editing.draft
            }
            editing = nil
            lastEditUndo = nil
            statusMessage = nil
            filter = ClipFilter()
            resetPaging()
            selection.clear()
            previewVisible = false
            previewItem = nil
            previewSelection = nil
            // The reveal dies with the pane — the panel must never reopen
            // onto plaintext nobody asked to see.
            secretReveal = nil
            uiState.secretNotice = nil
            vim.reset()
            pacer.reset()
            inputMode = .normal
            navHintDismissed = false
            quickLookHintDismissed = false
            pinboardPickerItem = nil
            namingPinboard = false
            editingPinboard = nil
            pinboardPendingDelete = nil
            dropTargetScope = nil
            suggestionIndex = 0
            suggestionDismissedKey = nil
            searchFocused = true
            refreshSourceAppNames()
        }
        .onChange(of: filter) { previous, current in
            resetPaging()
            selection.clear()
            // A query typed from scratch asks the question again; refining
            // one that is already there does not.
            if PanelHint.asksAgain(previousQuery: previous.search, currentQuery: current.search) {
                navHintDismissed = false
            }
            syncPreviewItem()
        }
        .onChange(of: pinboards.map(\.uuid)) {
            // The scope outlives its board: a board deleted out from under
            // the panel drops back to Pinned, which is where its members
            // have just landed.
            if case .board(let uuid) = filter.board,
               !pinboards.contains(where: { $0.uuid == uuid }) {
                filter.board = .pinned
            }
        }
        .onChange(of: pinboards.map(\.name), initial: true) {
            // `in:` resolves board names against the store's boards; a
            // rename or a new board rewrites the index the filter holds.
            filter.boardIndex = pinboards.map { (name: $0.name, uuid: $0.uuid) }
        }
        .onChange(of: suggestionContext) {
            // A keystroke changed what is being completed - the highlight
            // returns to the top, and a dismissed list reopens on a new
            // token rather than staying shut.
            suggestionIndex = 0
            if suggestionContext == nil { suggestionDismissedKey = nil }
        }
        // `app:` suggestions are ordered by clip count, and the counts cost
        // a scan per app - so they are only fetched once `app:` is typed.
        .task(id: suggestionContext?.key == .app) {
            guard suggestionContext?.key == .app, sourceAppCounts.isEmpty else { return }
            refreshAppCounts()
        }
        .onChange(of: inputMode) {
            // Leaving the field (normal mode) closes a completion that is
            // no longer being typed into anything.
            if readsVimKeys { suggestionDismissedKey = suggestionContext?.key }
        }
        .onChange(of: selection) {
            announceSelection()
        }
        .confirmationDialog(
            pendingDeletes.count > 1
                ? loc("Delete %d clips?", pendingDeletes.count)
                : loc("Delete this clip?"),
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button(
                pendingDeletes.count > 1 ? loc("Delete %d Clips", pendingDeletes.count) : loc("Delete Clip"),
                role: .destructive
            ) { confirmDelete() }
            Button(loc("Cancel"), role: .cancel) { pendingDeletes = [] }
        } message: {
            Text(loc("Deleting a clip cannot be undone."))
        }
        .confirmationDialog(
            loc("Delete \"%@\"?", pinboardPendingDelete?.name ?? ""),
            isPresented: pinboardDeleteBinding,
            titleVisibility: .visible
        ) {
            if let board = pinboardPendingDelete {
                Button(loc("Delete Pinboard"), role: .destructive) {
                    deletePinboard(board)
                }
            }
            Button(loc("Cancel"), role: .cancel) { pinboardPendingDelete = nil }
        } message: {
            Text(loc("The clips stay pinned. They return to Pinned."))
        }
        .popover(
            isPresented: pinboardPickerBinding,
            arrowEdge: .bottom
        ) {
            if let item = pinboardPickerItem {
                PinboardPickerView(
                    boards: pinboards,
                    selection: item.pinboard.map { Set([$0.uuid]) } ?? [],
                    nameProposal: namingProposal(for: item)
                ) { action in
                    applyPinboardPick(action, for: item)
                }
            }
        }
        // The chips badge their ⌃N jump while Control is held; there is no
        // other way for the gesture to be discovered before it is tried.
        .onModifierKeysChanged(mask: .control, initial: false) { _, new in
            controlHeld = new.contains(.control)
        }
    }

    private var pinboardDeleteBinding: Binding<Bool> {
        Binding(
            get: { pinboardPendingDelete != nil },
            set: { if !$0 { pinboardPendingDelete = nil } }
        )
    }

    private var pinboardPickerBinding: Binding<Bool> {
        Binding(
            get: { pinboardPickerItem != nil },
            set: { if !$0 { pinboardPickerItem = nil } }
        )
    }

    /// `dd` is destructive and has no undo, so it routes through the same kind
    /// of confirmation as the footer's nuke-all button — one clip or a whole
    /// selection, the same gate.
    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { !pendingDeletes.isEmpty },
            set: { if !$0 { pendingDeletes = [] } }
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
                    // While a clip is being edited, keys belong to the
                    // draft: the query takes nothing, not even a click.
                    .disabled(editing != nil)
            )
            .frame(width: Design.Size.searchFieldWidth)

            filterChips

            Spacer(minLength: Design.Space.tight)

            // The badge doubles as the editing-mode marker: while a draft is
            // open it reads EDIT whether or not vim navigation is on, since
            // editing is a mode of its own.
            if vimModeEnabled || editing != nil {
                modeBadge
            }
        }
    }

    private var searchPlaceholder: String {
        readsVimKeys ? loc("Press / to search") : loc("Search clips")
    }

    /// Makes the vim mode visible instead of leaving it as invisible state.
    ///
    /// The label colour is deliberately NOT the accent colour: accent-on-tint
    /// is around 3:1 for several system accents, and this is 10-point text.
    private var modeBadge: some View {
        // EDIT rather than a vim mode while the editor is open: vim's own
        // state is suspended, not left behind, and the badge is the one
        // place that has to say so.
        let editingActive = editing != nil
        return Text(editingActive ? "EDIT" : inputMode.badge)
            .font(Design.Typography.keycap)
            .padding(.horizontal, Design.Space.snug)
            .padding(.vertical, Design.Space.hair)
            .background(
                Capsule(style: .continuous).fill(
                    editingActive || inputMode != .normal
                        ? Design.Palette.accent.opacity(0.28)
                        : Color.primary.opacity(0.10)
                )
            )
            .foregroundStyle(Color(nsColor: editingActive || inputMode != .normal ? .labelColor : .secondaryLabelColor))
            .accessibilityLabel(editingActive ? loc("Editing mode") : inputMode.accessibilityName)
            .help(editingActive ? loc("Editing mode: Esc cancels, ⌘S saves") : inputMode.help)
    }

    // MARK: Suggestion list

    /// The completion list under the search field while a `key:` token is
    /// being typed - the values the key knows, filtered by what is there so
    /// far. Rendered as an overlay on the panel so it floats over the card
    /// strip rather than pushing it down.
    @ViewBuilder
    private var suggestionOverlay: some View {
        if suggestionsVisible {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(suggestionItems.enumerated()), id: \.element.id) { index, suggestion in
                    Button {
                        acceptSuggestion(suggestion)
                    } label: {
                        HStack(spacing: Design.Space.normal) {
                            Text(suggestion.token)
                                .font(Design.Typography.chip.monospaced())
                            Spacer(minLength: Design.Space.normal)
                            Text(suggestion.detail)
                                .font(Design.Typography.meta)
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, Design.Space.roomy)
                        .padding(.vertical, Design.Space.snug)
                        .frame(minWidth: 240, maxWidth: 340, alignment: .leading)
                        .background(
                            index == suggestionIndex ? Design.Palette.surface : Color.clear
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, Design.Space.snug)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    .strokeBorder(Design.Palette.hairline, lineWidth: Design.Stroke.hairline)
            )
            .shadow(color: Design.Palette.cardShadow, radius: 12, y: 4)
            // One list with one accessible name; the rows stay buttons
            // underneath it rather than reading as ungrouped controls.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(loc("Search suggestions"))
            .accessibilityHint(loc("Down and Up choose a suggestion, Return or Tab accepts, Esc closes"))
        }
    }

    // MARK: Cheat sheet

    /// A lone `?` in the search field shows this instead of the strip: the
    /// grammar's reference card, read out of the same lists the parser and
    /// the suggestions use so the three cannot drift.
    private var cheatSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.roomy) {
                Text(loc("Search operators"))
                    .font(Design.Typography.chip.weight(.semibold))
                Grid(alignment: .leading,
                     horizontalSpacing: Design.Space.loose,
                     verticalSpacing: Design.Space.snug) {
                    ForEach(SearchCheatSheet.rows, id: \.token) { row in
                        GridRow {
                            Text(row.token)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                .gridColumnAlignment(.trailing)
                            Text(row.detail)
                                .font(Design.Typography.meta)
                                .foregroundStyle(Color(nsColor: .labelColor))
                        }
                    }
                }
                Text(loc("Down and Up choose a suggestion, Return or Tab accepts, Esc closes"))
                    .font(Design.Typography.meta)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Design.Space.loose)
            .padding(.vertical, Design.Space.normal)
        }
        .scrollIndicators(.hidden)
        .frame(height: Design.Size.cardStripHeight)
        // Treat it as one informative element rather than nine rows of
        // static text to step through.
        .accessibilityElement(children: .combine)
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
        .accessibilityLabel(loc("Filter by type"))
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
        .help(loc("Show only %@", typeFilter.label.lowercased()))
        .accessibilityLabel(typeFilter.label)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Pinboard strip

    /// The boards row under the search field (PRD 06): All, Pinned, one chip
    /// per board, then the new-board control (or, while it is up, the
    /// inline name field. Every chip is also a drop target for a card being
    /// dragged, which is how filing by mouse works.
    private var pinboardStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Design.Space.snug) {
                scopeChip(loc("All"), scope: .all)
                scopeChip(
                    loc("Pinned"),
                    scope: .pinned,
                    color: Design.Palette.pin,
                    systemImage: "pin.fill",
                    count: boardlessPinCount
                )
                ForEach(Array(pinboards.enumerated()), id: \.element.uuid) { index, board in
                    boardChip(board, index: index)
                }
                if namingPinboard {
                    pinboardNameField
                } else {
                    newPinboardButton
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
        // `.contain`, like the type chips: the scopes stay individually
        // reachable and keep their own selected traits.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(loc("Pinboards"))
    }

    /// The pins that sit in no board: what the Pinned chip scopes to.
    private var boardlessPinCount: Int {
        pinnedClips.reduce(0) { $0 + ($1.pinboard == nil ? 1 : 0) }
    }

    /// The field that names a new board or renames `editingPinboard`.
    private var pinboardNameField: some View {
        TextField(
            editingPinboard == nil ? loc("Name pinboard") : loc("Rename pinboard"),
            text: $pinboardName
        )
        .textFieldStyle(.plain)
        .font(Design.Typography.chip)
        .frame(width: 120)
        .padding(.horizontal, Design.Space.roomy)
        .padding(.vertical, Design.Space.snug)
        .background(
            Capsule(style: .continuous)
                .fill(Design.Palette.chipFill(isOn: true, increasedContrast: contrast == .increased))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(
                Design.Palette.chipSelectedBorder(increasedContrast: contrast == .increased),
                lineWidth: Design.Stroke.selection
            )
        )
        .onSubmit(commitPinboardName)
        .onExitCommand(perform: cancelPinboardName)
    }

    /// The `+` at the end of the strip.
    private var newPinboardButton: some View {
        Button {
            editingPinboard = nil
            pinboardName = ""
            namingPinboard = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .padding(.horizontal, Design.Space.roomy)
                .padding(.vertical, Design.Space.snug)
                .background(
                    Capsule(style: .continuous)
                        .fill(Design.Palette.chipFill(isOn: false, increasedContrast: contrast == .increased))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Design.Palette.hairline, lineWidth: Design.Stroke.hairline)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(loc("New Pinboard"))
        .accessibilityLabel(loc("New Pinboard"))
    }

    /// One scope chip: All, Pinned, or a board. All three share a shape,
    /// capsule, optional dot, optional count, optional ⌃N badge, so the row
    /// reads as one control repeated, not three kinds of button.
    private func scopeChip(
        _ title: String,
        scope: PinboardScope,
        color: Color? = nil,
        systemImage: String? = nil,
        count: Int? = nil,
        shortcutDigit: Int? = nil
    ) -> some View {
        let isOn = filter.board == scope
        let isTargeted = dropTargetScope == scope
        return Button {
            activateBoard(scope)
        } label: {
            HStack(spacing: Design.Space.snug) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(color ?? Color(nsColor: .secondaryLabelColor))
                        .accessibilityHidden(true)
                } else if let color {
                    Circle()
                        .fill(color)
                        .frame(width: Design.Size.chipDot, height: Design.Size.chipDot)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(Design.Typography.chip)
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .font(Design.Typography.chip)
                        .monospacedDigit()
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
                if let shortcutDigit {
                    Text("⌃\(shortcutDigit)")
                        .font(Design.Typography.keycap)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .accessibilityHidden(true)
                }
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
                    isTargeted ? Design.Palette.accent
                        : isOn ? Design.Palette.chipSelectedBorder(increasedContrast: contrast == .increased)
                            : Design.Palette.hairline,
                    lineWidth: isOn || isTargeted ? Design.Stroke.selection : Design.Stroke.hairline
                )
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(loc("Show this set of clips"))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        // A card dropped here is filed under this scope. Only the internal
        // clip type is accepted: the panel's own drags carry it, drops from
        // other apps do not, so this never intercepts a paste-style drag.
        .onDrop(of: [ClipDragProvider.clipUTType], isTargeted: dropTargetBinding(for: scope)) {
            fileDroppedClip($0, to: scope)
        }
    }

    /// A board's chip, plus the context menu the strip manages for it:
    /// rename, colour, reorder, delete.
    private func boardChip(_ board: Pinboard, index: Int) -> some View {
        scopeChip(
            board.name,
            scope: .board(board.uuid),
            color: board.color,
            count: board.clips.count,
            shortcutDigit: controlHeld && index < 9 ? index + 1 : nil
        )
        .help(index < 9 ? loc("%@ · ⌃%d", board.name, index + 1) : board.name)
        .contextMenu {
            Button(loc("Rename Pinboard…")) {
                editingPinboard = board
                pinboardName = board.name
                namingPinboard = true
            }
            Menu(loc("Board Colour")) {
                ForEach(PinboardColor.allCases, id: \.rawValue) { color in
                    Button {
                        board.colorName = color.rawValue
                        try? modelContext.save()
                    } label: {
                        if board.colorName == color.rawValue {
                            Label(color.label, systemImage: "checkmark.circle.fill")
                        } else {
                            Label(color.label, systemImage: "circle.fill")
                        }
                    }
                }
            }
            Divider()
            Button(loc("Move Earlier")) {
                board.move(by: -1, in: modelContext)
                try? modelContext.save()
            }
            .disabled(index == 0)
            Button(loc("Move Later")) {
                board.move(by: 1, in: modelContext)
                try? modelContext.save()
            }
            .disabled(index == pinboards.count - 1)
            Divider()
            Button(loc("Delete Pinboard…")) {
                pinboardPendingDelete = board
            }
        }
    }

    /// Per-scope `isTargeted` storage for the drop highlight.
    private func dropTargetBinding(for scope: PinboardScope) -> Binding<Bool> {
        Binding(
            get: { dropTargetScope == scope },
            set: { dropTargetScope = $0 ? scope : nil }
        )
    }

    /// Switch the list to a pinboard scope and say where it went.
    private func activateBoard(_ scope: PinboardScope) {
        guard filter.board != scope else { return }
        filter.board = scope
        switch scope {
        case .all:
            announce(loc("All clips"))
        case .pinned:
            announce(loc("%@, %d clips", loc("Pinned"), boardlessPinCount))
        case .board(let uuid):
            if let board = pinboards.first(where: { $0.uuid == uuid }) {
                announce(loc("%@, %d clips", board.name, board.clips.count))
            }
        }
    }

    /// ⌥← / ⌥→ step through the scopes in strip order: All, Pinned, then the
    /// boards left to right, wrapping at both ends.
    private func cycleBoard(_ delta: Int) {
        let scopes: [PinboardScope] = [.all, .pinned] + pinboards.map { .board($0.uuid) }
        guard let index = scopes.firstIndex(of: filter.board) else {
            activateBoard(.all)
            return
        }
        let next = (index + delta + scopes.count) % scopes.count
        activateBoard(scopes[next])
    }

    /// ⌃1…⌃9 jumps straight to a board by strip position.
    private func pinboardJump(_ digit: Int) {
        guard digit >= 1, digit <= pinboards.count else { return }
        activateBoard(.board(pinboards[digit - 1].uuid))
    }

    /// File the selected clip, or open the picker that asks where.
    private func openPinboardPicker() {
        guard let item = selectedItem else { return }
        pinboardPickerItem = item
    }

    /// A name for a board the picker is asked to create for this clip: the
    /// clip's first line, trimmed to the board-name limit.
    private func namingProposal(for item: ClipItem) -> String {
        let raw = (item.refinedTitle ?? item.text ?? "")
            .components(separatedBy: .newlines)
            .first ?? ""
        return String(raw.trimmingCharacters(in: .whitespaces).prefix(Pinboard.maximumNameLength))
    }

    /// What the picker's outcome does to the clip it was opened for.
    private func applyPinboardPick(_ action: PinboardPickerAction, for item: ClipItem) {
        switch action {
        case .dismiss(let picked):
            // One clip belongs to at most one board, so only the first pick
            // can apply; a second is the picker being generous. No pick is
            // an answer too: it unpins nothing, it files nowhere.
            if let boardUUID = picked.first,
               let board = pinboards.first(where: { $0.uuid == boardUUID }) {
                item.file(into: board)
                announce(loc("Filed in %@", board.name))
            } else {
                item.removeFromBoard()
                item.isPinned = true
                announce(loc("Pinned"))
            }
        case .create(let name):
            guard let board = Pinboard.create(named: name, in: modelContext) else {
                return
            }
            item.file(into: board)
            announce(loc("Pinboard created, %@ filed", board.name))
        case .cancel:
            break
        }
        try? modelContext.save()
        pinboardPickerItem = nil
    }

    /// A clip dropped on a scope chip: the drag carries the clip's uuid as
    /// in-process data (see `ClipDragProvider`), the drop resolves it back
    /// to the row.
    private func fileDroppedClip(_ providers: [NSItemProvider], to scope: PinboardScope) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: ClipDragProvider.clipTypeIdentifier) { data, _ in
            guard let data,
                  let uuid = UUID(uuidString: String(decoding: data, as: UTF8.self))
            else { return }
            Task { @MainActor in
                fileClip(uuid, to: scope)
            }
        }
        return true
    }

    /// File one clip under a scope: a board gets the clip, Pinned keeps the
    /// pin and drops the board, All asks nothing.
    private func fileClip(_ uuid: UUID, to scope: PinboardScope) {
        var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        guard let item = try? modelContext.fetch(descriptor).first else { return }
        file(item, to: scope)
    }

    /// The same, with the clip already in hand (the card's `Pin to ▸`
    /// menu, which does not need the uuid lookup a drop does).
    private func file(_ item: ClipItem, to scope: PinboardScope) {
        switch scope {
        case .all:
            return
        case .pinned:
            item.pinToPinned()
            announce(loc("Pinned"))
        case .board(let boardUUID):
            guard let board = pinboards.first(where: { $0.uuid == boardUUID }) else { return }
            item.file(into: board)
            announce(loc("Filed in %@", board.name))
        }
        try? modelContext.save()
    }

    /// Commit or abandon the strip's name field.
    private func commitPinboardName() {
        defer {
            namingPinboard = false
            editingPinboard = nil
            pinboardName = ""
        }
        if let board = editingPinboard {
            if board.rename(to: pinboardName, in: modelContext) {
                try? modelContext.save()
            }
        } else if let board = Pinboard.create(named: pinboardName, in: modelContext) {
            try? modelContext.save()
            announce(loc("Pinboard created, %@", board.name))
            // A new board is filed into immediately: the person who named it
            // is looking at it.
            filter.board = .board(board.uuid)
        }
    }

    private func cancelPinboardName() {
        namingPinboard = false
        editingPinboard = nil
        pinboardName = ""
    }

    /// Confirmed deletion: the clips return to Pinned, the survivors'
    /// `order`s renumber, and the scope falls back if it was on this board.
    private func deletePinboard(_ board: Pinboard) {
        pinboardPendingDelete = nil
        let name = board.name
        let members = board.clips.count
        board.delete(in: modelContext)
        if filter.board == .board(board.uuid) { filter.board = .pinned }
        try? modelContext.save()
        announce(loc("%@ deleted, %d clips returned to Pinned", name, members))
    }

    /// True while a text field other than the search field owns the keys:
    /// the board-name field and the picker's filter field. The panel's bare
    /// key handlers stand down so typing reaches the field.
    private var auxiliaryFieldActive: Bool {
        namingPinboard || pinboardPickerItem != nil
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
            // ⇧ with a movement key drags one end of a range behind the
            // cursor instead of carrying the selection along whole, which is
            // what ⇧ with a movement key does in every list on the system.
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                // While the editor is open every arrow belongs to the
                // draft's caret, not the strip; a board-name field owns
                // them too.
                guard editing == nil, !auxiliaryFieldActive else { return .ignored }
                // While the suggestion list is up, the arrows move its
                // highlight rather than the card selection - the first
                // thing they can mean with a completion on the table.
                if suggestionsVisible {
                    moveSuggestion(press.key == .downArrow ? 1 : -1)
                    return .handled
                }
                moveSelection(
                    press.key == .downArrow ? 1 : -1,
                    extending: press.modifiers.contains(.shift),
                    phase: press.phase
                )
                return .handled
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
                guard editing == nil, !auxiliaryFieldActive else { return .ignored }
                // While there is a query to edit, the arrows belong to the
                // caret — swallowing them would make the search field
                // impossible to correct. With an empty field (the state the
                // panel opens in) they move the selection.
                guard readsVimKeys || filter.search.isEmpty else { return .ignored }
                // ⌥← and ⌥→ hop between pinboard scopes (PRD 06) rather than
                // moving the selection. Presses only: a held key that hopped
                // boards on every repeat would be impossible to steer.
                if press.modifiers.contains(.option) {
                    guard press.phase == .down else { return .handled }
                    // ⌥⇧← / ⌥⇧→, while scoped to a board, drag the selected
                    // clip along its manual order: the reorder the scope
                    // exists to hold.
                    if press.modifiers.contains(.shift),
                       case .board(let uuid) = filter.board,
                       let board = pinboards.first(where: { $0.uuid == uuid }),
                       let item = selectedItem {
                        let earlier = press.key == .leftArrow
                        item.move(within: board, by: earlier ? -1 : 1)
                        try? modelContext.save()
                        announce(earlier ? loc("Moved earlier") : loc("Moved later"))
                        return .handled
                    }
                    cycleBoard(press.key == .rightArrow ? 1 : -1)
                    return .handled
                }
                moveSelection(
                    press.key == .rightArrow ? 1 : -1,
                    extending: press.modifiers.contains(.shift),
                    phase: press.phase
                )
                return .handled
            }
            .onKeyPress(keys: [.return], phases: .down) { press in
                guard !auxiliaryFieldActive else { return .ignored }
                // While editing, ⌘Return is Save and Paste and every other
                // Return is the draft's own newline: the editor must see it.
                if editing != nil {
                    guard press.modifiers.contains(.command) else { return .ignored }
                    saveEdit(andPaste: true)
                    return .handled
                }
                // An open suggestion list takes Return next: the highlighted
                // completion is what the key just typed against.
                if suggestionsVisible {
                    if let suggestion = highlightedSuggestion {
                        acceptSuggestion(suggestion)
                    }
                    return .handled
                }
                pasteSelected(plainOnly: press.modifiers.contains(.shift))
                return .handled
            }
            // Tab accepts a suggestion too - the second completion key
            // every AppKit field teaches - and otherwise keeps its usual
            // meaning (moving focus), which the panel leaves to AppKit.
            .onKeyPress(.tab, phases: .down) { _ in
                guard suggestionsVisible, let suggestion = highlightedSuggestion
                else { return .ignored }
                acceptSuggestion(suggestion)
                return .handled
            }
            .onKeyPress(.space, phases: .down) { _ in
                // Space in a draft types a space.
                guard editing == nil, !auxiliaryFieldActive else { return .ignored }
                if readsVimKeys {
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
                // ⌃1…⌃9 jumps to the board at that strip position (PRD 06).
                // Ahead of the vim state machine: digits are unbound there,
                // but in normal mode an unbound key is still consumed.
                if press.modifiers.contains(.control),
                   !press.modifiers.contains(.command),
                   !press.phase.contains(.repeat),
                   // `press.key.character`, not `press.characters`: the
                   // latter factors the modifier in, and Control turns a
                   // digit into an unprintable control character.
                   let digit = press.key.character.wholeNumberValue,
                   (1...9).contains(digit) {
                    pinboardJump(digit)
                    return .handled
                }
                // The ⌘ shortcuts act on the press alone: a held ⌘1 should
                // paste one clip, not one per repeat event.
                if press.modifiers.contains(.command), !press.phase.contains(.repeat) {
                    // While the editor is open it owns the ⌘ keys: ⌘S is
                    // re-pointed at the draft, ⌘Z/X/C/V/A reach the text view
                    // through the Edit menu first, and ⌘1…⌘9 and friends do
                    // nothing. A quick-paste in the middle of a draft is
                    // exactly what "suspended" means.
                    if editing != nil {
                        switch press.characters.lowercased() {
                        case "s":
                            saveEdit(andPaste: false)
                        case "z" where !press.modifiers.contains(.shift):
                            // A ⌘Z that lands here is one the draft's own
                            // undo stack declined, so the session undo is
                            // the only thing left for it to take back.
                            _ = undoLastEdit()
                        default:
                            break
                        }
                        return .handled
                    }
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
                    // ⌘E for the same reason, and it is free for the same
                    // reason: `main.swift` builds an Edit menu of Undo, Redo,
                    // Cut, Copy, Paste and Select All and nothing else, so no
                    // menu item claims it. E is for Event.
                    if press.characters.lowercased() == "e" {
                        addSelectedToCalendar()
                        return .handled
                    }
                    // ⌘C means copy, everywhere in macOS, and a list of
                    // clipboard entries is the last place it may mean
                    // anything else — so it is claimed here rather than left
                    // to reach the vim `c` binding, which is the calendar's.
                    // The Edit menu's own Copy still wins whenever the search
                    // field has a selection to copy: this runs only once that
                    // item has nothing to act on.
                    if press.characters.lowercased() == "c" {
                        copySelected()
                        return .handled
                    }
                    // ⌘I, free the way ⌘S and ⌘E are: the Edit menu's own
                    // items (⌘Z/X/C/V/A) are its only neighbours. I is for
                    // "in place", which is what the edit is.
                    if press.characters.lowercased() == "i" {
                        editSelected()
                        return .handled
                    }
                    // ⌘P opens the pinboard picker on the cursor clip (PRD
                    // 06). P for Pinboard; the app has no Print menu item,
                    // so the shortcut is free.
                    if press.characters.lowercased() == "p" {
                        openPinboardPicker()
                        return .handled
                    }
                    // ⌘Z is the session undo the edit toast advertises. The
                    // Edit menu's own Undo takes it first whenever a field
                    // has undos to give; this runs only once it does not,
                    // and only while a saved edit is there to take back.
                    // ⇧⌘Z is deliberately left alone: it is Redo, and redo
                    // is the text fields' own.
                    if press.characters.lowercased() == "z",
                       !press.modifiers.contains(.shift),
                       undoLastEdit() {
                        return .handled
                    }
                    // ⌘Y is what Finder binds Quick Look to, and here it is
                    // the only way into the preview once something has been
                    // typed: a bare Space belongs to the search field for as
                    // long as the field has a query in it. It escalates the
                    // same way Space does, so both keys are one habit.
                    if press.characters.lowercased() == "y" {
                        escalatePreview()
                        return .handled
                    }
                    // ⌘T flips the preview's text between the original and
                    // its translation. Free like ⌘S and ⌘E: the app's menus
                    // claim no ⌘T. T for Translation.
                    if press.characters.lowercased() == "t", previewVisible {
                        previewTextTabToggle += 1
                        return .handled
                    }
                }
                return handleVimKey(press)
            }
    }

    /// Esc unwinds one layer at a time: editor → board-name field →
    /// suggestion list → pending vim sequence → visual mode → search mode →
    /// preview → panel.
    private func handleEscape() {
        // The open editor is the innermost layer: leaving it (or answering
        // its discard confirm) never touches what is underneath.
        if editing != nil {
            editEscape()
            return
        }
        if namingPinboard {
            cancelPinboardName()
            return
        }
        if suggestionsVisible {
            suggestionDismissedKey = suggestionContext?.key
            return
        }
        if vim.hasPending {
            vim.reset()
            return
        }
        if inputMode == .visual {
            setMode(.normal)
            return
        }
        if vimModeEnabled, inputMode == .insert {
            setMode(.normal)
            return
        }
        // A revealed secret is its own Esc layer: the first press hides the
        // plaintext, the second closes the pane.
        if secretReveal != nil {
            concealSecret()
            return
        }
        if previewVisible {
            closePreview()
            return
        }
        actions.close()
    }

    /// A hint in its place at the bottom edge of whatever it floats over,
    /// or nothing at all. One helper for both bubbles so they sit the same
    /// distance off the edge and fade in and out the same way.
    @ViewBuilder
    private func hintBubble(_ text: String?) -> some View {
        ZStack {
            if let text {
                HintBubble(text: text)
                    .padding(.bottom, Design.Space.normal)
            }
        }
        .animation(Design.Motion.standard, value: text)
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
        if showsCheatSheet {
            cheatSheet
        } else if visible.isEmpty {
            if filter.isIdentity {
                // Nothing filtered anything out, so the store really is empty.
                ContentUnavailableView {
                    Label(loc("No Clips Yet"), systemImage: "clipboard")
                } description: {
                    Text(loc("Copy something anywhere in macOS and it will appear here."))
                }
                .frame(maxWidth: .infinity)
                .frame(height: Design.Size.cardStripHeight)
            } else if filter.board != .all, filter.search.isEmpty,
                      filter.type == .all, filter.source == nil {
                // An empty board scope is not a failed search: nothing has
                // been filed here yet, and the way to fix that is a pin or
                // a drop, not a different query.
                ContentUnavailableView {
                    Label(boardScopeEmptyLabel, systemImage: "pin")
                } description: {
                    Text(loc("Pin a clip, or drag one onto the chip above."))
                }
                .frame(maxWidth: .infinity)
                .frame(height: Design.Size.cardStripHeight)
            } else {
                ContentUnavailableView {
                    Label(loc("No Matches"), systemImage: "magnifyingglass")
                } description: {
                    VStack(spacing: Design.Space.roomy) {
                        // Constraints name what emptied the list - "No
                        // clips from Slack, before 1 September." - so the
                        // user can see the answer "none" came from them and
                        // not from the store being empty.
                        if let summary = filter.constraintSummary {
                            Text(loc("No clips %@.", summary))
                        } else {
                            Text(loc("Try a different search or filter."))
                        }
                        if !filter.query.constraints.isEmpty {
                            Button(loc("Clear filters")) { clearConstraints() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help(loc("Remove the operators and the type chip, keep the words"))
                        }
                    }
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
            let selected = Set(selection.selectedIDs(in: visible.map(\.uuid)))
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: Design.Size.cardSpace) {
                        ForEach(Array(visible.enumerated()), id: \.element.uuid) { index, item in
                            ClipCardView(
                                item: item,
                                index: index,
                                isSelected: selected.contains(item.uuid),
                                queuePosition: queue.position(of: item),
                                pinboards: pinboards,
                                isSavingNote: uiState.notesInFlight.contains(item.uuid),
                                onPaste: { plain in actions.paste(item, plain) },
                                onCopyOnly: { actions.copyOnly(item) },
                                onEdit: { startEditing(item) },
                                onCopyExtractedText: { actions.copyExtractedText(item) },
                                onTransform: { transform in
                                    actions.applyTransform(item, transform)
                                },
                                onShowQR: { actions.showQR(item) },
                                onToggleQueue: { actions.toggleQueue(item) },
                                onSaveNote: { actions.saveNote(item) },
                                onAddToCalendar: { actions.addToCalendar(item) },
                                onOpenNote: { actions.openNote(item) },
                                onRevealInFinder: { actions.revealInFinder(item) },
                                onRevealSecret: { revealSecret(item) },
                                onDemoteSecret: { demoteSecret(item) },
                                onMarkSecret: { actions.promoteSecret(item) },
                                onFile: { file(item, to: $0) },
                                onOpenPinboardPicker: { pinboardPickerItem = item }
                            )
                            .id(item.uuid)
                            .contentShape(Rectangle())
                            // The modifiers are read from the event queue
                            // rather than from the gesture: SwiftUI's tap
                            // gesture reports where the click landed and
                            // nothing about what was held down with it.
                            .onTapGesture {
                                handleClick(on: item, at: index, in: visible)
                            }
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
                .scrollPosition($stripPosition)
                // Reopening the panel puts the deck back at the newest clip.
                // The filter and the selection are already reset on this
                // token; the strip's offset is not, and a panel that reopens
                // halfway down yesterday's history is one the newest clip is
                // missing from. An edge rather than an item id: it is the
                // same instruction whatever the reset leaves in the strip.
                .onChange(of: uiState.focusToken) {
                    stripPosition.scrollTo(edge: .leading)
                }
                // The same fading edge and chevron the preview pane uses for
                // text that runs past its bottom. The strip hides its scroll
                // bar and cuts its cards evenly, so nothing else in it says
                // that there are more clips to the right.
                .scrollMoreHint(.horizontal)
                .frame(height: Design.Size.cardStripHeight)
                .overlay(alignment: .bottom) { hintBubble(stripHint) }
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

    /// The empty-state title for a pinned scope that holds nothing.
    private var boardScopeEmptyLabel: String {
        switch filter.board {
        case .all: return loc("No Clips Yet")
        case .pinned: return loc("Nothing in Pinned yet")
        case .board(let uuid):
            let name = pinboards.first { $0.uuid == uuid }?.name ?? loc("Pinboard")
            return loc("Nothing in %@ yet", name)
        }
    }

    // MARK: Footer

    private func footer(_ visible: [ClipItem]) -> some View {
        HStack(spacing: Design.Space.normal) {
            // The type filter now lives in the chip row under the search
            // field; the source-app filter stays a menu because it is an
            // open-ended list.
            Menu {
                Picker(loc("Source App"), selection: $filter.source) {
                    Text(loc("All Apps")).tag(String?.none)
                    ForEach(sourceAppNames, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
            } label: {
                Label(filter.source ?? loc("All Apps"), systemImage: "app.badge")
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
                Label(loc("Capture paused"), systemImage: "pause.circle.fill")
                    .font(Design.Typography.footnote)
                    .foregroundStyle(Design.Palette.warning)
                    .lineLimit(1)
            }

            if !queue.isEmpty {
                Button {
                    actions.pasteQueue()
                } label: {
                    Label(loc("Paste %d", queue.count), systemImage: "list.number")
                        .font(Design.Typography.footnote)
                }
                .buttonStyle(.borderless)
                .disabled(queue.isPasting)
                .help(loc("Paste queued clips in order (⇧Q in vim normal mode)"))

                Button(loc("Clear")) { queue.clear() }
                    .buttonStyle(.borderless)
                    .font(Design.Typography.footnote)
                    .help(loc("Empty the paste queue"))
            }

            Spacer(minLength: Design.Space.tight)

            // The status line's toast: transient answers to what just
            // happened (an edit saved, a draft restored).
            if let statusMessage {
                Text(statusMessage)
                    .font(Design.Typography.footnote)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
                    .transition(.opacity)
            }

            // The whole store's count when it could be had, and the loaded
            // page with a "+" only when it could not: the list is paged, so
            // `visible.count` on its own is what is on screen rather than
            // what matches.
            Text(matchCount.map { loc("%d clips", $0) }
                ?? (hasMorePages ? loc("%d+ clips", visible.count) : loc("%d clips", visible.count)))
                .font(Design.Typography.footnote)
                .monospacedDigit()
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
                .fixedSize()
                .help(hasMorePages
                      ? loc("Showing the newest %d matches — scroll for more", visible.count)
                      : loc("All matching clips are shown"))

            Button(role: .destructive) {
                showNukeConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: Design.Size.rowActionButton, height: Design.Size.rowActionButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(loc("Delete entire history"))
        }
        .confirmationDialog(
            loc("Delete entire clipboard history?"),
            isPresented: $showNukeConfirmation,
            titleVisibility: .visible
        ) {
            Button(loc("Delete Everything"), role: .destructive) {
                // A batch delete, not a loop over `items` — the query only
                // holds the current page, and deleting that would leave the
                // rest of the history behind.
                //
                // Board memberships are relationships, which the batch
                // delete does not follow, so detach them first, same as
                // `ClipStore.nukeAll`, or the boards keep orders pointing
                // at dead rows. The boards themselves survive, empty.
                for board in pinboards {
                    for clip in board.clips {
                        clip.pinboard = nil
                        clip.pinboardOrder = nil
                    }
                }
                try? modelContext.delete(model: ClipItem.self)
                try? modelContext.save()
                sourceAppNames = []
                // Everything is gone, including any clip mid-edit.
                editing = nil
                editDrafts = [:]
                lastEditUndo = nil
                sourceAppCounts = []
            }
        } message: {
            Text(loc("This permanently removes all clips, including pinned ones."))
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
        // A range says how big it is rather than where its cursor is: "12 of
        // 300" is the same sentence whether one clip or thirty are about to be
        // pasted, which is the one thing the listener needs to know.
        let chosen = selection.isExtended ? selectedItems.count : 1
        guard chosen == 1 else {
            announce(loc("%d clips selected, %@", chosen, item.announcementSummary))
            return
        }
        announce(loc("%d of %d, %@", index + 1, visibleItems.count, item.announcementSummary))
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
        // Space on a locked secret is its Show button: the pane stays where
        // a reveal lives, so the second press opens the cipher rather than
        // closing the pane. Once revealed, Space closes as usual.
        if let target, target.isSecret, previewVisible,
           secretReveal?.uuid != target.uuid {
            revealSecret(target)
            return
        }
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
        announce(loc("Preview shown, %@", item.announcementSummary))
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
        quickLookHintDismissed = true
        announce(loc("Quick Look, %@", item.announcementSummary))
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
        previewSelection = nil
        secretReveal = nil
        uiState.secretNotice = nil
        announce(loc("Preview hidden"))
    }

    /// Keep the open preview in sync with the selection / visible items.
    ///
    /// When nothing is left to preview the pane is closed outright — leaving
    /// `previewVisible` true with a nil item made the next Space look dead.
    private func syncPreviewItem() {
        // An open editor is pinned to the clip it is editing: the selection
        // cannot move while it is up, so the pane must not either.
        guard previewVisible, editing == nil else { return }
        guard let item = selectedItem ?? visibleItems.first else {
            previewVisible = false
            previewItem = nil
            return
        }
        previewItem = item
        // The pane now shows a different clip: a reveal belongs to the row
        // it was opened on and cannot follow the selection to another.
        if secretReveal?.uuid != item.uuid {
            secretReveal = nil
            uiState.secretNotice = nil
        }
    }

    /// Ask the vault for a locked secret's plaintext. On success the pane
    /// gets what to show and for how long (D2's 30 s); a refused prompt gets
    /// the quiet notice instead. The prompt itself happens inside
    /// `actions.revealSecret` — this only moves its answer onto the screen.
    private func revealSecret(_ item: ClipItem) {
        uiState.secretNotice = nil
        Task { @MainActor in
            switch await actions.revealSecret(item) {
            case .success(let text):
                secretReveal = (
                    uuid: item.uuid,
                    text: text,
                    hidesAt: Date(timeIntervalSinceNow: SecretSettings.revealSeconds)
                )
                announce(loc("Revealed. Hides in %d seconds.", Int(SecretSettings.revealSeconds)))
            case .failure(let error):
                secretReveal = nil
                uiState.secretNotice = SecretsService.isAuthCancel(error)
                    ? loc("Not authenticated.")
                    : loc("This secret could not be opened.")
            }
        }
    }

    /// Put the plaintext away — countdown over, Hide pressed, Esc's first
    /// layer. The slot clears before the announcement so nil is never spoken.
    private func concealSecret() {
        guard secretReveal != nil else { return }
        secretReveal = nil
        announce(loc("Hidden."))
    }

    /// "Not a Secret": the service authenticates and demotes the row, and
    /// the pane that was showing ciphertext goes back to an ordinary clip.
    private func demoteSecret(_ item: ClipItem) {
        Task { @MainActor in
            if await actions.demoteSecret(item) {
                secretReveal = nil
                uiState.secretNotice = nil
                announce(loc("No longer a secret."))
            } else {
                uiState.secretNotice = loc("This secret could not be opened.")
            }
        }
    }

    // MARK: Editing

    /// Open the clip's text for editing in place: the preview pane becomes
    /// the editor, opening itself when it was closed, and a draft the panel
    /// was hiding with comes back with it.
    private func startEditing(_ item: ClipItem) {
        guard ClipDisplay.canEdit(item), !item.isDeleted else { return }
        // Already editing this clip: reopening would reset the live draft.
        if editing?.item.uuid == item.uuid { return }
        // Switching clips mid-edit keeps the outgoing dirty draft, the same
        // rule as closing the panel: it comes back if that clip is edited
        // again this session.
        if let current = editing, current.hasChanges {
            editDrafts[current.item.uuid] = current.draft
        }
        let stashed = editDrafts[item.uuid]
        editing = ClipEdit.Session(item: item, draft: stashed, restoredDraft: stashed != nil)
        previewItem = item
        previewVisible = true
        // Focus moves to the draft, so the search field must let it go;
        // pending vim sequences are discarded rather than finished inside it.
        searchFocused = false
        vim.reset()
        announce(loc("Editing clip"))
        if stashed != nil { showStatus(loc("Unsaved draft restored.")) }
    }

    /// ⌘I and vim's `e`: edit the cursor clip when its kind allows it, and
    /// say nothing at all on a clip that cannot be. The keys have no menu
    /// to hide behind, so they simply decline.
    private func editSelected() {
        guard let item = selectedItem else { return }
        startEditing(item)
    }

    /// One Escape inside the editor, or a press of its Cancel button, which
    /// is Esc's mouse-shaped twin. The layering (leave at once, warn once,
    /// discard) is `ClipEdit.escapeAction`'s.
    private func editEscape() {
        guard var session = editing else { return }
        switch ClipEdit.escapeAction(hasChanges: session.hasChanges, discardArmed: session.discardArmed) {
        case .leave:
            // Nothing was thrown away, so nothing is announced as thrown
            // away: focus returning to the search field is the signal.
            endEdit()
        case .confirmDiscard:
            session.discardArmed = true
            editing = session
            announce(loc("Discard changes? Esc again to discard, ⌘S to save."))
        case .discard:
            editDrafts.removeValue(forKey: session.item.uuid)
            endEdit(announcing: loc("Discarded"))
        }
    }

    /// Save the draft through the store (kind and hash re-derived,
    /// duplicates merged, derived fields reset), then paste it through the
    /// normal path when asked (PasteService, plain-text app list included).
    private func saveEdit(andPaste: Bool) {
        guard let session = editing else { return }
        // The clip may have been deleted (context menu) while it was being
        // edited; there is nothing left to save onto.
        guard !session.item.isDeleted else {
            editing = nil
            return
        }
        // An unchanged draft has nothing to write: leave the editor (and
        // still paste, when that was the exit asked for) rather than
        // clearing derived fields over content that never moved.
        guard session.hasChanges else {
            endEdit()
            if andPaste { actions.paste(session.item, false) }
            return
        }
        guard let snapshot = actions.applyEdit(session.item, session.draft) else { return }
        lastEditUndo = snapshot
        editDrafts.removeValue(forKey: session.item.uuid)
        endEdit(announcing: loc("Saved"))
        showStatus(loc("Clip edited · Undo (⌘Z)"))
        if andPaste {
            actions.paste(session.item, false)
        }
    }

    /// ⌘Z after a save: put the clip back the way the snapshot remembers it.
    /// True when there was an edit to take back.
    private func undoLastEdit() -> Bool {
        guard let snapshot = lastEditUndo else { return false }
        lastEditUndo = nil
        actions.undoEdit(snapshot)
        showStatus(loc("Edit undone"))
        return true
    }

    /// Leave the editor, whichever way out was taken, and hand the keys back
    /// to the panel. The search field is its usual focus.
    private func endEdit(announcing message: String? = nil) {
        editing = nil
        searchFocused = true
        if let message { announce(message) }
    }

    /// A line in the footer's status area for five seconds, and spoken so
    /// VoiceOver hears it too.
    private func showStatus(_ message: String) {
        statusMessage = message
        statusToken &+= 1
        announce(message)
    }

    // MARK: Vim mode

    private func setMode(_ mode: PanelInputMode) {
        guard inputMode != mode else { return }
        // Leaving visual drops the range, as it does in vim: the mode and the
        // range are the same gesture, so one outliving the other would leave
        // a selection nothing on screen explains.
        if inputMode == .visual { selection.collapse() }
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
        // An open editor suspends vim wholesale: every key belongs to the
        // draft, bound or not.
        guard editing == nil else { return .ignored }
        guard readsVimKeys, !auxiliaryFieldActive else { return .ignored }
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

        // `?` is a panel gesture, not a vim command: it makes the query
        // itself "?", which is what shows the operator cheat-sheet. Going
        // to insert mode leaves the caret after it, ready to type over. A
        // pending `g` or `d` keeps first refusal of the keystroke.
        if key == "?", !vim.hasPending {
            filter.search = "?"
            setMode(.insert)
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
            navHintDismissed = true
            let ids = visibleIDs
            let index = VimNavigator.newIndex(
                for: command,
                index: selection.movementOrigin(in: ids),
                count: ids.count
            )
            if inputMode == .visual {
                selection.extend(to: index, in: ids)
            } else {
                selection.select(index: index, in: ids)
            }
            refreshPreview(settling: step == .moveSettlingPreview)
        case .paste:
            pasteSelected(plainOnly: false)
        case .pastePlain:
            pasteSelected(plainOnly: true)
        case .pin:
            let chosen = selectedItems
            guard !chosen.isEmpty else { return }
            for item in chosen {
                // `unpin()` rather than a toggle: a clip that leaves the
                // pinned set also leaves its board: membership needs the
                // pin (PRD 06). Pinning goes through `togglePinned` so an
                // expiring secret drops its timer.
                if item.isPinned { item.unpin() } else { item.togglePinned() }
            }
            try? modelContext.save()
        case .pinboard:
            openPinboardPicker()
        case .delete:
            let chosen = selectedItems
            guard !chosen.isEmpty else { return }
            pendingDeletes = chosen
        case .queueToggle:
            let chosen = selectedItems
            guard !chosen.isEmpty else { return }
            for item in chosen { actions.toggleQueue(item) }
            // One clip queued steps to the next, so that `qqq` queues three.
            // A whole selection has already said which clips it means, and
            // stepping off it would throw that away.
            guard chosen.count == 1 else { return }
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
        case .addToCalendar:
            addSelectedToCalendar()
        case .edit:
            editSelected()
        case .visual:
            setMode(inputMode == .visual ? .normal : .visual)
        }
    }

    /// Delete the clip `dd` asked about, once confirmed, and move the
    /// selection to its neighbour by uuid (no index arithmetic that assumes
    /// whether the @Query has refreshed yet).
    private func confirmDelete() {
        let items = pendingDeletes
        guard !items.isEmpty else { return }
        pendingDeletes = []
        // Both questions are asked while the clips are still in the context: a
        // `ClipItem` the delete has taken out is no longer safe to read.
        let removed = items.map(\.uuid)
        let previewGoes = previewItem.map { removed.contains($0.uuid) } ?? false
        selection.selectNeighbour(ofAll: removed, in: visibleIDs)
        for item in items { modelContext.delete(item) }
        try? modelContext.save()
        // A clip deleted out from under its editor takes the session and
        // any stashed draft with it.
        if let session = editing, removed.contains(session.item.uuid) {
            editing = nil
        }
        for uuid in removed { editDrafts.removeValue(forKey: uuid) }
        if previewGoes { previewItem = nil }
        syncPreviewItem()
    }

    // MARK: Selection & paste

    /// Move the selection one step, at the pace `HeldKeyPacer` allows.
    ///
    /// `phase` is the keystroke's phase: a `.down` press always moves, a
    /// `.repeat` from a held key moves only if enough time has passed since
    /// the last step the user saw. `extending` is ⇧ held with the key, which
    /// leaves the far end of the range behind instead of carrying it along.
    private func moveSelection(_ delta: Int, extending: Bool = false, phase: KeyPress.Phases = .down) {
        let step = pacer.step(isRepeat: phase.contains(.repeat), now: Self.now())
        guard step != .drop else { return }
        navHintDismissed = true
        let ids = visibleIDs
        if extending {
            selection.extend(by: delta, in: ids)
        } else {
            selection.move(by: delta, in: ids)
        }
        refreshPreview(settling: step == .moveSettlingPreview)
    }

    /// A click on a card: paste it, extend the selection to it, or add it to
    /// the selection — whichever the modifiers held with the click asked for.
    private func handleClick(on item: ClipItem, at index: Int, in visible: [ClipItem]) {
        let ids = visible.map(\.uuid)
        switch ClipClick.intent(for: NSEvent.modifierFlags) {
        case .paste:
            actions.paste(item, false)
        case .extend:
            selection.extend(to: index, in: ids)
        case .toggle:
            selection.toggle(index: index, in: ids)
        }
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

    /// Paste the selection. Does nothing when it no longer exists — falling
    /// back to row 0 would paste the newest clip instead.
    ///
    /// Several clips paste in the order they sit in the strip, left to right,
    /// so what arrives in the target app reads the way the panel does.
    private func pasteSelected(plainOnly: Bool) {
        let chosen = selectedItems
        guard let first = chosen.first else { return }
        guard chosen.count > 1 else {
            actions.paste(first, plainOnly)
            return
        }
        actions.pasteMany(chosen, plainOnly)
    }

    /// Put the selected clip back on the pasteboard, leaving the panel open.
    ///
    /// The panel stays up because ⌘C is not a way out of it: it is the
    /// gesture for taking a clip with you, and the next thing the user does
    /// may well be to take another one.
    ///
    /// Several clips go as one block of text, one clip per line, because the
    /// pasteboard holds one thing: a run of ⌘C presses would leave only the
    /// last of them. The clips themselves — the image, the rich text, the file
    /// references — cannot survive that flattening, so this is text and only
    /// text; `pasteMany` is the path that keeps each clip whole.
    private func copySelected() {
        let chosen = selectedItems
        guard let first = chosen.first else { return }
        // A secret answers ⌘C in two voices. Revealed: the plaintext (or the
        // selected part of it) goes out concealed — the reveal that put it
        // on screen was already the authentication. Locked: the copy is an
        // open behind Touch ID, which `copyOnly`'s secret branch performs;
        // nothing is announced because whether it copied is the prompt's to
        // decide.
        if first.isSecret {
            if let reveal = secretReveal, reveal.uuid == first.uuid {
                let text = PreviewCopy.copyTarget(
                    selection: previewVisible ? previewSelection : nil,
                    clipText: reveal.text
                ) ?? reveal.text
                actions.copyConcealed(first, text)
                announce(loc("Copied"))
            } else {
                actions.copyOnly(first)
            }
            return
        }
        // A visible selection in the preview is what ⌘C means while it is
        // there: copy exactly it, and leave the panel open.
        if previewVisible, let selected = PreviewCopy.copyTarget(selection: previewSelection, clipText: nil) {
            actions.copyText(first, selected)
            announce(loc("Copied"))
            return
        }
        guard chosen.count > 1 else {
            actions.copyOnly(first)
            announce(loc("Copied"))
            return
        }
        let text = ClipSelection.copyText(for: chosen)
        guard !text.isEmpty else { return }
        actions.copyText(first, text)
        announce(loc("%d clips copied", chosen.count))
    }

    /// Write (or rewrite) the cursor clip's note.
    ///
    /// The cursor and not the whole selection: a note is one document about
    /// one clip, and the composer, the destination and the failure alert are
    /// all built around that. The same goes for the calendar, the QR sheet and
    /// Quick Look below — a multi-selection widens what pastes, copies and
    /// deletes, and leaves the single-clip actions pointed at the cursor.
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

    /// Put the selected clip's appointment in the calendar.
    ///
    /// Gated on the same cheap predicate as the card's menu item, so the key
    /// and the menu offer the action on the same clips. The gate only says the
    /// clip could hold a date; whether it actually does is settled by the
    /// detector, and a clip that turns out to hold none says so in an alert.
    private func addSelectedToCalendar() {
        guard let item = selectedItem, ClipDisplay.mightHaveEvent(item) else { return }
        actions.addToCalendar(item)
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
        .accessibilityLabel(loc("Preview height"))
        .accessibilityValue(loc("%d points", Int(height)))
        .accessibilityHint(loc("Drag up for a taller preview"))
        .accessibilityAdjustableAction { direction in
            let step = Design.Space.vast
            let target = direction == .increment ? height + step : height - step
            onResize(PanelGeometry.clampPreviewHeight(target, ceiling: ceiling))
        }
    }
}
