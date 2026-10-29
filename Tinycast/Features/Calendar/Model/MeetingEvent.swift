import Foundation

/// One calendar occurrence, flattened out of EventKit or JoyDay so nothing source-shaped reaches a view.
struct MeetingEvent: Identifiable, Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case eventKit
        case joyDay
    }

    /// Unique per occurrence: a recurring series shares one event identifier across every instance.
    let id: String
    let source: Source
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let isDeclined: Bool
    let calendarID: String
    let calendarName: String
    let calendarColor: CalendarColor?
    /// EventKit's `calendarItemIdentifier` — the only handle Calendar.app's `ical://` URL accepts.
    let calendarItemID: String?
    let link: MeetingLink?
    /// JoyDay's list rows say an event is an online meeting without carrying its link, which is
    /// fetched for the one occurrence whenever it is joined or copied.
    let hasOnlineMeeting: Bool
    /// JoyDay's handles for this exact occurrence; nil for EventKit.
    let joyDay: JoyDayRef?

    private static let entryPrefix = "meeting:"

    var entryID: String { Self.entryPrefix + id }

    static func id(fromEntryID entryID: String) -> String? {
        guard entryID.hasPrefix(entryPrefix) else { return nil }
        return String(entryID.dropFirst(entryPrefix.count))
    }

    /// A join link, or the promise of one that has to come from JoyDay's detail API first.
    var canJoinMeeting: Bool { link != nil || hasOnlineMeeting }

    /// What the UI names before the link resolves: a JoyDay online meeting is JD's own.
    var meetingProvider: MeetingLink.Provider? {
        link?.provider ?? (hasOnlineMeeting ? .jdMeeting : nil)
    }

    func isInProgress(now: Date) -> Bool { start <= now && now < end }
}

extension MeetingEvent {
    /// The values JoyDay's detail API keys one occurrence by.
    struct JoyDayRef: Hashable, Sendable {
        let scheduleID: String
        let calendarID: String
        let originalStart: Date?
    }
}

extension MeetingEvent {
    /// The owning calendar's colour as sRGB components, so the model stays free of AppKit.
    struct CalendarColor: Hashable, Sendable {
        let red: Double
        let green: Double
        let blue: Double
    }
}
