import SwiftUI

/// One meeting's page. ↵, ⌘↵, ⌘O and ⌘K act on it exactly as on its schedule row.
struct MeetingDetailsScreen: PaletteScreen {
    let store: CalendarStore
    let core: AppCore

    /// The row that opened the page. JoyDay's details arrive after the push, so this one leads
    /// it, re-read from the latest list while that list still has the occurrence.
    private var meeting: MeetingEvent? {
        guard let shown = store.detailsMeeting else { return nil }
        return store.event(id: shown.id) ?? shown
    }

    var rows: [MeetingEvent] { meeting.map { [$0] } ?? [] }

    var primaryActionTitle: String {
        guard let meeting else { return String(localized: "Open in Calendar") }
        return MeetingActionsMenu.detailsPrimaryTitle(for: meeting)
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        meeting.map { MeetingActionsMenu.content(meeting: $0, core: core, offersDetails: false) }
    }

    func activate(at selection: Int) {
        guard let meeting else { return }
        core.calendarCoordinator.join(meeting)
    }

    func secondary(at selection: Int) -> Bool {
        guard let meeting else { return false }
        return MeetingActionsMenu.secondary(meeting: meeting, core: core)
    }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        guard let meeting else { return false }
        return MeetingActionsMenu.perform(shortcut, meeting: meeting, core: core, offersDetails: false)
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        guard let meeting else {
            return AnyView(EmptyResults(text: String(localized: "This meeting is no longer available")))
        }
        if let details = store.details, details.meetingID == meeting.id {
            return AnyView(MeetingDetailsView(meeting: meeting, details: details))
        }
        return AnyView(
            MeetingDetailsStatus(
                meeting: meeting, error: store.detailsError, isLoading: store.detailsLoading))
    }
}

/// The page before its details land, or instead of them: the head stays, the body says why.
private struct MeetingDetailsStatus: View {
    @Environment(\.metrics) private var metrics
    let meeting: MeetingEvent
    let error: String?
    let isLoading: Bool

    private var message: String {
        if let error { return error }
        if isLoading { return String(localized: "Loading details…") }
        return String(localized: "This meeting is no longer available")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.md) {
            MeetingDetailsHeader(meeting: meeting)
            HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.sm) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(message)
                    .font(metrics.typography.rowTitle)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .textSelection(.enabled)
            }
            .padding(.top, metrics.spacing.xl)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, metrics.spacing.xxl)
        .padding(.top, metrics.spacing.md)
        .padding(.bottom, metrics.spacing.xxl)
        .id(meeting.id)
    }
}
