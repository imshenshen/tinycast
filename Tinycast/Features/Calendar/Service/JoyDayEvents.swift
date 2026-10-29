import Foundation

/// Turns JoyDay's rows into the same flat occurrence shape EventKit produces.
///
/// JoyDay sends one row per series plus rows for instances that were moved or deleted, and leaves
/// expansion to its web client. These are that client's rules, so the palette shows exactly the
/// occurrences the JoyDay page does.
enum JoyDayEvents {
    static let calendarPrefix = "joyday:"

    static func meetingEvents(
        appointments: [JoyDayAppointment],
        calendars: [JoyDayCalendar],
        window: DateInterval,
        calendar: Calendar = .current
    ) -> [MeetingEvent] {
        let calendarsByID = Dictionary(
            calendars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var excludedDays: [SeriesKey: Set<Date>] = [:]
        var series: [JoyDayAppointment] = []
        var singles: [JoyDayAppointment] = []

        for appointment in appointments {
            let key = SeriesKey(appointment)
            switch appointment.appointmentType {
            case "Exception", "Occurrence":
                // A moved or removed instance: blank its original day out of the series. Its own
                // row renders below unless it is the marker for a deletion.
                excludedDays[key, default: []].formUnion(
                    daysCovered(by: appointment, until: window.end, calendar: calendar))
                if !appointment.isDeleted, !appointment.isCancelled {
                    singles.append(appointment)
                }
            default:
                guard !appointment.isDeleted, !appointment.isCancelled else { continue }
                if hasRecurrence(appointment) {
                    series.append(appointment)
                } else {
                    singles.append(appointment)
                }
            }
        }

        var events: [MeetingEvent] = []
        events.reserveCapacity(appointments.count)
        for appointment in series {
            let excluded = excludedDays[SeriesKey(appointment)] ?? []
            for start in occurrenceStarts(
                of: appointment, window: window, excluding: excluded, calendar: calendar)
            {
                events.append(
                    Self.event(
                        from: appointment, start: start, calendars: calendarsByID,
                        calendar: calendar))
            }
        }
        for appointment in singles {
            let start = appointment.start
            let end = appointment.end
            guard end > window.start, start < window.end else { continue }
            events.append(
                Self.event(
                    from: appointment, start: start, calendars: calendarsByID, calendar: calendar))
        }
        return events.sorted { $0.start < $1.start }
    }

    // MARK: - Series

    private struct SeriesKey: Hashable {
        let scheduleID: String
        let calendarID: String

        init(_ appointment: JoyDayAppointment) {
            scheduleID = appointment.scheduleID
            calendarID = appointment.calendarID
        }
    }

    private static func hasRecurrence(_ appointment: JoyDayAppointment) -> Bool {
        if let rrule = appointment.rrule, !rrule.isEmpty { return true }
        switch appointment.repeatType {
        case "WorkDay", "EveryDay", "EveryWeek", "EveryTwoWeeks", "EveryMonth", "EveryYear":
            return true
        default:
            return false
        }
    }

    /// Days blanked out of a series: one day for a moved instance, a range for a removed tail.
    private static func daysCovered(
        by appointment: JoyDayAppointment, until limit: Date, calendar: Calendar
    ) -> Set<Date> {
        var days: Set<Date> = []
        if let repeatEnd = appointment.repeatEnd {
            var day = calendar.startOfDay(for: appointment.repeatStart ?? appointment.start)
            let end = min(repeatEnd, limit)
            while day < end, days.count < 3_000 {
                days.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        } else {
            days.insert(calendar.startOfDay(for: appointment.start))
            if let original = appointment.originalStart {
                days.insert(calendar.startOfDay(for: original))
            }
        }
        return days
    }

    private static func occurrenceStarts(
        of appointment: JoyDayAppointment,
        window: DateInterval,
        excluding excluded: Set<Date>,
        calendar: Calendar
    ) -> [Date] {
        let seriesStart = appointment.start
        let duration = max(0, appointment.end.timeIntervalSince(appointment.start))
        let earliest = window.start.addingTimeInterval(-duration)
        let limit = min(appointment.repeatEnd ?? window.end, window.end)
        guard limit > seriesStart || appointment.repeatEnd != nil else {
            return seriesStart < window.end && appointment.end > window.start ? [seriesStart] : []
        }

        var starts: [Date] = []

        /// False once the series is past the window, so every loop can stop on it.
        func consider(_ day: Date) -> Bool {
            let start = combine(day: day, timeOf: seriesStart, calendar: calendar)
            guard start < limit else { return false }
            if start >= earliest, !excluded.contains(calendar.startOfDay(for: start)) {
                starts.append(start)
            }
            return true
        }

        if let rule = appointment.rrule.flatMap(RecurrenceRule.init) {
            var counted = 0
            var day = startDay(of: seriesStart, calendar: calendar)
            var steps = 0
            while day < limit, steps < 20_000 {
                steps += 1
                if rule.matches(day, seriesStart: seriesStart, calendar: calendar) {
                    counted += 1
                    if let count = rule.count, counted > count { break }
                    if !consider(day) { break }
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            return starts
        }

        switch appointment.repeatType {
        case "WorkDay":
            var day = startDay(of: seriesStart, calendar: calendar)
            var steps = 0
            while day < limit, steps < 20_000 {
                steps += 1
                let weekday = calendar.component(.weekday, from: day)
                if weekday != 1, weekday != 7, !consider(day) { break }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        case "EveryDay":
            step(.day, 1, from: seriesStart, until: limit, calendar: calendar, consider)
        case "EveryWeek":
            step(.weekOfYear, 1, from: seriesStart, until: limit, calendar: calendar, consider)
        case "EveryTwoWeeks":
            step(.weekOfYear, 2, from: seriesStart, until: limit, calendar: calendar, consider)
        case "EveryMonth":
            step(.month, 1, from: seriesStart, until: limit, calendar: calendar, consider)
        case "EveryYear":
            step(.year, 1, from: seriesStart, until: limit, calendar: calendar, consider)
        default:
            if seriesStart < window.end, appointment.end > window.start { starts.append(seriesStart) }
        }
        return starts
    }

    private static func startDay(of date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    private static func step(
        _ component: Calendar.Component, _ value: Int, from start: Date, until limit: Date,
        calendar: Calendar, _ consider: (Date) -> Bool
    ) {
        var cursor = start
        var steps = 0
        while cursor < limit, steps < 20_000 {
            steps += 1
            if !consider(cursor) { break }
            guard let next = calendar.date(byAdding: component, value: value, to: cursor) else {
                break
            }
            cursor = next
        }
    }

    /// The series' start time of day, on another day.
    private static func combine(day: Date, timeOf reference: Date, calendar: Calendar) -> Date {
        let time = calendar.dateComponents([.hour, .minute, .second], from: reference)
        return calendar.date(
            bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0,
            of: day) ?? day
    }

    // MARK: - RRULE

    private struct RecurrenceRule {
        let frequency: Frequency
        let interval: Int
        let count: Int?
        let until: Date?
        let byDay: Set<Int>
        /// The weekday a week starts on, from WKST; Sunday when absent.
        let weekStart: Int

        enum Frequency: String {
            case daily = "DAILY"
            case weekly = "WEEKLY"
            case monthly = "MONTHLY"
            case yearly = "YEARLY"
        }

        init?(_ text: String) {
            var fields: [String: String] = [:]
            for pair in text.uppercased().split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                fields[String(parts[0])] = String(parts[1])
            }
            guard let raw = fields["FREQ"], let frequency = Frequency(rawValue: raw) else {
                return nil
            }
            self.frequency = frequency
            interval = max(1, Int(fields["INTERVAL"] ?? "") ?? 1)
            count = Int(fields["COUNT"] ?? "")
            until = fields["UNTIL"].flatMap(Self.parse)
            weekStart = Self.weekdays[fields["WKST"] ?? "SU"] ?? 1
            var weekdays: Set<Int> = []
            if let byDay = fields["BYDAY"] {
                for token in byDay.split(separator: ",") {
                    // Ordinal prefixes ("1MO", "-1FR") are beyond what JoyDay writes.
                    let code = token.suffix(2)
                    if let weekday = Self.weekdays[String(code)] { weekdays.insert(weekday) }
                }
            }
            byDay = weekdays
        }

        /// Falls back to the series start's weekday when BYDAY is absent.
        func matches(_ day: Date, seriesStart: Date, calendar: Calendar) -> Bool {
            guard day >= calendar.startOfDay(for: seriesStart) else { return false }
            if let until, day > calendar.startOfDay(for: until) { return false }
            let days = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: seriesStart), to: day
            ).day ?? 0
            switch frequency {
            case .daily:
                return days % interval == 0
            case .weekly:
                let weekdays = byDay.isEmpty
                    ? [calendar.component(.weekday, from: seriesStart)] : Array(byDay)
                guard weekdays.contains(calendar.component(.weekday, from: day)) else {
                    return false
                }
                // Intervals count weeks from the WKST boundary, not from the start day.
                return weeksSinceStart(of: day, seriesStart: seriesStart, calendar: calendar)
                    % interval == 0
            case .monthly:
                let months = calendar.dateComponents(
                    [.month], from: calendar.startOfDay(for: seriesStart), to: day
                ).month ?? 0
                return months % interval == 0
                    && calendar.component(.day, from: day)
                        == calendar.component(.day, from: seriesStart)
            case .yearly:
                let years = calendar.dateComponents(
                    [.year], from: calendar.startOfDay(for: seriesStart), to: day
                ).year ?? 0
                return years % interval == 0
                    && calendar.component(.month, from: day)
                        == calendar.component(.month, from: seriesStart)
                    && calendar.component(.day, from: day)
                        == calendar.component(.day, from: seriesStart)
            }
        }

        private func weeksSinceStart(
            of day: Date, seriesStart: Date, calendar: Calendar
        ) -> Int {
            let start = weekStartDay(for: seriesStart, calendar: calendar)
            let current = weekStartDay(for: day, calendar: calendar)
            let days = calendar.dateComponents([.day], from: start, to: current).day ?? 0
            return days / 7
        }

        private func weekStartDay(for date: Date, calendar: Calendar) -> Date {
            let day = calendar.startOfDay(for: date)
            let weekday = calendar.component(.weekday, from: day)
            let offset = (weekday - weekStart + 7) % 7
            return calendar.date(byAdding: .day, value: -offset, to: day) ?? day
        }

        private static let weekdays: [String: Int] = [
            "SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7,
        ]

        private static func parse(_ value: String) -> Date? {
            // iCal writes 20260501T090000Z; some producers write a plain date.
            let formats = ["yyyyMMdd'T'HHmmss'Z'", "yyyyMMdd'T'HHmmss", "yyyyMMdd"]
            for format in formats {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = format.hasSuffix("'Z'") ? TimeZone(secondsFromGMT: 0) : .current
                formatter.dateFormat = format
                if let date = formatter.date(from: value) { return date }
            }
            return ISO8601DateFormatter().date(from: value)
        }
    }

    // MARK: - Mapping

    private static func event(
        from appointment: JoyDayAppointment, start: Date,
        calendars: [String: JoyDayCalendar], calendar: Calendar
    ) -> MeetingEvent {
        let duration = max(0, appointment.end.timeIntervalSince(appointment.start))
        let end = start.addingTimeInterval(duration)
        let info = calendars[appointment.calendarID]
        return MeetingEvent(
            id: "\(calendarPrefix)\(appointment.scheduleID)|\(appointment.calendarID)"
                + "|\(Int(start.timeIntervalSince1970))",
            source: .joyDay,
            title: appointment.title,
            start: start,
            end: end,
            isAllDay: appointment.isAllDay,
            isDeclined: appointment.isDeclined,
            calendarID: calendarPrefix + appointment.calendarID,
            calendarName: info?.title ?? String(localized: "京ME"),
            calendarColor: color(from: info?.color),
            calendarItemID: nil,
            link: link(for: appointment.meeting)
                ?? MeetingLink.detect(fields: [appointment.location]),
            hasOnlineMeeting: appointment.meeting != nil || appointment.meetingLinked,
            joyDay: MeetingEvent.JoyDayRef(
                scheduleID: appointment.scheduleID,
                calendarID: appointment.calendarID,
                originalStart: appointment.originalStart))
    }

    /// The join URL JoyDay's own web client opens, with the native deep link preferred when one
    /// is a scheme macOS can hand straight to an app.
    static func link(from detail: JoyDayDetail) -> MeetingLink? { link(for: detail.meeting) }

    private static func link(for meeting: JoyDayMeeting?) -> MeetingLink? {
        guard let meeting else { return nil }
        let route = meeting.routeType?.lowercased()
        let isJDMeeting =
            route == "jdmemeeting" || route == "ddmeeting" || route == "joymeeting"
            || route == "dongdongmeeting"
        if let deepLink = meeting.deepLink, let scheme = deepLink.scheme?.lowercased(),
            scheme != "http", scheme != "https"
        {
            return MeetingLink(provider: .jdMeeting, url: deepLink, account: nil)
        }
        if let url = meeting.url {
            let detected = MeetingLink.detect(fields: [url.absoluteString])?.provider
            return MeetingLink(
                provider: isJDMeeting ? .jdMeeting : (detected ?? .generic), url: url,
                account: nil)
        }
        if let deepLink = meeting.deepLink {
            return MeetingLink(provider: .jdMeeting, url: deepLink, account: nil)
        }
        if isJDMeeting, let id = meeting.id, !id.isEmpty,
            let deepLink = joinDeepLink(meetingID: id, password: meeting.password)
        {
            return MeetingLink(provider: .jdMeeting, url: deepLink, account: nil)
        }
        return nil
    }

    // MARK: - Details

    /// JoyDay's detail payload in the shape every source's details page already renders.
    static func details(from detail: JoyDayDetail, meeting: MeetingEvent) -> MeetingDetails {
        var attendees: [MeetingDetails.Attendee] = []
        var seen = Set<String>()
        if let organizer = detail.organizer {
            seen.insert(key(for: organizer))
            attendees.append(
                MeetingDetails.Attendee(
                    name: organizer.name, response: .accepted, isOrganizer: true))
        }
        for participant in detail.participants {
            let key = key(for: participant.person)
            guard seen.insert(key).inserted else { continue }
            attendees.append(
                MeetingDetails.Attendee(
                    name: participant.person.name, response: response(to: participant.status),
                    isOrganizer: false))
        }
        return MeetingDetails(
            meetingID: meeting.id,
            location: detail.location,
            notes: detail.notes,
            attendees: attendees)
    }

    private static func key(for person: JoyDayPerson) -> String {
        person.email ?? person.userID ?? person.name
    }

    private static func response(to status: String?) -> MeetingDetails.Attendee.Response {
        switch status?.lowercased() {
        case "accept", "accepted": .accepted
        case "tentative", "maybe": .tentative
        case "reject", "rejected", "decline", "declined": .declined
        default: .pending
        }
    }

    private static func joinDeepLink(meetingID: String, password: String?) -> URL? {
        var params: [String: Any] = ["conferenceCode": meetingID]
        if let password, !password.isEmpty { params["password"] = password }
        guard let data = try? JSONSerialization.data(withJSONObject: params),
            let json = String(data: data, encoding: .utf8),
            let encoded = json.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return nil }
        return URL(string: "jdme://jm/biz/im/video/join?params=\(encoded)&paramType=1")
    }

    /// JoyDay stores colours as `ffRRGGBB`, with a leading alpha byte.
    private static func color(from hex: String?) -> MeetingEvent.CalendarColor? {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 8 { value = String(value.dropFirst(2)) }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        return MeetingEvent.CalendarColor(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255)
    }
}
