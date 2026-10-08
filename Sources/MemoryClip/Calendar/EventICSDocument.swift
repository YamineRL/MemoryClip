import Foundation

/// A `DetectedEvent` rendered as an iCalendar (.ics) document.
///
/// The "Edit…" half of the calendar offer: instead of writing the event
/// straight into the user's calendar, MemoryClip hands the appointment to
/// the default calendar handler — Calendar.app, or whatever owns .ics — as
/// a document to open. That app shows its own "add this event" inspector,
/// with every field editable before anything is committed, and discarding
/// it leaves nothing behind. Write-only EventKit access could never offer
/// either of those: its events are committed on `save` and cannot be
/// re-shown for editing.
///
/// Pure string building, no EventKit, so the exact bytes are testable.
enum EventICSDocument {
    /// The whole document for one detected event.
    ///
    /// `uid` identifies the VEVENT — iCalendar demands one and the caller
    /// supplies it so a test can pin it; a uuid string is the right value.
    static func document(for event: DetectedEvent, uid: String) -> String {
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//MemoryClip//MemoryClip//EN",
            "BEGIN:VEVENT",
            "UID:\(escape(uid))",
            "DTSTAMP:\(utc(Date()))",
            "SUMMARY:\(escape(event.title))",
        ]
        lines += dateLines(for: event)
        if let location = event.location, !location.isEmpty {
            lines.append("LOCATION:\(escape(location))")
        }
        if let url = event.meetingURL {
            lines.append("URL:\(url.absoluteString)")
        }
        lines += [
            "END:VEVENT",
            "END:VCALENDAR",
        ]
        // The spec's line ending is CRLF; every calendar client reads LF
        // anyway, but there is no reason to deviate on a file we control.
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Write the document for `event` into the temporary directory and
    /// return its URL. The file is cleaned up by the system like everything
    /// else there; the name is stable per uid so a second look at the same
    /// offer replaces rather than stacks.
    static func writeTemporarily(for event: DetectedEvent, uid: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryClip-Event-\(uid).ics")
        try document(for: event, uid: uid).write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        return url
    }

    // MARK: - Dates

    /// The DTSTART/DTEND pair, in the shape the event's kind needs.
    ///
    /// All-day events carry `VALUE=DATE` — a plain day, no clock — because
    /// that is what Calendar shows as an all-day row rather than a midnight
    /// appointment. iCalendar's `DTEND` is exclusive, which is already
    /// `DetectedEvent.end`'s convention: the start of the following day
    /// (see `EventKitSink.inclusiveAllDayEnd` for the convention EventKit
    /// needs instead). No arithmetic, just the day that instant lands on.
    /// Timed events name their zone when the text named one (`TZID`), else
    /// float to UTC.
    private static func dateLines(for event: DetectedEvent) -> [String] {
        if event.isAllDay {
            let zone = event.timeZone ?? .current
            return [
                "DTSTART;VALUE=DATE:\(day(event.start, in: zone))",
                "DTEND;VALUE=DATE:\(day(event.end, in: zone))",
            ]
        }
        guard let zone = event.timeZone else {
            return [
                "DTSTART:\(utc(event.start))",
                "DTEND:\(utc(event.end))",
            ]
        }
        return [
            "DTSTART;TZID=\(zone.identifier):\(local(event.start, in: zone))",
            "DTEND;TZID=\(zone.identifier):\(local(event.end, in: zone))",
        ]
    }

    /// `20260820` — the DATE form for all-day lines. Formatted in the event's
    /// own zone: an all-day start is already the beginning of that day there,
    /// and rendering it in another zone could shift it one day backwards.
    private static func day(_ date: Date, in zone: TimeZone) -> String {
        let formatter = dayFormatter
        formatter.timeZone = zone
        return formatter.string(from: date)
    }

    /// `20260820T150000Z` — the UTC DATE-TIME form.
    private static func utc(_ date: Date) -> String {
        utcFormatter.string(from: date)
    }

    /// `20260820T150000` — the floating DATE-TIME form a `TZID` parameter
    /// gives meaning to.
    private static func local(_ date: Date, in zone: TimeZone) -> String {
        let formatter = localFormatter
        formatter.timeZone = zone
        return formatter.string(from: date)
    }

    /// Formatters are lazily shared: building one per property costs far
    /// more than the strings they produce.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    private static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let localFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter
    }()

    // MARK: - Text escaping

    /// RFC 5545 text escaping: backslash first (or the rest double-escapes),
    /// then semicolons and commas which delimit property values, then
    /// newlines which would otherwise split the line.
    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }
}
