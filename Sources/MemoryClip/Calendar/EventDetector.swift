import Foundation

/// Reads an appointment out of a clip's text: a date, and whatever corroborates
/// it — a clock time, a video-call link, a postal address, a title.
///
/// Foundation-only, no state, nonisolated — safe to call from any concurrency
/// context, and callable from a test without a calendar, a store or a
/// permission grant.
///
/// The date and address work is `NSDataDetector`'s, not ours. It is the same
/// engine that underlines dates in Mail, it is written in C, it is localized
/// for every language the OS ships, and it already understands the forms that
/// matter here — "Thursday, August 20 at 3:00 PM – 4:00 PM", "Mon 24 Aug 2026,
/// 10:00–11:30 (CEST)", "next Tuesday". Re-deriving any of that from regular
/// expressions would be worse in every language including English, and this
/// file's own history explains why the rest of the app avoids regexes on hot
/// paths (see `TextDetector`).
///
/// What is ours is the judgement layer on top: `NSDataDetector` will happily
/// call "Q3 ends September 30" a date, so the detector has to decide which of
/// its matches is an *appointment*. That is what `isStrongSignal` is for.
enum EventDetector {
    /// Upper bound, in UTF-8 bytes, on the text we scan.
    ///
    /// Four times `TextDetector`'s cap, because this runs on demand rather
    /// than per visible row, and because its input is often a screenshot's
    /// OCR text — a whole invitation e-mail rather than a single field. Past
    /// the cap we scan the prefix instead of giving up: an appointment that
    /// appears 16 KB into a clip is not the reason someone pressed the button,
    /// and a bounded scan is what keeps a 2 MB paste from stalling.
    static let maxScannedUTF8Bytes = 16_384

    /// How long an event lasts when the text names a start but no end.
    static let defaultDuration: TimeInterval = 3600

    /// The longest run the text is allowed to talk us into.
    ///
    /// `NSDataDetector` reports a `duration` for anything it reads as a range,
    /// and it reads far too much as one: "Q3 ends September 30" comes back as
    /// a forty-four-day duration measured from today. Anything longer than a
    /// day is therefore treated as no duration at all rather than as a
    /// multi-day event — the failure it prevents (a month-long block dropped
    /// across your calendar) is much worse than the one it causes (a genuine
    /// three-day offsite booked as one hour, which you can drag).
    static let maxTextDuration: TimeInterval = 24 * 3600

    /// Hosts whose links are video calls rather than ordinary web pages.
    /// Matched as suffixes, so `us02web.zoom.us` and `acme.webex.com` count.
    static let meetingHosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "meet.jit.si", "chime.aws",
        "gotomeeting.com", "bluejeans.com", "around.co", "riverside.fm",
        "meet.proton.me", "facetime.apple.com", "skype.com", "8x8.vc"
    ]

    /// First DNS labels that announce a call whoever is hosting it —
    /// `meet.proton.me`, `call.example.org`, a self-hosted `video.acme.co`.
    ///
    /// The named list above cannot keep up: every month there is another
    /// service, and a list that has fallen behind fails *silently* — the
    /// automatic setting simply does nothing, which reads as the feature
    /// being broken rather than as a host it has not heard of. This is the
    /// rule that generalises, and it is safe to be generous with because a
    /// link alone never creates anything: `isStrongSignal` also demands a
    /// clock time, so the worst a wrong guess here does is let a timed line
    /// that already looked like an appointment become one.
    static let meetingHostPrefixes: Set<String> = [
        "meet", "call", "video", "conf", "conference", "join", "vc", "room", "live"
    ]

    /// How far a corroborating detail may sit from the date it belongs to,
    /// in UTF-16 units between the closest edges of the two matches.
    ///
    /// A real invitation writes its details as a block — subject, when,
    /// where, link, a handful of lines. A long email thread can carry a
    /// date in one section, an address in a signature four paragraphs down
    /// and a Zoom link in an unrelated earlier message, and combining them
    /// fabricates an appointment that exists nowhere. So a link or address
    /// only counts when it lives NEXT to the date: the window is wide
    /// enough for a label-and-value pair or a wrapped line, far too narrow
    /// to reach across a thread.
    static let detailProximity = 320

    /// The appointment in `text`, or nil when it names no date at all.
    ///
    /// - Parameters:
    ///   - fallbackTitle: used when no line survives as a title. The caller
    ///     supplies it so this stays a pure function of its input — the
    ///     coordinator passes the clip's model-written title when it has one.
    ///   - defaultDuration: how long an event with no stated end should run.
    ///   - calendar: injected so the all-day arithmetic is testable in a
    ///     fixed zone rather than in whatever zone the test machine is in.
    static func detect(
        _ text: String,
        fallbackTitle: String,
        defaultDuration: TimeInterval = defaultDuration,
        calendar: Calendar = .current
    ) -> DetectedEvent? {
        let scanned = boundedPrefix(of: text)
        guard !scanned.isEmpty else { return nil }

        let types: NSTextCheckingResult.CheckingType = [.date, .address, .link]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return nil }

        let subject = scanned as NSString
        let whole = NSRange(location: 0, length: subject.length)
        let matches = detector.matches(in: scanned, range: whole)

        guard let dateMatch = matches.first(where: { $0.resultType == .date }),
              let detectedStart = dateMatch.date
        else { return nil }

        // Whether a clock time was actually written down, as opposed to
        // supplied by the detector. A date with no time comes back at noon,
        // so the resolved `Date` cannot answer this — only the text can.
        let named = subject.substring(with: dateMatch.range)
        var hasClockTime = namesAClockTime(named)
        var start = detectedStart
        var duration = dateMatch.duration

        // Left nil unless the text named a zone: `timeZone` means "the text
        // said so", which is what the sink needs in order to decide whether
        // to override the calendar's own zone.
        let zone = dateMatch.timeZone

        // A labelled invitation writes the clock time on its own row —
        // "TIME   Doors open : 6:00 p.m." — which the detector reports as a
        // SECOND date match, not part of the first. When the primary match
        // names only a day, adopt the nearest timed match's clock, under
        // the same proximity window every other corroborating detail must
        // live in: a time too far away to belong to the date stays out.
        if !hasClockTime,
           let timed = matches.first(where: {
               $0.resultType == .date
                   && $0.range.location != dateMatch.range.location
                   && $0.range.isNear(dateMatch.range, within: detailProximity)
                   && namesAClockTime(subject.substring(with: $0.range))
           }),
           let clock = timed.date {
            let zoned = resolvedCalendar(in: zone, base: calendar)
            let clockParts = zoned.dateComponents([.hour, .minute, .second], from: clock)
            if let combined = zoned.date(
                bySettingHour: clockParts.hour ?? 0,
                minute: clockParts.minute ?? 0,
                second: 0,
                of: start
            ) {
                start = combined
                duration = timed.duration
                hasClockTime = true
            }
        }

        // Corroboration counts only when it lives next to the date —
        // `detailProximity` above has the reasoning. A detail that belongs
        // to some other part of the text is not this appointment's.
        let location = matches
            .first { $0.resultType == .address && $0.range.isNear(dateMatch.range, within: detailProximity) }
            .flatMap { addressLine(from: $0.addressComponents) }

        let meetingURL = matches
            .compactMap { $0.resultType == .link ? (url: $0.url, range: $0.range) : nil }
            .first { $0.url.map(isMeetingURL) == true && $0.range.isNear(dateMatch.range, within: detailProximity) }
            .flatMap(\.url)

        // Left nil unless the text named a zone: `timeZone` means "the text
        // said so", which is what the sink needs in order to decide whether to
        // override the calendar's own zone.
        let title = titleLine(in: subject, avoiding: matches) ?? fallbackTitle
        let span = span(
            from: start,
            duration: duration,
            hasClockTime: hasClockTime,
            defaultDuration: defaultDuration,
            calendar: resolvedCalendar(in: zone, base: calendar)
        )

        return DetectedEvent(
            title: title,
            start: span.start,
            end: span.end,
            isAllDay: !hasClockTime,
            location: location,
            meetingURL: meetingURL,
            timeZone: zone,
            isStrongSignal: hasClockTime && (meetingURL != nil || location != nil)
        )
    }

    /// Whether `text` holds an appointment worth offering a button for.
    /// Cheaper to read at a call site than `detect(...) != nil`.
    static func hasEvent(_ text: String) -> Bool {
        detect(text, fallbackTitle: "-") != nil
    }

    // MARK: - Span

    /// Start and end, after the duration has been sanity-checked and an
    /// untimed date has been widened to the whole day.
    private static func span(
        from start: Date,
        duration: TimeInterval,
        hasClockTime: Bool,
        defaultDuration: TimeInterval,
        calendar: Calendar
    ) -> (start: Date, end: Date) {
        guard hasClockTime else {
            // All day. `end` is the start of the *following* day — a
            // half-open interval, so `duration` is a day rather than zero and
            // the two fields never compare equal. `EventKitSink` converts to
            // EventKit's inclusive last-day convention.
            let day = calendar.startOfDay(for: start)
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            return (day, next)
        }
        let stated = (duration > 0 && duration <= maxTextDuration) ? duration : defaultDuration
        return (start, start.addingTimeInterval(stated))
    }

    /// `base` re-pointed at `zone`, so an event written in another zone is
    /// widened to *its* day rather than to the local one.
    private static func resolvedCalendar(in zone: TimeZone?, base: Calendar) -> Calendar {
        guard let zone else { return base }
        var moved = base
        moved.timeZone = zone
        return moved
    }

    // MARK: - Title

    /// The first line that still says something once the date, address and
    /// links are struck out of it.
    ///
    /// Invitations put the subject on its own line above the details, so the
    /// first surviving line is nearly always the right answer — and when the
    /// date shares that line ("Design review Thu 20 Aug, 3pm") striking the
    /// match out leaves exactly the subject behind.
    private static func titleLine(in subject: NSString, avoiding matches: [NSTextCheckingResult]) -> String? {
        var result: String?
        subject.enumerateSubstrings(
            in: NSRange(location: 0, length: subject.length),
            options: [.byLines, .substringNotRequired]
        ) { _, range, _, stop in
            let residue = strike(matches, from: range, in: subject)
            if let candidate = titleCandidate(residue) {
                result = candidate
                stop.pointee = true
            }
        }
        return result
    }

    /// `range`'s text with every overlapping match removed.
    private static func strike(
        _ matches: [NSTextCheckingResult],
        from range: NSRange,
        in subject: NSString
    ) -> String {
        var pieces: [String] = []
        var cursor = range.location
        let end = range.location + range.length
        for match in matches.sorted(by: { $0.range.location < $1.range.location }) {
            let overlap = NSIntersectionRange(match.range, range)
            guard overlap.length > 0 else { continue }
            if overlap.location > cursor {
                pieces.append(subject.substring(with: NSRange(
                    location: cursor,
                    length: overlap.location - cursor
                )))
            }
            cursor = max(cursor, overlap.location + overlap.length)
        }
        if cursor < end {
            pieces.append(subject.substring(with: NSRange(location: cursor, length: end - cursor)))
        }
        return pieces.joined(separator: " ")
    }

    /// A struck-out line reduced to a title, or nil when nothing usable is
    /// left. Leading labels ("Subject:", "When –") and the punctuation the
    /// struck-out match left behind are trimmed off both ends.
    private static func titleCandidate(_ line: String) -> String? {
        let furniture = CharacterSet(charactersIn: "-–—:,;·|@()[]{}<>\"'")
            .union(.whitespacesAndNewlines)
        let trimmed = stripLeadingLabel(line).trimmingCharacters(in: furniture)
        let unlabelled = stripLeadingShoutedLabel(trimmed).trimmingCharacters(in: furniture)
        let tidied = stripTrailingConnectors(unlabelled)
        guard tidied.count >= 3, tidied.contains(where: \.isLetter) else { return nil }
        // A line that survives only as a label — "DATE" beside the struck-
        // out date, "EVENT DETAILS" heading the block — named the field,
        // not the event, and yields to the caller's fallback.
        guard !fieldLabels.contains(tidied.lowercased()),
              !sectionHeaders.contains(tidied.lowercased()) else { return nil }
        return String(tidied.prefix(maxTitleCharacters))
    }

    /// Words that introduce the date and are left stranded when it is struck
    /// out. "Call with mehdi the 18 of Aug" matches its date at "18", so the
    /// title would otherwise keep the article that was pointing at it.
    ///
    /// Only ever removed from the *end* — "Call with the design team" keeps
    /// its "the", because there the word is inside the phrase rather than
    /// dangling off it. Stripping runs to the last word rather than stopping
    /// one short: a line that is nothing but connectors ("the", "on the")
    /// said nothing about the event, and an empty result is what hands the
    /// job to the caller's fallback title.
    private static let trailingConnectors: Set<String> = [
        "the", "a", "an", "on", "at", "in", "of", "for", "from", "to", "by",
        "this", "that", "next", "starts", "starting", "is", "was", "be",
        "le", "la", "les", "un", "une", "du", "de", "des", "à", "au", "aux",
        "ce", "cet", "cette", "prochain", "prochaine", "est", "sera"
    ]

    private static func stripTrailingConnectors(_ title: String) -> String {
        var words = title.split(separator: " ", omittingEmptySubsequences: true)
        while let last = words.last, trailingConnectors.contains(last.lowercased()) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    /// Drops a field label — "Subject:", "When:", "Objet :" — from the front
    /// of a line, since a copied invitation leads with one and it is never
    /// what the event should be called.
    ///
    /// Matched against a fixed list rather than inferred from shape. Any
    /// "short word followed by a colon" rule also strips the first half of
    /// "Postmortem: the April outage", and a title losing its subject is a
    /// worse outcome than a label surviving: the list can only fail by doing
    /// nothing. It is not `loc`-ed — these are the words that appear in
    /// copied text, whatever language the interface is in, so both the
    /// English and the French forms are listed together.
    private static let fieldLabels: Set<String> = [
        "subject", "title", "event", "when", "where", "location", "time",
        "date", "meeting", "invitation", "invite", "re", "fwd",
        "objet", "titre", "quand", "où", "ou", "lieu", "heure", "réunion", "reunion"
    ]

    /// Whole-line section headers — the words a copied invitation uses to
    /// introduce its details block rather than to name the event. Matched
    /// against the full stripped line only, so "Event details for the Q3
    /// offsite" survives as a title while a bare "EVENT DETAILS" does not.
    private static let sectionHeaders: Set<String> = [
        "event details", "event information", "event info", "details",
        "schedule", "agenda", "programme", "program",
        "when & where", "when and where",
        "détails de l'événement", "détails de l'evenement", "détails",
        "informations", "infos pratiques", "quand et où"
    ]

    private static func stripLeadingLabel(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return line }
        let label = line[line.startIndex..<colon]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard fieldLabels.contains(label) else { return line }
        let rest = line[line.index(after: colon)...]
        return rest.contains(where: \.isLetter) ? String(rest) : line
    }

    /// A field label shouted in capitals rather than followed by a colon —
    /// "TIME   6:00 p.m." on a details card, where the label is layout
    /// furniture rather than part of the name. The all-caps requirement is
    /// what makes dropping it safe: "Date Night" keeps its first word
    /// because "Date" is not shouted.
    private static func stripLeadingShoutedLabel(_ line: String) -> String {
        let words = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard words.count == 2 else { return line }
        let first = String(words[0])
        let rest = String(words[1])
        let letters = first.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 2,
              first == first.uppercased(),
              fieldLabels.contains(first.lowercased()),
              rest.contains(where: \.isLetter) else { return line }
        return rest
    }

    /// Calendars show far less than this, and an EventKit title is free-form —
    /// the clamp is here so a wall of OCR text cannot become one.
    private static let maxTitleCharacters = 120

    // MARK: - Clock time

    /// Whether `text` writes a time of day, rather than only a date.
    ///
    /// Three forms, all of which have to survive the detector having already
    /// decided this substring is a date: `15:00` and `3:00 PM` (a colon
    /// between digits), `3 PM` and `9am` (a digit before a meridiem), and
    /// `14h30` (a digit either side of an `h`, the French clock). Written as a
    /// scalar walk rather than a `Regex` for the reason `TextDetector`
    /// records: `Regex` is not `Sendable`, so it cannot be hoisted out of the
    /// call and would be recompiled every time.
    static func namesAClockTime(_ text: String) -> Bool {
        let scalars = Array(text.lowercased().unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            let previous = index > 0 ? scalars[index - 1] : nil
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil

            // 15:00, 3:00 PM
            if scalar == ":", let previous, let next,
               isDigit(previous), isDigit(next) { return true }

            // 14h30 — but not "24 hours", which has no digit after the h.
            if scalar == "h", let previous, let next,
               isDigit(previous), isDigit(next) { return true }

            // 3 PM, 9am, 9 a.m.
            if isDigit(scalar), meridiemFollows(scalars, after: index) { return true }
        }
        return false
    }

    /// Whether "am"/"pm" (with or without dots) starts within the next two
    /// characters — allowing for the space in "3 PM" and nothing else.
    private static func meridiemFollows(_ scalars: [Unicode.Scalar], after index: Int) -> Bool {
        var cursor = index + 1
        if cursor < scalars.count, scalars[cursor] == " " { cursor += 1 }
        guard cursor + 1 < scalars.count else { return false }
        let first = scalars[cursor]
        guard first == "a" || first == "p" else { return false }
        var second = cursor + 1
        if scalars[second] == ".", second + 1 < scalars.count { second += 1 }
        return scalars[second] == "m"
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    // MARK: - Address and links

    /// The address components joined into the single line EventKit wants.
    /// Ordered rather than dictionary-ordered, so the same address always
    /// renders the same way.
    static func addressLine(from components: [NSTextCheckingKey: String]?) -> String? {
        guard let components else { return nil }
        let ordered: [NSTextCheckingKey] = [.name, .street, .city, .state, .zip, .country]
        let parts = ordered.compactMap { components[$0] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ")
    }

    /// Whether `url` is a video call rather than a web page.
    ///
    /// Either a known host, or one whose first label says so — see
    /// `meetingHostPrefixes`. The prefix rule needs at least three labels so
    /// that a bare `meet.com` style domain does not qualify on its own.
    static func isMeetingURL(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        if meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        let labels = host.split(separator: ".")
        guard labels.count >= 3, let first = labels.first else { return false }
        return meetingHostPrefixes.contains(String(first))
    }

    // MARK: - Input

    /// `text` truncated to `maxScannedUTF8Bytes`, cut on a character boundary.
    private static func boundedPrefix(of text: String) -> String {
        guard text.utf8.count > maxScannedUTF8Bytes else { return text }
        let bytes = text.utf8.prefix(maxScannedUTF8Bytes)
        return String(decoding: bytes, as: UTF8.self)
    }
}

private extension NSRange {
    /// Whether two matches sit within `distance` UTF-16 units of each other,
    /// measuring between their closest edges (0 when they overlap or touch).
    func isNear(_ other: NSRange, within distance: Int) -> Bool {
        let gap: Int
        if location + length <= other.location {
            gap = other.location - (location + length)
        } else if other.location + other.length <= location {
            gap = location - (other.location + other.length)
        } else {
            gap = 0
        }
        return gap <= distance
    }
}
