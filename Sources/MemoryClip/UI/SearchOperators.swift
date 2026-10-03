import Foundation

/// The `key:` operators the search field understands.
///
/// Keys match case-insensitively and name something the store can actually
/// answer. `in:` names a pinboard by a prefix of its name (`in:pinned` is
/// the Pinned board); a name nothing matches is an empty result, not a
/// warning - the vocabulary is the user's own, like `app:`.
enum ClipOperatorKey: String, CaseIterable, Sendable {
    case app
    case `is`
    case `in`
    case type
    case after
    case before
    case on

    /// The values the suggestion list offers for keys with a fixed
    /// vocabulary. Empty for `app:` and `in:`, whose lists come from the
    /// store's apps and boards.
    var fixedValues: [String] {
        switch self {
        case .app, .in:
            return []
        case .is:
            return ClipStateValue.allCases.map(\.rawValue)
        case .type:
            return TypeFilter.typeableValues.map(\.rawValue)
        case .after, .before, .on:
            return ["today", "yesterday", "7d"]
        }
    }

    /// The grammar the unknown-value tooltip names. `app:` and `in:` take
    /// any text, so they never need a list (and never warn).
    var knownValues: [String] {
        switch self {
        case .app, .in: return []
        case .is: return ClipStateValue.allCases.map(\.rawValue)
        case .type: return TypeFilter.typeableValues.map(\.rawValue)
        case .after, .before, .on: return ["today", "yesterday", "2026-09-01", "7d", "2w", "3m"]
        }
    }
}

/// The states `is:` knows how to test.
enum ClipStateValue: String, CaseIterable, Sendable {
    case pinned, screenshot, noted, event, translated, secret

    /// Whether the clip is in this state. `noted`, `event` and `translated`
    /// are nil-checks on the fields those features write: a clip "has a
    /// note" exactly when `notePath` was filled in. `secret` reads the
    /// sealed-row flag, the one part of a secret the store keeps readable.
    func matches(_ item: some ClipDisplayable) -> Bool {
        switch self {
        case .pinned: return item.isPinned
        case .screenshot: return item.isScreenshot
        case .noted: return item.notePath != nil
        case .event: return item.calendarEventID != nil
        case .translated: return item.translatedText != nil || item.clipTranslationText != nil
        case .secret: return item.isSecret
        }
    }

    /// The state in words, for the empty-state sentence ("from Slack,
    /// pinned, before 1 September").
    var phrase: String {
        switch self {
        case .pinned: return loc("pinned")
        case .screenshot: return loc("screenshots")
        case .noted: return loc("with a note")
        case .event: return loc("in the calendar")
        case .translated: return loc("translated")
        case .secret: return loc("secret")
        }
    }

    /// The same, negated ("not pinned").
    var negatedPhrase: String {
        switch self {
        case .pinned: return loc("not pinned")
        case .screenshot: return loc("not screenshots")
        case .noted: return loc("without a note")
        case .event: return loc("not in the calendar")
        case .translated: return loc("not translated")
        case .secret: return loc("not secret")
        }
    }
}

extension TypeFilter {
    /// The values `type:` recognises - the real kind filters, not `all`,
    /// which filters nothing and reads as a mistyped value.
    static var typeableValues: [TypeFilter] { [.text, .image, .link, .file, .color] }

    /// The chip in words, for the empty-state sentence ("images"). `.all`
    /// never reaches it: the summary only includes it when it is filtering.
    var phrase: String {
        switch self {
        case .all: return loc("All")
        case .text: return loc("text")
        case .image: return loc("images")
        case .link: return loc("links")
        case .file: return loc("files")
        case .color: return loc("colors")
        }
    }
}

/// One whitespace-run of a query, classified. `key` and `value` are set on
/// operators - `key:value`, optionally `-`-negated, the value's quotes
/// stripped - and `nil` on words. A `key:` whose value came out empty is a
/// word: the suggestion list is what carries that moment, not the grammar.
struct QueryToken: Equatable {
    /// The token's whole extent, `-` and quotes included.
    var range: Range<String.Index>
    /// The `-key:` run that opens an operator - nil on words.
    var head: Range<String.Index>?
    var key: ClipOperatorKey?
    var value: String?
    var negated: Bool
}

/// An operator token with its validity resolved, as the search field paints
/// it: the pill is `range`, the secondary-coloured `key:` is `head`, and an
/// unknown `valueIsKnown` gets the warning underline.
struct SearchOperatorToken: Equatable {
    var range: Range<String.Index>
    var head: Range<String.Index>
    var key: ClipOperatorKey
    var value: String
    var negated: Bool
    var valueIsKnown: Bool
}

/// The non-word half of a query: every `key:value` operator resolved into
/// the bounds the filter applies.
///
/// `ClipFilter.predicate` pushes the cheap clauses (one `app:` prefix, the
/// `isPinned` flag, the `createdAt` bounds, the `type:` kind set) into SQL;
/// `matches(_:)` applies all of them in `refine(_:)`. The two must agree -
/// the predicate may be wider than the final rule, never narrower, or pages
/// could drop clips a later constraint would have kept.
struct ClipConstraints: Equatable {
    /// `app:` prefixes every match's source app must start with.
    var apps: [String] = []
    /// `-app:` prefixes no match's app may start with.
    var notApps: [String] = []
    /// `is:` states required of a match, and `-is:` states forbidden.
    var states: Set<ClipStateValue> = []
    var notStates: Set<ClipStateValue> = []
    /// `type:` filters every match must satisfy, and `-type:` ones none may.
    var types: Set<TypeFilter> = []
    var notTypes: Set<TypeFilter> = []
    /// `in:` prefixes naming the boards a match must sit in, and `-in:`
    /// ones it must not. Prefixes, not names: `in:pin` reaches "Pinned"
    /// the pseudo-board and any board whose name starts that way.
    var boards: [String] = []
    var notBoards: [String] = []
    /// `createdAt >= after` - from `after:` or `-before:`, resolved against
    /// the `now` the query was parsed with.
    var after: Date?
    /// `createdAt < before` - from `before:` or `-after:`.
    var before: Date?
    /// Whole local days a match may not fall inside (`-on:`).
    var excludedDays: [DateInterval] = []
    /// The constraints in words, in the order they were typed - "from
    /// Slack", "before 1 September" - for "No clips …" in the empty state.
    var phrases: [String] = []

    /// Whether any operator is narrowing the query.
    var isEmpty: Bool {
        apps.isEmpty && notApps.isEmpty && states.isEmpty && notStates.isEmpty
            && types.isEmpty && notTypes.isEmpty && boards.isEmpty && notBoards.isEmpty
            && after == nil && before == nil && excludedDays.isEmpty
    }

    /// `app:`'s match rule: an anchored prefix of the source app name,
    /// case- and diacritic-insensitive the way `localizedStandardContains`
    /// is - so `app:saf` reaches "Safari" and `app:xcode` reaches "Xcode"
    /// without the user matching the app's capitalisation. `.anchored`
    /// asks for the same thing while stopping the scan at the prefix, and
    /// the literal `hasPrefix` first - already a match on its own - keeps
    /// the common case off the ICU path.
    static func hasAppPrefix(_ name: String?, _ prefix: String) -> Bool {
        guard let name else { return false }
        if name.hasPrefix(prefix) { return true }
        return name.range(
            of: prefix,
            options: [.anchored, .caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        ) != nil
    }

    /// `in:`'s rule over one prefix: the pseudo-board `pinned` covers a clip
    /// that is pinned but filed nowhere, and any board whose name starts
    /// with the prefix counts its members - the same anchored, folding
    /// compare `app:` uses. A clip is never both: membership needs the pin,
    /// and `pinboardUUID` decides which side it lands on.
    static func matchesBoard(
        _ item: some ClipDisplayable,
        prefix: String,
        boards: [(name: String, uuid: UUID)]
    ) -> Bool {
        if hasAppPrefix(ClipStateValue.pinned.rawValue, prefix),
           item.isPinned, item.pinboardUUID == nil {
            return true
        }
        guard let uuid = item.pinboardUUID else { return false }
        return boards.contains { $0.uuid == uuid && hasAppPrefix($0.name, prefix) }
    }

    /// Whether the clip satisfies every constraint - the Swift-side twin of
    /// the clauses `ClipFilter.predicate` pushes into SQL. `boards` is the
    /// store's pinboards as (name, uuid) pairs: `in:` resolves names to the
    /// identifier `ClipItem` actually stores, and a name nothing claims
    /// matches no clip.
    func matches(
        _ item: some ClipDisplayable,
        boards: [(name: String, uuid: UUID)] = []
    ) -> Bool {
        for prefix in apps where !Self.hasAppPrefix(item.sourceAppName, prefix) { return false }
        for prefix in notApps where Self.hasAppPrefix(item.sourceAppName, prefix) { return false }
        for state in states where !state.matches(item) { return false }
        for state in notStates where state.matches(item) { return false }
        for type in types where !type.matches(item.kind, isScreenshot: item.isScreenshot) { return false }
        for type in notTypes where type.matches(item.kind, isScreenshot: item.isScreenshot) { return false }
        for prefix in self.boards where !Self.matchesBoard(item, prefix: prefix, boards: boards) { return false }
        for prefix in notBoards where Self.matchesBoard(item, prefix: prefix, boards: boards) { return false }
        if let after, item.createdAt < after { return false }
        if let before, item.createdAt >= before { return false }
        for day in excludedDays where day.contains(item.createdAt) { return false }
        return true
    }

    /// Fold one operator into the constraint set. Returns whether the value
    /// was in the key's vocabulary - an unrecognised value contributes
    /// nothing, and the flag is what the search field underlines.
    mutating func apply(
        _ key: ClipOperatorKey,
        value: String,
        negated: Bool,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        switch key {
        case .app:
            if negated {
                guard !notApps.contains(value) else { return true }
                notApps.append(value)
                phrases.append(loc("not from %@", value))
            } else {
                guard !apps.contains(value) else { return true }
                apps.append(value)
                phrases.append(loc("from %@", value))
            }
            return true
        case .is:
            guard let state = ClipStateValue(rawValue: value.lowercased()) else { return false }
            if negated {
                if notStates.insert(state).inserted { phrases.append(state.negatedPhrase) }
            } else if states.insert(state).inserted {
                phrases.append(state.phrase)
            }
            return true
        case .type:
            guard let type = TypeFilter(rawValue: value.lowercased()), type != .all else { return false }
            if negated {
                if notTypes.insert(type).inserted { phrases.append(loc("not %@", type.phrase)) }
            } else if types.insert(type).inserted {
                phrases.append(type.phrase)
            }
            return true
        case .in:
            // Any board name is a value: the list is the user's own, so a
            // miss is an empty board rather than an unrecognised word.
            if negated {
                guard !notBoards.contains(value) else { return true }
                notBoards.append(value)
                phrases.append(loc("not in pinboard %@", value))
            } else {
                guard !boards.contains(value) else { return true }
                boards.append(value)
                phrases.append(loc("in pinboard %@", value))
            }
            return true
        case .after, .before, .on:
            return applyDate(key, value: value, negated: negated, now: now, calendar: calendar)
        }
    }

    /// One operand of a date operator, resolved against `now`/`calendar`:
    /// either a named local day or a "N ago" reach back from `now`.
    enum DateOperand: Equatable {
        /// `2026-09-01`, `today`, `yesterday`: one local calendar day,
        /// start inclusive / end exclusive however long it ran (a DST
        /// transition day is 23 or 25 hours, not 24).
        case day(DateInterval)
        /// `7d`, `2w`, `3m`: the instant `now - N units`, remembering the
        /// count for "in the last 7 days" / "more than 7 days ago".
        case ago(instant: Date, count: Int, unit: RelativeUnit)

        enum RelativeUnit: String, Equatable {
            case day = "d"
            case week = "w"
            case month = "m"

            var calendarComponent: Calendar.Component {
                switch self {
                case .day: return .day
                case .week: return .weekOfYear
                case .month: return .month
                }
            }

            /// "in the last 7 days", for `after:7d`.
            func lastPhrase(_ count: Int) -> String {
                switch self {
                case .day: return loc("in the last %d days", count)
                case .week: return loc("in the last %d weeks", count)
                case .month: return loc("in the last %d months", count)
                }
            }

            /// "more than 7 days ago", for `before:7d`.
            func agoPhrase(_ count: Int) -> String {
                switch self {
                case .day: return loc("more than %d days ago", count)
                case .week: return loc("more than %d weeks ago", count)
                case .month: return loc("more than %d months ago", count)
                }
            }
        }

        /// The day the operand names. Named days are one already; `7d`
        /// lands on whatever local day `now - 7` fell in - which is what
        /// `on:7d` ("that day last week") means.
        func dayInterval(in calendar: Calendar) -> DateInterval {
            switch self {
            case .day(let interval): return interval
            case .ago(let instant, _, _):
                return calendar.dateInterval(of: .day, for: instant)
                    ?? DateInterval(start: instant, duration: 0)
            }
        }

        /// The `createdAt >=` a day or instant contributes. A named day
        /// starts at its local midnight (`after:2026-09-01` is "since 1
        /// September", including the day itself); `7d` is the instant.
        var lowerBound: Date {
            switch self {
            case .day(let interval): return interval.start
            case .ago(let instant, _, _): return instant
            }
        }

        /// The `createdAt <` one contributes: the start of a named day
        /// (`before:2026-09-01` ends on 31 August), the instant for `7d`
        /// ("more than 7 days ago").
        var upperBound: Date {
            switch self {
            case .day(let interval): return interval.start
            case .ago(let instant, _, _): return instant
            }
        }
    }

    /// The value of a date operator, resolved against `now`/`calendar`.
    /// Returns nil for anything outside the documented forms - `after:soon`
    /// stays an unrecognised value, flagged rather than silently dropped.
    static func dateOperand(_ value: String, now: Date, calendar: Calendar) -> DateOperand? {
        switch value.lowercased() {
        case "today":
            return calendar.dateInterval(of: .day, for: now).map(DateOperand.day)
        case "yesterday":
            guard let back = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .day, for: back).map(DateOperand.day)
        default: break
        }
        let lowered = value.lowercased()
        // `7d`, `2w`, `3m` - count then unit.
        if let last = lowered.last,
           let unit = DateOperand.RelativeUnit(rawValue: String(last)),
           let count = Int(lowered.dropLast()), count > 0,
           let instant = calendar.date(byAdding: unit.calendarComponent, value: -count, to: now) {
            return .ago(instant: instant, count: count, unit: unit)
        }
        // `2026-09-01` - strict ISO shape, and a day that must be real:
        // Calendar would roll 2026-02-31 into March, so the components are
        // checked back out rather than trusted.
        let parts = lowered.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 3,
           parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
           parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
           let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
           let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
           calendar.component(.year, from: date) == year,
           calendar.component(.month, from: date) == month,
           calendar.component(.day, from: date) == day {
            return calendar.dateInterval(of: .day, for: date).map(DateOperand.day)
        }
        return nil
    }

    /// `1 September`, or `1 September 2027` when the day sits in a
    /// different year from `now`. Localised to the app's language.
    static func dayLabel(_ day: DateInterval, now: Date, calendar: Calendar) -> String {
        let start = day.start
        let style: Date.FormatStyle =
            calendar.component(.year, from: start) == calendar.component(.year, from: now)
                ? .dateTime.day().month(.wide)
                : .dateTime.day().month(.wide).year()
        return start.formatted(style.locale(L10n.locale))
    }

    /// The `after:`/`before:`/`on:` arm of `apply`. Negation flips the
    /// bound - `-after:D` is `before:D` - and `-on:D` excludes the day.
    private mutating func applyDate(
        _ key: ClipOperatorKey,
        value: String,
        negated: Bool,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard let operand = Self.dateOperand(value, now: now, calendar: calendar) else { return false }
        let wantsLower = (key == .after) != negated
        let wantsUpper = (key == .before) != negated
        switch operand {
        case .day(let day):
            if key == .on {
                let label = Self.dayLabel(day, now: now, calendar: calendar)
                if negated {
                    guard !excludedDays.contains(day) else { return true }
                    excludedDays.append(day)
                    phrases.append(loc("not on %@", label))
                } else {
                    after = max(after ?? .distantPast, day.start)
                    before = min(before ?? .distantFuture, day.end)
                    phrases.append(loc("on %@", label))
                }
            } else if wantsLower {
                after = max(after ?? .distantPast, operand.lowerBound)
                phrases.append(loc("since %@", Self.dayLabel(day, now: now, calendar: calendar)))
            } else {
                before = min(before ?? .distantFuture, operand.upperBound)
                phrases.append(loc("before %@", Self.dayLabel(day, now: now, calendar: calendar)))
            }
        case .ago(_, let count, let unit):
            if key == .on {
                let day = operand.dayInterval(in: calendar)
                let label = Self.dayLabel(day, now: now, calendar: calendar)
                if negated {
                    guard !excludedDays.contains(day) else { return true }
                    excludedDays.append(day)
                    phrases.append(loc("not on %@", label))
                } else {
                    after = max(after ?? .distantPast, day.start)
                    before = min(before ?? .distantFuture, day.end)
                    phrases.append(loc("on %@", label))
                }
            } else if wantsLower {
                after = max(after ?? .distantPast, operand.lowerBound)
                phrases.append(unit.lastPhrase(count))
            } else {
                before = min(before ?? .distantFuture, operand.upperBound)
                phrases.append(unit.agoPhrase(count))
            }
        }
        // `wantsUpper` computed for completeness; `.on` handles its own arm.
        _ = wantsUpper
        return true
    }
}

/// One row of the list that drops under the search field while an operator
/// is being completed.
struct SearchSuggestion: Equatable, Identifiable {
    /// The completed token text (`app:"Safari"`), minus its trailing space.
    var token: String
    /// The value it completes to, unquoted.
    var value: String
    /// The quiet trailing label - a clip count for `app:`, the day a date
    /// value resolves to, what an `is:`/`type:` value filters for.
    var detail: String
    var id: String { token }
}

extension ClipQuery {
    /// The grammar's `key:value` scan, quote-aware.
    ///
    /// One pass, left to right: each whitespace-run is either an operator
    /// (`[-]key:value` or `[-]key:"quoted value"`, key case-insensitive) or
    /// a word. Whatever does not fit stays a word - `https://x.y`, `14:30`,
    /// `re:` and `app:` with no value all search as literal text.
    static func scan(_ text: String) -> [QueryToken] {
        var tokens: [QueryToken] = []
        var i = text.startIndex
        while i < text.endIndex {
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            guard i < text.endIndex else { break }
            let tokenStart = i
            var negated = false
            if text[i] == "-" {
                negated = true
                i = text.index(after: i)
            }
            let headStart = i
            while i < text.endIndex, text[i].isLetter { i = text.index(after: i) }
            if i > headStart, i < text.endIndex, text[i] == ":",
               let key = ClipOperatorKey(rawValue: text[headStart..<i].lowercased()) {
                let headEnd = text.index(after: i)
                i = headEnd
                let value: String
                if i < text.endIndex, text[i] == "\"" {
                    // Quoted: to the close quote, or to the end of the text
                    // while it is still open.
                    i = text.index(after: i)
                    let valueStart = i
                    while i < text.endIndex, text[i] != "\"" { i = text.index(after: i) }
                    value = String(text[valueStart..<i])
                    if i < text.endIndex { i = text.index(after: i) }
                } else {
                    let valueStart = i
                    while i < text.endIndex, !text[i].isWhitespace { i = text.index(after: i) }
                    value = String(text[valueStart..<i])
                }
                if value.isEmpty {
                    // `key:` alone is a word - the suggestion list, not the
                    // grammar, is what answers a half-typed operator.
                    tokens.append(QueryToken(
                        range: tokenStart..<i, head: nil, key: nil, value: nil,
                        negated: negated
                    ))
                } else {
                    tokens.append(QueryToken(
                        range: tokenStart..<i, head: tokenStart..<headEnd,
                        key: key, value: value, negated: negated
                    ))
                }
            } else {
                while i < text.endIndex, !text[i].isWhitespace { i = text.index(after: i) }
                tokens.append(QueryToken(
                    range: tokenStart..<i, head: nil, key: nil, value: nil,
                    negated: negated
                ))
            }
        }
        return tokens
    }

    /// The operator-shaped spans of `text`, validity resolved - what the
    /// search field paints. Re-derived rather than stored: the field editor
    /// works on its own string, and `ClipQuery` keeps its own copy for the
    /// filter path.
    static func operatorTokens(
        in text: String,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [SearchOperatorToken] {
        scan(text).compactMap { token in
            guard let key = token.key, let value = token.value, let head = token.head else { return nil }
            var scratch = ClipConstraints()
            let known = scratch.apply(key, value: value, negated: token.negated, now: now, calendar: calendar)
            return SearchOperatorToken(
                range: token.range, head: head, key: key, value: value,
                negated: token.negated, valueIsKnown: known
            )
        }
    }

    /// `key:` token text for a value - quoted when it holds whitespace or a
    /// quote, the only shapes that would not survive the scan. Inner quotes
    /// cannot be represented, so they are dropped.
    static func quoted(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace || $0 == "\"" }) else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: ""))\""
    }

    // MARK: Suggestions

    /// The trailing operator token of a query, when it is still being
    /// completed: `is:` just typed, `app:saf` half-finished. The caret is
    /// assumed to sit at the end of the field - a `key:` typed in the
    /// middle is not rewritten.
    struct SuggestionContext: Equatable {
        var key: ClipOperatorKey
        /// The value typed so far - "" right after the colon.
        var prefix: String
        /// Whether the token was `-`-negated; accepting keeps the sign.
        var negated: Bool
        /// The token's extent - what accepting a suggestion rewrites.
        var range: Range<String.Index>
    }

    /// The context `suggestions(for:)` consumes, or nil when the tail of
    /// `text` is a word (or `key:` with a closing space).
    static func suggestionContext(in text: String) -> SuggestionContext? {
        guard let last = text.last, !last.isWhitespace,
              let token = scan(text).last else { return nil }
        if let key = token.key, let value = token.value {
            return SuggestionContext(key: key, prefix: value, negated: token.negated, range: token.range)
        }
        // `key:` or `key:"` with nothing after it scans as a word; it is
        // the exact moment a suggestion should appear.
        var word = text[token.range]
        if word.first == "-" { word = word.dropFirst() }
        let head = word.prefix(while: \.isLetter)
        guard let key = ClipOperatorKey(rawValue: head.lowercased()) else { return nil }
        let rest = word.dropFirst(head.count)
        guard rest == ":" || rest == ":\"" else { return nil }
        return SuggestionContext(key: key, prefix: "", negated: token.negated, range: token.range)
    }

    /// The rows to show for a `context`: `app:` from the store's names
    /// ordered most-used first (the caller passes them pre-sorted), `in:`
    /// from the store's board names (the Pinned pseudo-board first, since
    /// `in:pinned` answers it), `is:`/`type:`/dates from the fixed
    /// vocabularies, each filtered by the typed prefix. Capped at eight,
    /// as the PRD asks.
    static func suggestions(
        for context: SuggestionContext,
        apps: [(name: String, count: Int)],
        boards: [String] = [],
        now: Date,
        calendar: Calendar
    ) -> [SearchSuggestion] {
        let prefix = context.prefix.lowercased()
        func matches(_ candidate: String) -> Bool {
            prefix.isEmpty || candidate.lowercased().hasPrefix(prefix)
        }
        switch context.key {
        case .app:
            return Array(apps
                .filter { prefix.isEmpty || ClipConstraints.hasAppPrefix($0.name, context.prefix) }
                .prefix(8)
                .map {
                    SearchSuggestion(
                        token: "app:" + quoted($0.name),
                        value: $0.name,
                        detail: loc("%d clips", $0.count)
                    )
                })
        case .in:
            return ([ClipStateValue.pinned.rawValue] + boards)
                .filter(matches)
                .prefix(8)
                .map {
                    SearchSuggestion(
                        token: "in:" + quoted($0), value: $0,
                        detail: $0 == ClipStateValue.pinned.rawValue ? loc("Pinned") : ""
                    )
                }
        case .is:
            return context.key.fixedValues.filter(matches).prefix(8).map { value in
                let state = ClipStateValue(rawValue: value)
                return SearchSuggestion(
                    token: "is:" + value, value: value, detail: state?.phrase ?? ""
                )
            }
        case .type:
            return context.key.fixedValues.filter(matches).prefix(8).map { value in
                let filter = TypeFilter(rawValue: value)
                return SearchSuggestion(
                    token: "type:" + value, value: value, detail: filter?.phrase ?? ""
                )
            }
        case .after, .before, .on:
            return context.key.fixedValues.filter(matches).prefix(8).map { value in
                SearchSuggestion(
                    token: "\(context.key.rawValue):" + value,
                    value: value,
                    detail: dateDetail(value, for: context.key, now: now, calendar: calendar)
                )
            }
        }
    }

    /// What a date suggestion resolves to - the day `on:today` names, "the
    /// last 7 days" for `after:7d`, "more than 7 days ago" for `before:7d`.
    private static func dateDetail(
        _ value: String,
        for key: ClipOperatorKey,
        now: Date,
        calendar: Calendar
    ) -> String {
        guard let operand = ClipConstraints.dateOperand(value, now: now, calendar: calendar)
        else { return "" }
        switch (operand, key) {
        case (.day(let day), _):
            return ClipConstraints.dayLabel(day, now: now, calendar: calendar)
        case (.ago, .on):
            return ClipConstraints.dayLabel(operand.dayInterval(in: calendar), now: now, calendar: calendar)
        case (.ago(_, let count, let unit), .after):
            return unit.lastPhrase(count)
        case (.ago(_, let count, let unit), .before):
            return unit.agoPhrase(count)
        case (_, .app), (_, .is), (_, .in), (_, .type):
            return ""
        }
    }

    /// `text` with `context`'s token replaced by the completed operator and
    /// a trailing space - the space ends the token so the list closes and
    /// the next keystroke starts fresh.
    static func accepting(_ context: SuggestionContext, _ value: String, in text: String) -> String {
        let token = (context.negated ? "-" : "")
            + context.key.rawValue + ":" + quoted(value) + " "
        return text.replacingCharacters(in: context.range, with: token)
    }

    /// `search` with every `app:` token - either sign - replaced by one for
    /// `name`, or with them dropped when `name` is nil. The footer menu and
    /// the preview's app name both come through here: the picker's "Safari"
    /// and a typed `app:saf` are one code path.
    static func settingApp(_ name: String?, in search: String) -> String {
        var kept: [String] = []
        for token in scan(search) {
            if token.key == .app { continue }
            kept.append(String(search[token.range]))
        }
        if let name {
            kept.append("app:" + quoted(name))
        }
        return kept.joined(separator: " ")
    }

    /// `search` with every operator token - known value or not - removed.
    /// The words stay: that is what the empty state's "Clear filters"
    /// button keeps.
    static func clearingOperators(from search: String) -> String {
        scan(search)
            .filter { $0.key == nil }
            .map { String(search[$0.range]) }
            .joined(separator: " ")
    }
}

/// The cheat-sheet content a lone `?` in the search field shows: each
/// operator with one example, then the two syntax notes.
enum SearchCheatSheet {
    /// `(token example, what it matches)` pairs, in display order.
    static var rows: [(token: String, detail: String)] {
        let states = ClipStateValue.allCases.map(\.rawValue).joined(separator: ", ")
        let kinds = TypeFilter.typeableValues.map(\.rawValue).joined(separator: ", ")
        let times = "today, yesterday, 7d, 2w, 3m, 2026-09-01"
        return [
            ("app:Safari", loc("clips from an app")),
            ("is:pinned", loc("a state: %@", states)),
            ("type:link", loc("a kind: %@", kinds)),
            ("in:work", loc("a pinboard")),
            ("after:7d", loc("copied after a time: %@", times)),
            ("before:2026-09-01", loc("copied before a time")),
            ("on:yesterday", loc("copied on one day")),
            ("-app:Slack", loc("a leading - negates")),
            ("app:\"Google Chrome\"", loc("quotes keep a value with spaces together")),
        ]
    }
}
