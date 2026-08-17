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
        "gotomeeting.com", "bluejeans.com", "around.co", "riverside.fm"
    ]

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
              let start = dateMatch.date
        else { return nil }

        // Whether a clock time was actually written down, as opposed to
        // supplied by the detector. A date with no time comes back at noon,
        // so the resolved `Date` cannot answer this — only the text can.
        let named = subject.substring(with: dateMatch.range)
        let hasClockTime = namesAClockTime(named)

        let location = matches
            .first { $0.resultType == .address }
            .flatMap { addressLine(from: $0.addressComponents) }

        let meetingURL = matches
            .compactMap { $0.resultType == .link ? $0.url : nil }
            .first(where: isMeetingURL)

        // Left nil unless the text named a zone: `timeZone` means "the text
        // said so", which is what the sink needs in order to decide whether to
        // override the calendar's own zone.
        let zone = dateMatch.timeZone

        let title = titleLine(in: subject, avoiding: matches) ?? fallbackTitle
        let span = span(
            from: start,
            duration: dateMatch.duration,
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
        guard trimmed.count >= 3, trimmed.contains(where: \.isLetter) else { return nil }
        return String(trimmed.prefix(maxTitleCharacters))
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

    private static func stripLeadingLabel(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return line }
        let label = line[line.startIndex..<colon]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard fieldLabels.contains(label) else { return line }
        let rest = line[line.index(after: colon)...]
        return rest.contains(where: \.isLetter) ? String(rest) : line
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
    static func isMeetingURL(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: - Input

    /// `text` truncated to `maxScannedUTF8Bytes`, cut on a character boundary.
    private static func boundedPrefix(of text: String) -> String {
        guard text.utf8.count > maxScannedUTF8Bytes else { return text }
        let bytes = text.utf8.prefix(maxScannedUTF8Bytes)
        return String(decoding: bytes, as: UTF8.self)
    }
}
