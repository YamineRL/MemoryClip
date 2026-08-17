import XCTest

@testable import MemoryClip

/// Every fixture names an absolute date. `NSDataDetector` resolves "tomorrow"
/// and "Friday" against the wall clock, so a relative fixture would pass or
/// fail depending on the day the suite runs.
final class EventDetectorTests: XCTestCase {
    /// A fixed zone, so the all-day arithmetic does not depend on where the
    /// machine running the tests happens to be.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .gmt
        return calendar
    }()

    private func detect(_ text: String, fallback: String = "Untitled") -> DetectedEvent? {
        EventDetector.detect(text, fallbackTitle: fallback, calendar: calendar)
    }

    // MARK: - Nothing to find

    func testTextWithNoDateIsNotAnEvent() {
        XCTAssertNil(detect("Just some text with no date, https://example.com"))
        XCTAssertNil(detect(""))
        XCTAssertNil(detect("   \n  "))
    }

    func testHasEventMatchesDetect() {
        XCTAssertFalse(EventDetector.hasEvent("no date here"))
        XCTAssertTrue(EventDetector.hasEvent("Standup on August 20, 2026 at 9:30am"))
    }

    // MARK: - The strong signal

    func testDateTimeAndMeetingLinkIsStrong() {
        let event = detect("""
        Design review
        August 20, 2026 at 3:00 PM – 4:00 PM
        Zoom: https://us02web.zoom.us/j/89123456789?pwd=abc
        """)
        XCTAssertEqual(event?.title, "Design review")
        XCTAssertEqual(event?.isStrongSignal, true)
        XCTAssertEqual(event?.isAllDay, false)
        XCTAssertEqual(event?.meetingURL?.host(), "us02web.zoom.us")
        XCTAssertEqual(event?.duration, 3600)
    }

    func testDateTimeAndAddressIsStrong() {
        let event = detect("Lunch with Sam on August 20, 2026 at 12:30 at 1 Infinite Loop, Cupertino, CA 95014")
        XCTAssertEqual(event?.isStrongSignal, true)
        XCTAssertEqual(event?.location, "1 Infinite Loop, Cupertino, CA, 95014")
    }

    func testDateTimeAloneIsNotStrong() {
        let event = detect("Standup on August 20, 2026 at 9:30am")
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.isStrongSignal, false, "a time with nothing corroborating it is still only a date")
    }

    func testBareDateIsNotStrongEvenWithALink() {
        // The case the setting exists to refuse: prose that mentions a day.
        let event = detect("Q3 ends September 30, 2026 — details at https://us02web.zoom.us/j/89123456789")
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.isStrongSignal, false)
        XCTAssertEqual(event?.isAllDay, true)
    }

    // MARK: - All-day

    func testUntitledDateBecomesAWholeDay() {
        let event = detect("All hands on August 20, 2026")
        XCTAssertEqual(event?.isAllDay, true)
        XCTAssertEqual(event?.start, calendar.date(from: DateComponents(year: 2026, month: 8, day: 20)))
        XCTAssertEqual(event?.duration, 86_400, "end is the start of the following day")
    }

    func testAllDayStartIsMidnightNotTheDetectorsNoon() {
        let event = detect("Launch August 20, 2026")
        let hour = calendar.component(.hour, from: event?.start ?? .distantPast)
        XCTAssertEqual(hour, 0, "NSDataDetector returns noon for an untimed date; it must be widened to the day")
    }

    // MARK: - Duration

    func testStatedRangeIsKept() {
        let event = detect("Team offsite September 3, 2026 from 9am to 5pm at 1 Infinite Loop, Cupertino, CA 95014")
        XCTAssertEqual(event?.duration, 8 * 3600)
    }

    func testMissingEndFallsBackToTheDefault() {
        let event = detect("Standup on August 20, 2026 at 9:30am")
        XCTAssertEqual(event?.duration, EventDetector.defaultDuration)
    }

    func testDefaultDurationIsHonoured() {
        let event = EventDetector.detect(
            "Standup on August 20, 2026 at 9:30am",
            fallbackTitle: "Untitled",
            defaultDuration: 1800,
            calendar: calendar
        )
        XCTAssertEqual(event?.duration, 1800)
    }

    func testAbsurdDurationIsRefused() {
        // "ends September 30" reads as a range running from today, which the
        // detector reports as tens of days.
        let event = detect("The quarter ends September 30, 2026 at 5:00 PM")
        XCTAssertNotNil(event)
        XCTAssertLessThanOrEqual(event?.duration ?? .infinity, EventDetector.maxTextDuration)
    }

    // MARK: - Titles

    func testTitleComesFromTheLineAboveTheDetails() {
        let event = detect("""
        Sprint planning
        August 24, 2026, 10:00–11:30
        https://meet.google.com/xyz-abcd-efg
        """)
        XCTAssertEqual(event?.title, "Sprint planning")
    }

    func testTitleSurvivesSharingItsLineWithTheDate() {
        let event = detect("Design review August 20, 2026 at 3:00 PM")
        XCTAssertEqual(event?.title, "Design review")
    }

    func testLabelPunctuationIsTrimmedOffTheTitle() {
        let event = detect("Subject: Budget sync — August 20, 2026 at 2:00 PM")
        XCTAssertEqual(event?.title.hasPrefix("Subject"), false)
        XCTAssertEqual(event?.title.contains("Budget sync"), true)
    }

    func testATitleThatMerelyContainsAColonIsKeptWhole() {
        let event = detect("Postmortem: the April outage\nAugust 20, 2026 at 3:00 PM")
        XCTAssertEqual(event?.title, "Postmortem: the April outage")
    }

    func testTrailingConnectorIsTrimmedOffTheTitle() {
        // "Call with mehdi the 18 of Aug…" — the date match starts at "18",
        // so striking it out leaves the article stranded at the end.
        let event = detect("Call with mehdi the 18 of Aug 2026 at 12:55")
        XCTAssertEqual(event?.title, "Call with mehdi")
    }

    func testTrailingConnectorsAreTrimmedRepeatedly() {
        XCTAssertEqual(detect("Sync on the 20 August 2026 at 3:00 PM")?.title, "Sync")
        XCTAssertEqual(detect("Review at 20 August 2026 at 3:00 PM")?.title, "Review")
    }

    func testAConnectorInsideTheTitleIsKept() {
        let event = detect("Call with the design team\n20 August 2026 at 3:00 PM")
        XCTAssertEqual(event?.title, "Call with the design team")
    }

    func testATitleThatIsOnlyAConnectorFallsBack() {
        let event = detect("the 20 August 2026 at 3:00 PM", fallback: "Event")
        XCTAssertEqual(event?.title, "Event")
    }

    func testFallbackTitleIsUsedWhenNothingSurvives() {
        let event = detect("August 20, 2026 at 3:00 PM", fallback: "Screenshot")
        XCTAssertEqual(event?.title, "Screenshot")
    }

    func testTitleIsClamped() {
        let long = String(repeating: "a", count: 400)
        let event = detect("\(long)\nAugust 20, 2026 at 3:00 PM")
        XCTAssertEqual(event?.title.count, 120)
    }

    // MARK: - Meeting links

    func testRecognisedMeetingHosts() {
        for host in [
            "https://us02web.zoom.us/j/8912",
            "https://meet.google.com/xyz-abcd-efg",
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting",
            "https://acme.webex.com/meet/sam",
            "https://whereby.com/team"
        ] {
            XCTAssertTrue(EventDetector.isMeetingURL(URL(string: host)!), host)
        }
    }

    func testMeetingSubdomainsCountWhateverTheService() {
        // The named list can never be complete — a host whose first label
        // says what it is counts on its own.
        for host in [
            "https://meet.proton.me/callurl",
            "https://call.example.org/abc",
            "https://video.acme.co/room/9",
            "https://vc.example.com/x"
        ] {
            XCTAssertTrue(EventDetector.isMeetingURL(URL(string: host)!), host)
        }
    }

    func testProtonCallIsAStrongSignal() {
        let event = detect("Call with mehdi the 18 of Aug 2026 at 12:55 https://meet.proton.me/callurl")
        XCTAssertEqual(event?.title, "Call with mehdi")
        XCTAssertEqual(event?.meetingURL?.host(), "meet.proton.me")
        XCTAssertEqual(event?.isStrongSignal, true, "a timed call with a meeting link must create on its own")
    }

    func testOrdinaryLinksAreNotMeetings() {
        XCTAssertFalse(EventDetector.isMeetingURL(URL(string: "https://example.com/zoom.us")!))
        XCTAssertFalse(EventDetector.isMeetingURL(URL(string: "https://notzoom.us.example.com")!))
    }

    func testOnlyTheMeetingLinkIsPicked() {
        let event = detect("""
        Design review
        August 20, 2026 at 3:00 PM
        Agenda: https://example.com/agenda
        Join: https://meet.google.com/xyz-abcd-efg
        """)
        XCTAssertEqual(event?.meetingURL?.host(), "meet.google.com")
    }

    // MARK: - Clock times

    func testClockTimeForms() {
        for text in ["15:00", "3:00 PM", "3 PM", "9am", "9 a.m.", "14h30"] {
            XCTAssertTrue(EventDetector.namesAClockTime(text), text)
        }
    }

    func testNonClockTimeForms() {
        for text in ["August 20, 2026", "Friday", "24 hours", "2026-08-20", "Q3"] {
            XCTAssertFalse(EventDetector.namesAClockTime(text), text)
        }
    }

    // MARK: - Addresses

    func testAddressLineOrderIsStable() {
        let components: [NSTextCheckingKey: String] = [
            .zip: "95014", .state: "CA", .street: "1 Infinite Loop", .city: "Cupertino"
        ]
        XCTAssertEqual(
            EventDetector.addressLine(from: components),
            "1 Infinite Loop, Cupertino, CA, 95014"
        )
    }

    func testEmptyAddressIsNil() {
        XCTAssertNil(EventDetector.addressLine(from: nil))
        XCTAssertNil(EventDetector.addressLine(from: [.city: "   "]))
    }

    // MARK: - Bounds

    func testOversizeInputIsScannedOnlyToTheCap() {
        let filler = String(repeating: "x", count: EventDetector.maxScannedUTF8Bytes + 100)
        XCTAssertNil(detect(filler + "\nAugust 20, 2026 at 3:00 PM"))
    }

    func testEventInsideTheCapIsStillFound() {
        let filler = String(repeating: "x", count: 100)
        XCTAssertNotNil(detect(filler + "\nAugust 20, 2026 at 3:00 PM"))
    }
}
