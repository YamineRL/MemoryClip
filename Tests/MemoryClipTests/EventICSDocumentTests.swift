import Foundation
import XCTest

@testable import MemoryClip

/// The .ics bytes the offer's Edit button hands to a calendar app. Wrong
/// escaping or a wrong date shape here is an event the user edits, saves —
/// and gets back wrong, so every line is pinned, not spot-checked.
final class EventICSDocumentTests: XCTestCase {
    /// A fixed instant: 2026-08-20 15:00 in Europe/Paris (13:00 UTC).
    private let start = Date(timeIntervalSince1970: 1_787_230_800)
    /// +1h.
    private let end = Date(timeIntervalSince1970: 1_787_234_400)

    private let paris = TimeZone(identifier: "Europe/Paris")!

    private func timedEvent(
        title: String = "Design review",
        zone: TimeZone? = nil
    ) -> DetectedEvent {
        DetectedEvent(
            title: title,
            start: start,
            end: end,
            isAllDay: false,
            location: nil,
            meetingURL: nil,
            timeZone: zone,
            isStrongSignal: true
        )
    }

    func testDocumentSkeleton() {
        let ics = EventICSDocument.document(for: timedEvent(), uid: "fixed-uid")

        XCTAssertTrue(ics.hasPrefix("BEGIN:VCALENDAR\r\nVERSION:2.0"))
        XCTAssertTrue(ics.hasSuffix("END:VCALENDAR\r\n"))
        XCTAssertTrue(ics.contains("UID:fixed-uid"))
        XCTAssertTrue(ics.contains("BEGIN:VEVENT"))
        XCTAssertTrue(ics.contains("END:VEVENT"))
        XCTAssertTrue(ics.contains("SUMMARY:Design review"))
    }

    func testTimedEventWithoutZoneUsesUTC() {
        let ics = EventICSDocument.document(for: timedEvent(), uid: "x")

        XCTAssertTrue(ics.contains("DTSTART:20260820T130000Z"))
        XCTAssertTrue(ics.contains("DTEND:20260820T140000Z"))
    }

    func testTimedEventWithZoneCarriesTZID() {
        let ics = EventICSDocument.document(for: timedEvent(zone: paris), uid: "x")

        XCTAssertTrue(ics.contains("DTSTART;TZID=Europe/Paris:20260820T150000"))
        XCTAssertTrue(ics.contains("DTEND;TZID=Europe/Paris:20260820T160000"))
    }

    func testAllDayEventUsesDateFormAndExclusiveEnd() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let dayStart = calendar.startOfDay(for: start)
        var event = timedEvent()
        event.isAllDay = true
        event.start = dayStart
        event.end = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        let ics = EventICSDocument.document(for: event, uid: "x")
        let dayString = { (date: Date) in
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyyMMdd"
            return formatter.string(from: date)
        }

        XCTAssertTrue(ics.contains("DTSTART;VALUE=DATE:\(dayString(event.start))"))
        // DetectedEvent.end is already the exclusive end — the start of the
        // following day — so DTEND names that day and nothing is shifted.
        XCTAssertTrue(ics.contains("DTEND;VALUE=DATE:\(dayString(event.end))"))
        XCTAssertFalse(ics.contains("T000000"), "an all-day event carries no clock time")
    }

    func testEscapesTextValues() {
        var event = timedEvent(title: "Review, Q3; bring the \"deck\"\nRoom 4")
        event.location = "1, Rue de la Paix; Paris"

        let ics = EventICSDocument.document(for: event, uid: "x")

        XCTAssertTrue(ics.contains("SUMMARY:Review\\, Q3\\; bring the \"deck\"\\nRoom 4"))
        XCTAssertTrue(ics.contains("LOCATION:1\\, Rue de la Paix\\; Paris"))
        XCTAssertFalse(ics.contains("Room 4\n"), "a raw newline would split the line")
    }

    func testBackslashEscapesBeforeEverythingElse() {
        var event = timedEvent(title: "C:\\path, dir")
        event.location = nil

        let ics = EventICSDocument.document(for: event, uid: "x")

        XCTAssertTrue(ics.contains("SUMMARY:C:\\\\path\\, dir"))
    }

    func testMeetingURLAndLocationAreCarried() {
        var event = timedEvent()
        event.meetingURL = URL(string: "https://us02web.zoom.us/j/89123456789")
        event.location = "10 Downing Street"

        let ics = EventICSDocument.document(for: event, uid: "x")

        XCTAssertTrue(ics.contains("URL:https://us02web.zoom.us/j/89123456789"))
        XCTAssertTrue(ics.contains("LOCATION:10 Downing Street"))
    }

    func testWriteTemporarilyProducesAReadableFile() throws {
        let url = try EventICSDocument.writeTemporarily(for: timedEvent(), uid: "write-test")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.pathExtension, "ics")
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("BEGIN:VEVENT"))
        XCTAssertTrue(contents.contains("UID:write-test"))
    }
}
