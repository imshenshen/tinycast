import AppKit
import EventKit

@MainActor
@Observable
final class CalendarStore {
    /// Flattened occurrences over `span`, newest query wins.
    private(set) var events: [MeetingEvent] = []
    private(set) var calendars: [MeetingCalendar] = []
    private(set) var access: CalendarAccess = Permissions.calendarAccess()
    /// The details page's meeting, re-read with every reload so an edit never shows stale.
    private(set) var details: MeetingDetails?
    /// Set before the fetch, so the page has a header while JoyDay's detail is in flight.
    private(set) var detailsMeeting: MeetingEvent?
    private(set) var detailsLoading = false
    private(set) var detailsError: String?
    /// JoyDay (京ME) is a second source: its own opt-in, session and refresh cadence.
    private(set) var joyDayStatus: JoyDayStatus = .off
    private(set) var joyDayEnabled: Bool

    /// Changing it re-reads: nothing may filter a snapshot into a span it never fetched.
    var span: MeetingSpan = .todayAndTomorrow {
        didSet {
            guard span != oldValue, lastReloadAt != nil else { return }
            reload()
        }
    }

    /// Fired whenever `events` changes, so the launcher's meeting slice is republished.
    @ObservationIgnored var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private let hiddenKey = "hiddenMeetingCalendars"
    private let joyDayKey = "joyDayCalendarEnabled"
    /// Exclusions, not inclusions, so a calendar added after this was written defaults to on.
    private var hiddenCalendarIDs: Set<String>

    /// Both sources publish through one array, so every surface keeps reading a single list.
    private var eventKitEvents: [MeetingEvent] = []
    private var eventKitCalendars: [MeetingCalendar] = []
    private var joyDayEvents: [MeetingEvent] = []
    private var joyDayMeetingCalendars: [MeetingCalendar] = []
    private var joyDaySourceCalendars: [JoyDayCalendar] = []
    private var joyDayFetchedAt: Date?
    /// The span the snapshot covers, so a span change refetches even inside the stale window.
    private var joyDayWindow: DateInterval?
    @ObservationIgnored private var joyDayTask: Task<Void, Never>?
    @ObservationIgnored private let joyDayClient = JoyDayClient()
    /// JoyDay's detail API is the only place a list row's link and notes live; both are per
    /// occurrence, so they are keyed by the synthetic event id and fetched once.
    @ObservationIgnored private var joyDayLinks: [MeetingEvent.ID: MeetingLink] = [:]
    @ObservationIgnored private var joyDayDetails: [MeetingEvent.ID: MeetingDetails] = [:]
    @ObservationIgnored private var detailsTask: Task<Void, Never>?

    /// Built on first use, so a Mac with the feature off never loads EventKit at launch.
    @ObservationIgnored private var eventStore: EKEventStore?
    @ObservationIgnored private var changeObserver: NotificationToken?
    @ObservationIgnored private var wakeObserver: NotificationToken?
    @ObservationIgnored private var lastReloadAt: Date?

    /// Covers the day rolling over and a Mac that slept; edits come from EventKit.
    private static let staleAfter: TimeInterval = 10 * 60
    /// JoyDay has no change notification, so it polls on a slower schedule of its own.
    private static let joyDayStaleAfter: TimeInterval = 5 * 60

    init() {
        hiddenCalendarIDs = Set(defaults.stringArray(forKey: hiddenKey) ?? [])
        joyDayEnabled = defaults.bool(forKey: joyDayKey)
    }

    /// TCC sends nothing when a grant changes in Settings, so anything acting on `access` re-reads.
    func refreshAccess() {
        access = Permissions.calendarAccess()
    }

    // MARK: - Lifecycle

    func start() {
        refreshAccess()
        observeWake()
        // Deferred: the first EventKit query pays for its XPC warm-up, and launch protects itself.
        Task { reload() }
        refreshJoyDayIfNeeded(force: true)
    }

    func stop() {
        changeObserver = nil
        wakeObserver = nil
        eventStore = nil
        lastReloadAt = nil
        joyDayTask?.cancel()
        joyDayTask = nil
        detailsTask?.cancel()
        detailsTask = nil

        joyDayFetchedAt = nil
        joyDayWindow = nil
        joyDayEvents = []
        joyDaySourceCalendars = []
        joyDayMeetingCalendars = []
        joyDayStatus = .off
        joyDayLinks = [:]
        joyDayDetails = [:]
        eventKitEvents = []
        eventKitCalendars = []
        details = nil
        detailsMeeting = nil
        detailsLoading = false
        detailsError = nil
        publish([])
        calendars = []
    }

    /// Tinycast's own consent dialog has already been accepted by the time this runs.
    func requestAccess() async -> Bool {
        let granted = await Permissions.requestCalendarAccess()
        refreshAccess()
        guard granted else { return false }
        // A store built before the grant never sees the new calendars; drop it and rebuild.
        changeObserver = nil
        eventStore = nil
        reload()
        return true
    }

    /// EventKit says when to reload; the palette adds one refresh per summon.
    private func observeStoreChanges() {
        guard changeObserver == nil, let eventStore else { return }
        let center = NotificationCenter.default
        let token = center.addObserver(
            forName: .EKEventStoreChanged, object: eventStore, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        changeObserver = NotificationToken(token, center: center)
    }

    /// A Mac asleep through a meeting wakes with a stale snapshot and no edit to trigger a reload.
    private func observeWake() {
        guard wakeObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        wakeObserver = NotificationToken(token, center: center)
    }

    // MARK: - Reading

    /// The per-minute refresh: cheap when the snapshot still holds, which is almost always.
    func reloadIfStale(now: Date) {
        guard let lastReloadAt else {
            reload()
            return
        }
        let aged = now.timeIntervalSince(lastReloadAt) >= Self.staleAfter
        // A day boundary invalidates the span itself, however fresh the snapshot is.
        let rolled = !Calendar.current.isDate(lastReloadAt, inSameDayAs: now)
        guard aged || rolled else { return }
        reload()
    }

    /// `EKEventStore` is not `Sendable`, so this stays on main; only pure values leave.
    func reload() {
        defer { refreshDetails() }
        refreshAccess()
        guard access == .granted else {
            eventKitEvents = []
            eventKitCalendars = []
            rebuildCalendars()
            publishMerged()
            refreshJoyDayIfNeeded()
            return
        }
        let store = eventStore ?? EKEventStore()
        eventStore = store
        observeStoreChanges()
        lastReloadAt = Date()

        let sources = store.calendars(for: .event)
        eventKitCalendars =
            sources
            .map {
                MeetingCalendar(
                    id: $0.calendarIdentifier, title: $0.title, accountName: $0.source.title)
            }
        rebuildCalendars()

        let selected = sources.filter { !hiddenCalendarIDs.contains($0.calendarIdentifier) }
        guard !selected.isEmpty,
            let interval = span.interval(from: Date(), calendar: .current)
        else {
            eventKitEvents = []
            publishMerged()
            refreshJoyDayIfNeeded()
            return
        }
        // The predicate expands recurrence itself; rolling our own never works.
        let predicate = store.predicateForEvents(
            withStart: interval.start, end: interval.end, calendars: selected)
        eventKitEvents = store.events(matching: predicate).compactMap(Self.meeting(from:))
        publishMerged()
        refreshJoyDayIfNeeded()
    }

    private func publishMerged() {
        // JoyDay's rows are filtered here rather than at fetch, so a toggle is instant. The span
        // filter keeps a snapshot from the previous span out until the refetch lands.
        let window = span.interval(from: Date(), calendar: .current)
        let joyDay = joyDayEvents.filter { event in
            guard !hiddenCalendarIDs.contains(event.calendarID) else { return false }
            guard let window else { return true }
            return event.end > window.start && event.start < window.end
        }
        publish((eventKitEvents + joyDay).sorted { $0.start < $1.start })
    }

    private func rebuildCalendars() {
        calendars = (eventKitCalendars + joyDayMeetingCalendars).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func publish(_ next: [MeetingEvent]) {
        guard next != events else { return }
        events = next
        onChange?()
    }

    private static func meeting(from event: EKEvent) -> MeetingEvent? {
        // A cancelled event is not happening, so it never reaches a surface.
        guard event.status != .canceled, let start = event.startDate, let end = event.endDate,
            let calendar = event.calendar
        else { return nil }
        let me = event.attendees?.first { $0.isCurrentUser }
        return MeetingEvent(
            id: occurrenceID(of: event, start: start),
            source: .eventKit,
            title: event.title ?? String(localized: "(No Title)"),
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            isDeclined: me?.participantStatus == .declined,
            calendarID: calendar.calendarIdentifier,
            calendarName: calendar.title,
            calendarColor: color(of: calendar),
            calendarItemID: event.calendarItemIdentifier,
            link: MeetingLink.detect(
                fields: [event.url?.absoluteString, event.location, event.notes],
                account: accountEmail(of: me ?? event.organizer)),
            hasOnlineMeeting: false,
            joyDay: nil)
    }

    private static func occurrenceID(of event: EKEvent, start: Date) -> MeetingEvent.ID {
        (event.eventIdentifier ?? event.calendarItemIdentifier)
            + "|\(start.timeIntervalSinceReferenceDate)"
    }

    private static func color(of calendar: EKCalendar) -> MeetingEvent.CalendarColor? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let components = calendar.cgColor?.converted(
                to: space, intent: .defaultIntent, options: nil)?.components,
            components.count >= 3
        else { return nil }
        return MeetingEvent.CalendarColor(
            red: components[0], green: components[1], blue: components[2])
    }

    /// The organizer covers an event booked with no guests and so no attendee list.
    private static func accountEmail(of participant: EKParticipant?) -> String? {
        guard let participant else { return nil }
        return MeetingLink.accountAddress(
            of: participant.url, isCurrentUser: participant.isCurrentUser)
    }

    func event(id: String) -> MeetingEvent? {
        events.first { $0.id == id }
    }

    // MARK: - Details

    func loadDetails(of meeting: MeetingEvent) {
        detailsMeeting = meeting
        switch meeting.source {
        case .eventKit:
            detailsTask?.cancel()
            detailsTask = nil
            detailsLoading = false
            detailsError = nil
            let next = fetchDetails(of: meeting)
            if next != details { details = next }
        case .joyDay:
            loadJoyDayDetails(of: meeting)
        }
    }

    /// JoyDay sends details from the page's own session; the list snapshot never carries them.
    private func loadJoyDayDetails(of meeting: MeetingEvent) {
        detailsTask?.cancel()
        detailsTask = nil
        if let cached = joyDayDetails[meeting.id] {
            detailsLoading = false
            detailsError = nil
            if cached != details { details = cached }
            return
        }
        details = nil
        detailsError = nil
        guard let reference = meeting.joyDay else {
            detailsLoading = false
            return
        }
        detailsLoading = true
        detailsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let detail = try await joyDayClient.detail(
                    scheduleID: reference.scheduleID, calendarID: reference.calendarID,
                    start: meeting.start, end: meeting.end,
                    originalStart: reference.originalStart)
                guard !Task.isCancelled, detailsMeeting?.id == meeting.id else { return }
                let mapped = JoyDayEvents.details(from: detail, meeting: meeting)
                joyDayDetails[meeting.id] = mapped
                if let link = JoyDayEvents.link(from: detail) {
                    joyDayLinks[meeting.id] = link
                }
                details = mapped
                detailsLoading = false
            } catch {
                guard !Task.isCancelled, detailsMeeting?.id == meeting.id else { return }
                detailsLoading = false
                detailsError = error.localizedDescription
            }
        }
    }

    /// The link a JoyDay row promises but does not carry; EventKit rows already have theirs.
    func resolveLink(for meeting: MeetingEvent) async throws -> MeetingLink? {
        if let link = meeting.link { return link }
        guard meeting.source == .joyDay, meeting.hasOnlineMeeting, let reference = meeting.joyDay
        else { return nil }
        if let cached = joyDayLinks[meeting.id] { return cached }
        let detail = try await joyDayClient.detail(
            scheduleID: reference.scheduleID, calendarID: reference.calendarID,
            start: meeting.start, end: meeting.end, originalStart: reference.originalStart)
        guard let link = JoyDayEvents.link(from: detail) else { return nil }
        joyDayLinks[meeting.id] = link
        return link
    }

    func clearDetails() {
        detailsTask?.cancel()
        detailsTask = nil
        if details != nil { details = nil }
        if detailsMeeting != nil { detailsMeeting = nil }
        if detailsLoading { detailsLoading = false }
        if detailsError != nil { detailsError = nil }
    }

    private func refreshDetails() {
        guard let shown = details?.meetingID, let meeting = event(id: shown),
            meeting.source == .eventKit
        else { return }
        let next = fetchDetails(of: meeting)
        if next != details { details = next }
    }

    /// Only this occurrence's window is queried, so an open page costs one tiny fetch per reload.
    private func fetchDetails(of meeting: MeetingEvent) -> MeetingDetails? {
        guard let eventStore, let calendar = eventStore.calendar(withIdentifier: meeting.calendarID)
        else { return nil }
        // Padded, or a zero-length event would fall outside its own window.
        let predicate = eventStore.predicateForEvents(
            withStart: meeting.start, end: meeting.end.addingTimeInterval(1), calendars: [calendar])
        let match = eventStore.events(matching: predicate).first { event in
            event.startDate.map { Self.occurrenceID(of: event, start: $0) } == meeting.id
        }
        guard let match else { return nil }
        return MeetingDetails(
            meetingID: meeting.id, location: match.location, notes: match.notes,
            attendees: Self.attendees(of: match))
    }

    private static func attendees(of event: EKEvent) -> [MeetingDetails.Attendee] {
        let organizer = event.organizer?.url
        return (event.attendees ?? []).compactMap { participant in
            guard let name = participant.name ?? MeetingLink.address(of: participant.url) else {
                return nil
            }
            return MeetingDetails.Attendee(
                name: name, response: response(to: participant.participantStatus),
                isOrganizer: participant.url == organizer)
        }
    }

    private static func response(
        to status: EKParticipantStatus
    ) -> MeetingDetails.Attendee.Response {
        switch status {
        case .accepted: .accepted
        case .tentative: .tentative
        case .declined: .declined
        default: .pending
        }
    }

    /// False means there is no such calendar, which is a report, not a silent no-op.
    func createEvent(_ draft: EventDraft, now: Date) -> Bool {
        let store = eventStore ?? EKEventStore()
        eventStore = store
        guard access == .granted, let calendar = store.defaultCalendarForNewEvents else {
            return false
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.trimmedTitle
        event.startDate = draft.start(from: now)
        event.endDate = draft.end(from: now)
        guard (try? store.save(event, span: .thisEvent, commit: true)) != nil else { return false }
        reload()
        return true
    }

    // MARK: - Per-calendar switches

    func isEnabled(_ calendar: MeetingCalendar) -> Bool {
        !hiddenCalendarIDs.contains(calendar.id)
    }

    func setEnabled(_ enabled: Bool, for calendar: MeetingCalendar) {
        if enabled {
            hiddenCalendarIDs.remove(calendar.id)
        } else {
            hiddenCalendarIDs.insert(calendar.id)
        }
        defaults.set(Array(hiddenCalendarIDs), forKey: hiddenKey)
        reload()
    }

    // MARK: - JoyDay

    /// Consent to read 京ME's calendar is the switch itself, so it is written immediately.
    func setJoyDayEnabled(_ enabled: Bool) {
        guard enabled != joyDayEnabled else { return }
        joyDayEnabled = enabled
        defaults.set(enabled, forKey: joyDayKey)
        guard !enabled else {
            refreshJoyDayIfNeeded(force: true)
            return
        }
        joyDayTask?.cancel()
        joyDayTask = nil
        joyDayFetchedAt = nil
        joyDayWindow = nil
        joyDayEvents = []
        joyDaySourceCalendars = []
        joyDayMeetingCalendars = []
        joyDayStatus = .off
        joyDayLinks = [:]
        joyDayDetails = [:]
        if detailsMeeting?.source == .joyDay { clearDetails() }
        rebuildCalendars()
        publishMerged()
    }

    func refreshJoyDay() {
        refreshJoyDayIfNeeded(force: true)
    }

    /// Brings JoyDay up in 京ME, then tries the read again once its page has had time to boot.
    func openJoyDayInMe() {
        Task {
            do {
                try await JoyDayBridge.openCalendar()
            } catch {
                joyDayStatus = .needsAttention(error.localizedDescription)
                return
            }
            try? await Task.sleep(for: .seconds(4))
            refreshJoyDayIfNeeded(force: true)
        }
    }

    private func refreshJoyDayIfNeeded(force: Bool = false) {
        guard joyDayEnabled, joyDayTask == nil else { return }
        guard let interval = span.interval(from: Date(), calendar: .current) else { return }
        if !force, joyDayWindow == interval, let joyDayFetchedAt,
            Date().timeIntervalSince(joyDayFetchedAt) < Self.joyDayStaleAfter
        {
            return
        }
        joyDayTask = Task {
            await fetchJoyDay(in: interval)
            joyDayTask = nil
            // The span may have changed mid-fetch; the snapshot covers the old one.
            if case .ready = joyDayStatus,
                joyDayWindow != span.interval(from: Date(), calendar: .current)
            {
                refreshJoyDayIfNeeded(force: true)
            }
        }
    }

    private func fetchJoyDay(in interval: DateInterval) async {
        if joyDayStatus != .connecting { joyDayStatus = .connecting }
        do {
            if joyDaySourceCalendars.isEmpty {
                let fetched = try await joyDayClient.calendars()
                guard joyDayEnabled, !Task.isCancelled else { return }
                joyDaySourceCalendars = fetched.filter { $0.type != 4 }
                joyDayMeetingCalendars = joyDaySourceCalendars.map {
                    MeetingCalendar(
                        id: JoyDayEvents.calendarPrefix + $0.id, title: $0.title,
                        accountName: String(localized: "京ME"))
                }
                rebuildCalendars()
            }

            guard !joyDaySourceCalendars.isEmpty else {
                joyDayEvents = []
                joyDayFetchedAt = Date()
                joyDayWindow = interval
                joyDayStatus = .ready(Date())
                publishMerged()
                return
            }

            let appointments = try await joyDayClient.appointments(
                from: interval.start, to: interval.end,
                calendarIDs: joyDaySourceCalendars.map(\.id))
            guard joyDayEnabled, !Task.isCancelled else { return }
            joyDayEvents = JoyDayEvents.meetingEvents(
                appointments: appointments, calendars: joyDaySourceCalendars, window: interval)
            joyDayFetchedAt = Date()
            joyDayWindow = interval
            joyDayStatus = .ready(Date())
            publishMerged()
        } catch {
            // Every call reads the session fresh, so an expired login simply needs a new sign-in.
            guard !Task.isCancelled else { return }
            joyDayStatus = .needsAttention(error.localizedDescription)
        }
    }
}
