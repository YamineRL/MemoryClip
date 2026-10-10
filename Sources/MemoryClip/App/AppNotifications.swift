import AppKit
import UserNotifications

/// Everything MemoryClip can put in Notification Centre, registered once.
///
/// `UNUserNotificationCenter` has one delegate and one set of categories, so
/// however many features post banners, exactly one place may install them.
/// Before there were two, that place was `EventNotifier` itself; a second
/// caller would have replaced the calendar's category rather than joined it,
/// and the Undo button would have quietly stopped appearing.
enum AppNotifications {
    /// Register every category and take delivery of taps.
    ///
    /// Called once at launch. The centre holds its delegate weakly, so the
    /// caller keeps `delegate` alive for as long as the app runs —
    /// `AppDelegate` does, in a stored property.
    @MainActor
    static func install(delegate: any UNUserNotificationCenterDelegate) {
        guard EventNotifier.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories([
            EventNotifier.category,
            EventNotifier.offerCategory,
            UpdateNotifier.category,
        ])
    }
}

/// Answers the buttons on MemoryClip's banners.
///
/// Kept apart from the notifiers because they are stateless enums that
/// anything may post through, while this holds the objects the buttons act
/// on. `AppDelegate` owns one for the life of the app — the notification
/// centre's `delegate` is a weak reference, and a delegate that has been
/// deallocated is a button that does nothing.
@MainActor
final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let calendarCoordinator: CalendarCoordinator
    private let updateChecker: UpdateChecker

    init(calendarCoordinator: CalendarCoordinator, updateChecker: UpdateChecker) {
        self.calendarCoordinator = calendarCoordinator
        self.updateChecker = updateChecker
    }

    /// Show the banner even when MemoryClip is the active app.
    ///
    /// Left alone, macOS suppresses a notification an app posts to itself
    /// while it is frontmost — which for a menu-bar app means the banner
    /// vanishes exactly when the panel is open, the one moment the user is
    /// looking at MemoryClip.
    ///
    /// `nonisolated` so it witnesses the requirement whatever isolation the
    /// SDK declares it with; it touches nothing of this object's.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    /// Act on a tapped button.
    ///
    /// Only value types cross to the main actor: `UNNotificationResponse`
    /// is a reference type that is not `Sendable`, so the action identifier
    /// and the creation's operation uuid are read off here and passed over.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        let operation = (content.userInfo["operationID"] as? String)
            .flatMap(UUID.init(uuidString:))
        let clipUUID = (content.userInfo["clipUUID"] as? String)
            .flatMap(UUID.init(uuidString:))
        let eventStart = (content.userInfo["eventStart"] as? TimeInterval)
            .map(Date.init(timeIntervalSinceReferenceDate:))
        log.notice("Notification action \(response.actionIdentifier, privacy: .public) on \(content.categoryIdentifier, privacy: .public)")
        await handle(
            response.actionIdentifier,
            operation: operation,
            clipUUID: clipUUID,
            eventStart: eventStart,
            category: content.categoryIdentifier
        )
    }

    private func handle(_ action: String, operation: UUID?, clipUUID: UUID?, eventStart: Date?, category: String) async {
        switch action {
        case EventNotifier.undoActionIdentifier:
            // The banner names the creation it announced; undo retracts THAT
            // one, not whatever was saved most recently. A banner from an
            // older run carries no operation the coordinator still knows —
            // the answer is `.undoUnavailable`, not silence.
            if let operation {
                _ = await calendarCoordinator.undoEvent(operation)
            } else {
                _ = await calendarCoordinator.undoLastEvent()
            }
        case EventNotifier.openActionIdentifier:
            Self.openCalendar(showing: eventStart)
        case EventNotifier.addActionIdentifier:
            // The offer's yes. A clip that disappeared behind its banner is
            // answered by the coordinator's own error path.
            if let clipUUID {
                _ = await calendarCoordinator.acceptOfferedEvent(forClipWith: clipUUID)
            }
        case EventNotifier.editActionIdentifier:
            // The offer's edit: the appointment becomes a draft .ics in the
            // default calendar app — editable before it is anything, and
            // nothing at all if it is discarded.
            if let clipUUID, let detected = calendarCoordinator.detectedEvent(forClipWith: clipUUID) {
                EventICSDocument.openDraft(for: detected, uid: clipUUID.uuidString)
            }
        case EventNotifier.declineActionIdentifier:
            // Not Now, said out loud: the question is answered, so the
            // banner asking it goes too.
            if let clipUUID {
                EventNotifier.dismissOffer(forClipWith: clipUUID)
            }
        case UpdateNotifier.downloadActionIdentifier:
            // The banner outlives the check that posted it — it can be sitting
            // in Notification Centre days later — so the release is looked up
            // again rather than taken from whatever `status` still holds.
            if let update = updateChecker.pendingUpdate {
                updateChecker.download(update)
            } else {
                updateChecker.check(userInitiated: false)
            }
        case UNNotificationDefaultActionIdentifier:
            // The banner's body was tapped. For the created-event banner that
            // means "show me what landed" — Calendar opened on the event's own
            // day, not at today. For the offer it raises the question as a
            // real dialog: a banner-style notification hides its buttons under
            // a hover chevron, and an answer must never hinge on the user
            // knowing that.
            if category == EventNotifier.categoryIdentifier {
                Self.openCalendar(showing: eventStart)
            } else if category == EventNotifier.offerCategoryIdentifier, let clipUUID {
                presentOfferDialog(forClipWith: clipUUID)
            }
        default:
            // The banner's own close control and dismissals — neither is
            // an instruction.
            break
        }
    }

    /// The offer's body tap, raised as a real dialog.
    ///
    /// Banner-style notifications — the style macOS defaults to — show no
    /// buttons until the user hovers and opens the chevron, so for most
    /// users the offer reads as an announcement, not a question. The dialog
    /// gives the tap the three answers the banner carries: Add writes the
    /// event, Edit drafts it as an .ics, Not Now closes. A clip that vanished
    /// behind its banner is logged, not answered.
    private func presentOfferDialog(forClipWith uuid: UUID) {
        guard let detected = calendarCoordinator.detectedEvent(forClipWith: uuid) else {
            log.notice("Offer tapped for a clip that no longer holds an event")
            return
        }
        let text = EventNotifier.offerMessage(
            eventTitle: detected.title,
            start: detected.start,
            isAllDay: detected.isAllDay,
            location: detected.location
        )
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = text.title
        alert.informativeText = text.body
        alert.addButton(withTitle: loc("Add"))
        alert.addButton(withTitle: loc("Edit…"))
        alert.addButton(withTitle: loc("Not Now"))
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { _ = await calendarCoordinator.acceptOfferedEvent(forClipWith: uuid) }
        case .alertSecondButtonReturn:
            EventICSDocument.openDraft(for: detected, uid: uuid.uuidString)
        default:
            break
        }
    }

    /// Bring up Calendar, on the event's own day when one is known.
    ///
    /// `calshow:` — the old undocumented scheme — is not claimed by anything
    /// on this system, so navigation goes through Calendar's own scripting
    /// interface: `view calendar at` needs only a date, which is all
    /// write-only EventKit access leaves in MemoryClip's hands anyway. A
    /// refused Automation consent, an unanswered consent prompt, or a
    /// missing date degrades to opening the app plain.
    private static func openCalendar(showing date: Date? = nil) {
        if let date, showCalendar(at: date) {
            // The event landed Calendar on the event's day; bring it forward.
            activateCalendar()
            return
        }
        activateCalendar()
    }

    /// Ask Calendar to display `date` ("view calendar", event class 'wrbt'
    /// id 'aec9', per its scripting dictionary). The date rides as a raw
    /// long-date-time parameter rather than an AppleScript string, so the
    /// call does not depend on the user's locale. Consent is the price: the
    /// first send raises macOS's "MemoryClip wants to control Calendar"
    /// prompt — legitimate here, behind a button the user pressed.
    private static func showCalendar(at date: Date) -> Bool {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(0x7772_6274), // 'wrbt'
            eventID: AEEventID(0x6165_6339), // 'aec9'
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.iCal"),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(date: date),
            forKeyword: AEKeyword(0x7774_6474) // 'wtdt' — at <date>
        )
        do {
            // waitForReply distinguishes a delivered command from a refused
            // one — a noReply send would leave the fallback unreachable —
            // and the timeout keeps a pending consent prompt from hanging
            // the notification handler.
            _ = try event.sendEvent(options: .waitForReply, timeout: 5)
            return true
        } catch {
            log.error("Calendar navigation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Launch or foreground Calendar without a destination.
    private static func activateCalendar() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else {
            log.error("Calendar.app could not be located")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
