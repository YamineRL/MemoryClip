import AppKit
import UserNotifications

/// The banner an automatically created event announces itself with, and the
/// two buttons on it.
///
/// # Nothing here may run without a bundle
///
/// `UNUserNotificationCenter.current()` does not fail politely in a process
/// that is not an application bundle — it raises, taking the process with it.
/// Under `swift test` and `swift run` there is no `Info.plist` of MemoryClip's
/// (the same condition `AppVersionInfo` documents for the About pane), so
/// every entry point below opens with `isAvailable` and every test in the
/// suite would otherwise be one automatic event away from a crash rather than
/// a failure.
///
/// That is also why the shape is split: `message(...)` is a pure function of
/// its arguments, returning the two lines the banner shows, and is what the
/// tests exercise. `post(...)` is the delivery half, and is inert — a silent
/// early return — anywhere the notification centre cannot be reached.
///
/// # Permission
///
/// Authorization is requested at the first *post*, not at launch. A menu-bar
/// app that asks to send notifications before it has anything to say is asking
/// the user to answer a question they have no way to judge; asked at the
/// moment MemoryClip has actually put something in a calendar, the question
/// answers itself. `.alert` only: nothing here is worth a sound or a red dot
/// on an app icon that does not exist.
///
/// A denial is final and silent. The event is still in the calendar and the
/// clip still says `· in calendar` in the panel, which is the same information
/// arriving somewhere the user chose to look.
enum EventNotifier {
    /// The category the two actions hang off, named on every request so the
    /// buttons appear on the banner.
    static let categoryIdentifier = "app.memoryclip.calendarEvent"
    /// Removes the event again — `CalendarCoordinator.undoEvent(_:)` on the
    /// operation the banner carries in its `userInfo`.
    static let undoActionIdentifier = "app.memoryclip.calendarEvent.undo"
    /// Brings up Calendar so the user can see what landed.
    static let openActionIdentifier = "app.memoryclip.calendarEvent.open"

    /// The category of the OFFER — the question an appointment-shaped clip
    /// asks before anything is written. Separate from the created-event
    /// banner: this one carries the clip's uuid and proposes rather than
    /// announces, and tapping its body must NOT count as a yes — only the
    /// Add button may say yes.
    static let offerCategoryIdentifier = "app.memoryclip.calendarOffer"
    /// Writes the offered event to the calendar.
    static let addActionIdentifier = "app.memoryclip.calendarOffer.add"
    /// Opens the offered event as an .ics in the default calendar app, where
    /// it is a draft the user edits before it is anything at all.
    static let editActionIdentifier = "app.memoryclip.calendarOffer.edit"
    /// Says no. An explicit button rather than relying on the banner's close
    /// control: the question deserves its answers visible. It does nothing
    /// on purpose — declining must not record anything.
    static let declineActionIdentifier = "app.memoryclip.calendarOffer.decline"

    /// The two lines of the banner.
    struct Message: Equatable {
        let title: String
        let body: String
    }

    /// Whether this process can talk to the notification centre at all.
    ///
    /// See the header: `current()` traps rather than returning nil, so this is
    /// not an optimisation, it is the guard that keeps the test suite alive.
    ///
    /// Both halves are load-bearing. A missing bundle identifier is the
    /// obvious case, but it is not the one the test suite is in: `xctest`
    /// injects `com.apple.dt.xctest.tool` into the info dictionary of a
    /// *directory* — `/Applications/Xcode.app/Contents/Developer/usr/bin` —
    /// so the identifier is there while the bundle behind it is not, and
    /// `current()` raises `bundleProxyForCurrentProcess is nil` on the spot.
    /// Requiring the main bundle to actually be an `.app` is what tells the
    /// built application apart from every other way this code can be loaded.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    // MARK: - What it says

    /// The banner text for one created event.
    ///
    /// Pure, and taking values rather than an `EventReceipt`, so it is
    /// testable without a notification centre, without EventKit and without a
    /// bundle — which between them is everything this function would otherwise
    /// need to be exercised at all.
    ///
    /// The start is rendered through a `Date.FormatStyle` carrying the app's
    /// own locale rather than the system's: MemoryClip's language is resolved
    /// against the catalogue it ships (see `L10n`), so a French user reading
    /// French strings must not get an English date in the middle of one. The
    /// style, not a format string, because the order of day, month and time —
    /// and the word between them — differs per locale and is not ours to
    /// guess.
    ///
    /// An all-day event drops the time entirely and spells the day out: "at
    /// 00:00" is not when it starts, it is an artefact of how midnight is
    /// stored.
    static func message(
        eventTitle: String,
        start: Date,
        isAllDay: Bool,
        calendarTitle: String,
        locale: Locale = L10n.locale
    ) -> Message {
        let when = isAllDay
            ? start.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(locale))
            : start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
        return Message(
            title: loc("Added to your %@ calendar", calendarTitle),
            body: loc("%@ — %@", eventTitle, when)
        )
    }

    /// The banner text for the offer — the same event line under a question
    /// instead of a past-tense claim. Nothing has been created at this point,
    /// and the wording must not pretend otherwise.
    static func offerMessage(
        eventTitle: String,
        start: Date,
        isAllDay: Bool,
        locale: Locale = L10n.locale
    ) -> Message {
        let when = isAllDay
            ? start.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(locale))
            : start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
        return Message(
            title: loc("Add this event to your calendar?"),
            body: loc("%@ — %@", eventTitle, when)
        )
    }

    // MARK: - Delivery

    /// Announce one created event, if the user will have it.
    ///
    /// Every failure here is silent on purpose: an event that could not be
    /// announced is still an event, and there is no window open to complain
    /// in when this runs.
    ///
    /// `operation` is the creation the banner announces, and the undo its
    /// button must name: it rides in `userInfo` and becomes the request's
    /// identifier, so the delegate can retract THIS creation rather than
    /// whatever happened to be saved last — two events' banners each undo
    /// their own.
    @MainActor
    static func post(
        eventTitle: String,
        start: Date,
        isAllDay: Bool,
        calendarTitle: String,
        operation: UUID
    ) async {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        guard await isAuthorized(center) else { return }

        let text = message(
            eventTitle: eventTitle,
            start: start,
            isAllDay: isAllDay,
            calendarTitle: calendarTitle
        )
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.categoryIdentifier = categoryIdentifier
        content.userInfo["operationID"] = operation.uuidString
        // The event's own start rides along so a body tap can land Calendar
        // on the right day via calshow: — the app cannot resolve its event
        // back under write-only access, but a date is all the scheme needs.
        content.userInfo["eventStart"] = start.timeIntervalSinceReferenceDate

        // No trigger: deliver now. The operation is the request's identifier
        // too — a repost of the same creation would replace its banner
        // rather than stack a second one.
        let request = UNNotificationRequest(
            identifier: operation.uuidString,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            log.error("Calendar notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ask the user whether to add this clip's event, if notifications are
    /// allowed.
    ///
    /// The clip's uuid rides in `userInfo` and names the request, so a second
    /// offer for the same clip replaces the first rather than stacking — and
    /// the delegate's Add button can find the clip again without the banner
    /// carrying anything it does not need.
    ///
    /// An unauthorized centre declines silently, the same deal the created-
    /// event banner makes: the offer is the nicety, not the feature. The
    /// clip still exists, and the panel's button is still the way to add it.
    @MainActor
    static func postOffer(
        eventTitle: String,
        start: Date,
        isAllDay: Bool,
        clipUUID: UUID
    ) async {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        guard await isAuthorized(center) else { return }

        let text = offerMessage(eventTitle: eventTitle, start: start, isAllDay: isAllDay)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.categoryIdentifier = offerCategoryIdentifier
        content.userInfo["clipUUID"] = clipUUID.uuidString

        let request = UNNotificationRequest(
            identifier: "offer-\(clipUUID.uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            log.error("Calendar offer failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Retract the offer banner for `clipUUID`, if one is still showing.
    ///
    /// An answered question should not stay on screen: a banner left behind
    /// invites a second answer the coordinator can only refuse.
    @MainActor
    static func dismissOffer(forClipWith uuid: UUID) {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["offer-\(uuid.uuidString)"]
        )
    }

    /// Ask for permission, or confirm we already have it.
    ///
    /// `requestAuthorization` is the whole check: after the first answer it
    /// returns what macOS recorded without prompting again, so this can be
    /// called on every post without the user ever seeing a second dialog.
    @MainActor
    private static func isAuthorized(_ center: UNUserNotificationCenter) async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert])
        } catch {
            log.error("Notification permission failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Undo, and a way to go and look.
    ///
    /// Undo is not `.destructive`: red is for what you cannot take back, and
    /// this button is the taking back. Opening Calendar is `.foreground`
    /// because it activates another app.
    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [
                UNNotificationAction(identifier: undoActionIdentifier, title: loc("Undo"), options: []),
                UNNotificationAction(
                    identifier: openActionIdentifier,
                    title: loc("Open in Calendar"),
                    options: [.foreground]
                )
            ],
            intentIdentifiers: [],
            options: []
        )
    }

    /// The offer's three answers.
    ///
    /// Add and Edit are `.foreground`: Add may have to raise the first TCC
    /// prompt — legitimate only when something the user pressed asks for it —
    /// and Edit hands an .ics to another app, which is what foreground is
    /// for. Not Now needs no option because it does nothing.
    static var offerCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: offerCategoryIdentifier,
            actions: [
                UNNotificationAction(
                    identifier: addActionIdentifier,
                    title: loc("Add"),
                    options: [.foreground]
                ),
                UNNotificationAction(
                    identifier: editActionIdentifier,
                    title: loc("Edit…"),
                    options: [.foreground]
                ),
                UNNotificationAction(
                    identifier: declineActionIdentifier,
                    title: loc("Not Now"),
                    options: []
                ),
            ],
            intentIdentifiers: [],
            options: []
        )
    }
}
