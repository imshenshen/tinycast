import SwiftUI

struct MeetingCard: View {
    @Environment(\.metrics) private var metrics
    let meeting: MeetingEvent
    let now: Date
    let selected: Bool

    var body: some View {
        HStack(spacing: metrics.spacing.xl) {
            SymbolImage(
                name: meeting.meetingProvider?.sfSymbol ?? "calendar",
                size: metrics.size.headerIconSlot
            )
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: metrics.spacing.xs) {
                Text(meeting.title)
                    .font(metrics.typography.calcResult.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: metrics.spacing.sm) {
                    if let tint = meeting.calendarColor { ColorDot(color: tint.color) }
                    Text(subtitle)
                        .font(metrics.typography.rowTrailing)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: metrics.spacing.md)
            Text(UpcomingWindow.countdown(to: meeting.start, now: now, locale: .current))
                .font(metrics.typography.rowTitle.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, metrics.spacing.md)
                .padding(.vertical, metrics.spacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: metrics.radius.keyCap, style: .continuous)
                        .fill(Theme.Colors.controlSurface)
                )
        }
        .padding(.horizontal, metrics.spacing.xl)
        .padding(.vertical, metrics.spacing.xxl)
        .leadCard(selected: selected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(meeting.title), \(subtitle), "
                + UpcomingWindow.countdown(to: meeting.start, now: now, locale: .current)
        )
        .accessibilityAddTraits(.isButton)
    }

    private var subtitle: String {
        let time = MeetingTimeFormat.range(of: meeting)
        guard let provider = meeting.meetingProvider else { return time }
        return "\(time) · \(provider.title)"
    }
}

/// The one place a meeting time becomes text, so the card and the schedule rows never diverge.
@MainActor
enum MeetingTimeFormat {
    private static let formatter: Date.FormatStyle = .dateTime.hour().minute()

    static func clock(_ date: Date) -> String { date.formatted(formatter) }

    /// Two clocks rather than the interval style, which drops a shared AM/PM and dates midnight.
    static func range(of meeting: MeetingEvent) -> String {
        "\(clock(meeting.start)) – \(clock(meeting.end))"
    }
}

extension MeetingEvent.CalendarColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

/// Actions for a meeting, shared by the card, every launcher and schedule row and the details page.
@MainActor
enum MeetingActionsMenu {
    static func content(
        meeting: MeetingEvent, core: AppCore, offersDetails: Bool = true
    ) -> PopoverMenuContent {
        var items: [PopoverMenuItem] = []
        // A JoyDay row names its online meeting before its link is fetched, so both count.
        let canJoin = meeting.canJoinMeeting
        if canJoin {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Join Meeting"), systemImage: "video.fill", shortcut: "↵"
                ) {
                    core.calendarCoordinator.join(meeting)
                })
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Copy Meeting Link"), systemImage: "link", shortcut: "⌘↵"
                ) {
                    core.calendarCoordinator.copyLink(meeting)
                })
        }
        items.append(
            PopoverMenuItem(
                title: meeting.source == .joyDay
                    ? String(localized: "Open in 京ME") : String(localized: "Open in Calendar"),
                systemImage: "calendar", startsSection: true,
                shortcut: !canJoin && meeting.source == .eventKit ? "↵" : "⌘O"
            ) {
                core.calendarCoordinator.openInCalendar(meeting)
            })
        if offersDetails {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Show Details"), systemImage: "info.circle",
                    shortcut: !canJoin && meeting.source == .joyDay ? "↵" : "⌘I"
                ) {
                    core.calendarCoordinator.showDetails(of: meeting)
                })
        }
        return PopoverMenuContent(header: meeting.title, items: items)
    }

    /// The pill over a row, naming what ↵ there does: join, or open the one page that has it.
    static func primaryTitle(for meeting: MeetingEvent) -> String {
        if meeting.canJoinMeeting { return String(localized: "Join Meeting") }
        return meeting.source == .joyDay
            ? String(localized: "Show Details") : String(localized: "Open in Calendar")
    }

    /// The details page's pill: ↵ there joins, or hands the occurrence to the page that owns it.
    static func detailsPrimaryTitle(for meeting: MeetingEvent) -> String {
        if meeting.canJoinMeeting { return String(localized: "Join Meeting") }
        return meeting.source == .joyDay
            ? String(localized: "Open in 京ME") : String(localized: "Open in Calendar")
    }

    /// ⌘↵ — false for a meeting with no link, leaving the key unhandled.
    static func secondary(meeting: MeetingEvent, core: AppCore) -> Bool {
        guard meeting.canJoinMeeting else { return false }
        core.calendarCoordinator.copyLink(meeting)
        return true
    }

    static func perform(
        _ shortcut: PaletteShortcut, meeting: MeetingEvent, core: AppCore, offersDetails: Bool = true
    ) -> Bool {
        switch shortcut {
        case .openInApp:
            core.calendarCoordinator.openInCalendar(meeting)
        case .showDetails where offersDetails:
            core.calendarCoordinator.showDetails(of: meeting)
        default:
            return false
        }
        return true
    }
}
