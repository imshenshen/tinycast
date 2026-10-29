import SwiftUI

struct CalendarSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @Environment(CalendarStore.self) private var store

    var body: some View {
        @Bindable var settings = settings
        Form {
            FeatureSwitchSection(
                anchor: .calendarCalendar,
                enableTitle: "Join meetings from Tinycast",
                enableSubtitle: enableSubtitle,
                isEnabled: enabledBinding,
                showsInLauncher: $settings.calendarShowInLauncher,
                showsIcon: true,
                showsHeader: false)

            Section {
                Picker(selection: $settings.calendarLauncherLimit) {
                    ForEach(CalendarLauncherLimit.allCases) { limit in
                        Text(limit.title).tag(limit)
                    }
                } label: {
                    SettingsRowTitle(.calendarCalendar, "Upcoming meetings in launcher")
                }
            }
            .settingsEnabled(settings.calendarEnabled && settings.calendarShowInLauncher)

            if settings.calendarEnabled, store.access == .notDetermined {
                Section {
                    SettingsRow(
                        title: String(localized: "Calendar access is needed"),
                        subtitle: String(localized: "Needed to read events and find join links.")
                    ) {
                        Button("Allow Calendar Access…") {
                            core.calendarCoordinator.setCalendarEnabled(true)
                        }
                    }
                }
            } else if store.access == .denied {
                Section {
                    SettingsRow(
                        title: String(localized: "Calendar access is off"),
                        subtitle: String(localized: "Allow it in Privacy & Security ▸ Calendars.")
                    ) {
                        Button("Open System Settings…") { Permissions.openCalendarSettings() }
                    }
                }
            }

            Section {
                Picker(selection: $settings.joinWindowMinutes) {
                    ForEach(JoinWindow.allCases) { window in
                        Text(window.title).tag(window)
                    }
                } label: {
                    SettingsRowTitle(.calendarJoining, "Show the meeting card")
                    Text("Before and after a meeting starts.")
                }
                Toggle(isOn: $settings.autoJoinMeetings) {
                    SettingsRowTitle(.calendarJoining, "Auto Join Meetings")
                    Text("As they start.")
                }
                Toggle(isOn: $settings.autoJoinNamedProvidersOnly) {
                    SettingsRowTitle(.calendarJoining, "Only join known meeting services")
                }
                .toggleStyle(.checkbox)
                .settingsEnabled(settings.autoJoinMeetings)
                Toggle(isOn: $settings.autoJoinConfirms) {
                    SettingsRowTitle(.calendarJoining, "Confirm before joining")
                }
                .toggleStyle(.checkbox)
                .settingsEnabled(settings.autoJoinMeetings)
                Toggle(isOn: $settings.cameraPreview) {
                    SettingsRowTitle(.calendarJoining, "Camera Preview")
                    Text("Before joining a meeting.")
                }
                MeetingBrowserPicker(selection: $settings.meetingBrowserBundleID)
            } header: {
                SettingsSectionHeader(.calendarJoining)
            }
            .settingsEnabled(settings.calendarEnabled)

            Section {
                Picker(selection: $settings.calendarMenuBarDisplay) {
                    ForEach(CalendarMenuBarDisplay.allCases) { display in
                        Text(display.title).tag(display)
                    }
                } label: {
                    SettingsRowTitle(.calendarMenuBar, "Calendar in Menu Bar")
                    Text("Separate from the Tinycast icon.")
                }
                Picker(selection: $settings.calendarSpan) {
                    ForEach(MeetingSpan.allCases) { span in
                        Text(span.title).tag(span)
                    }
                } label: {
                    SettingsRowTitle(.calendarMenuBar, "Days to Show")
                    Text("In the menu, My Schedule and launcher search.")
                }
                Picker(selection: $settings.menuBarEvents) {
                    ForEach(MenuBarEvents.allCases) { lead in
                        Text(lead.title).tag(lead)
                    }
                } label: {
                    SettingsRowTitle(.calendarMenuBar, "Show Upcoming Events")
                    Text("When the next event appears.")
                }
                .settingsEnabled(settings.calendarMenuBarDisplay != .disabled)
                Toggle(isOn: $settings.menuBarLinkedEventsOnly) {
                    SettingsRowTitle(.calendarMenuBar, "Only show events with meetings")
                }
                .toggleStyle(.checkbox)
                .settingsEnabled(settings.calendarMenuBarDisplay != .disabled)
                Toggle(isOn: $settings.calendarMenuBarHidesWhenEmpty) {
                    SettingsRowTitle(.calendarMenuBar, "Hide when there are no upcoming events")
                }
                .toggleStyle(.checkbox)
                .settingsEnabled(settings.calendarMenuBarDisplay != .disabled)
                Picker(selection: $settings.hideCurrentEvent) {
                    ForEach(HideCurrentEvent.allCases) { hide in
                        Text(hide.title).tag(hide)
                    }
                } label: {
                    SettingsRowTitle(.calendarMenuBar, "Hide Current Event")
                    Text("Once it has started.")
                }
                .settingsEnabled(settings.calendarMenuBarDisplay != .disabled)
            } header: {
                SettingsSectionHeader(.calendarMenuBar)
            }
            .settingsEnabled(settings.calendarEnabled)

            FeatureCommandsSection(owner: .calendar, anchor: .calendarCommands)
                .settingsEnabled(settings.calendarEnabled)

            JoyDaySection()
                .settingsEnabled(settings.calendarEnabled)

            CalendarPickerSection()
                .settingsEnabled(settings.calendarEnabled)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.calendar)
        .releasesFocusOnOutsideClick()
        // The snapshot reloads only while the feature runs, so a Settings grant lands here.
        .onAppear { store.refreshAccess() }
    }

    private var enableSubtitle: LocalizedStringResource {
        switch settings.calendarSpan {
        case .today:
            "Reads today's events for join links. Nothing leaves this Mac."
        case .todayAndTomorrow:
            "Reads today's and tomorrow's events for join links. Nothing leaves this Mac."
        case .nextSevenDays:
            "Reads the next 7 days' events for join links. Nothing leaves this Mac."
        }
    }

    /// Routed through the coordinator so enabling, which is also consent, confirms first.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.calendarEnabled },
            set: { core.calendarCoordinator.setCalendarEnabled($0) }
        )
    }
}

private struct MeetingBrowserPicker: View {
    @Binding var selection: String?
    @State private var browsers: [MeetingLauncher.Browser] = []

    var body: some View {
        Picker(selection: installedSelection) {
            Text("Default Browser").tag(String?.none)
            Divider()
            ForEach(browsers) { browser in
                Text(browser.name).tag(Optional(browser.id))
            }
        } label: {
            SettingsRowTitle(.calendarJoining, "Open Meeting Links In")
            Text("When no meeting app handles the link.")
        }
        .onAppear { browsers = MeetingLauncher.installedBrowsers() }
    }

    /// A browser since removed reads as the default, which is what joining falls back to.
    private var installedSelection: Binding<String?> {
        Binding(
            get: { browsers.contains { $0.id == selection } ? selection : nil },
            set: { selection = $0 }
        )
    }
}

/// 京ME's JoyDay calendar, merged alongside EventKit's.
///
/// JoyDay has no API key: its web client signs every request, and the only session available lives
/// in the tab 京ME already has open. Enabling this lets Tinycast read that session and fetch the
/// same events the JoyDay page shows.
private struct JoyDaySection: View {
    @Environment(CalendarStore.self) private var store

    var body: some View {
        Section {
            Toggle(isOn: enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("京ME Calendar").fontWeight(.semibold)
                    Text("Merges JoyDay events from 京ME with Apple Calendar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if store.joyDayEnabled {
                SettingsRow(title: statusTitle, subtitle: statusSubtitle) {
                    HStack(spacing: Theme.Spacing.lg) {
                        Button("Refresh") { store.refreshJoyDay() }
                        Button("Open in 京ME") { store.openJoyDayInMe() }
                    }
                }
                Text(
                    """
                    Uses the JoyDay tab open in 京ME. 京ME must allow JavaScript from Apple \
                    Events (browser.allow_javascript_apple_events in its Chromium profile), \
                    and Tinycast needs Automation access to 京ME.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("京ME")
        }
    }

    private var enabled: Binding<Bool> {
        Binding(get: { store.joyDayEnabled }, set: { store.setJoyDayEnabled($0) })
    }

    private var statusTitle: String {
        switch store.joyDayStatus {
        case .off: return String(localized: "Off")
        case .connecting: return String(localized: "Reading JoyDay…")
        case .ready(let date):
            let time = date.formatted(date: .omitted, time: .shortened)
            return String(localized: "Updated \(time)")
        case .needsAttention(let message): return message
        }
    }

    private var statusSubtitle: String? {
        switch store.joyDayStatus {
        case .ready: return String(localized: "JoyDay refreshes every few minutes.")
        case .connecting: return nil
        case .off, .needsAttention: return String(localized: "Nothing leaves this Mac but the request to JoyDay.")
        }
    }
}

/// Machine-local by nature, so these live on the store and never travel in a backup.
private struct CalendarPickerSection: View {
    @Environment(CalendarStore.self) private var store
    @State private var query = ""

    private var calendars: [MeetingCalendar] {
        guard !query.isEmpty else { return store.calendars }
        return store.calendars.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.accountName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Section {
            SettingsFilterField(prompt: "Search calendars…", query: $query)

            if calendars.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(calendars) { calendar in
                    CalendarRow(calendar: calendar)
                }
            }
        } header: {
            SettingsSectionHeader(.calendarCalendars)
        }
    }

    private var emptyMessage: String {
        if !query.isEmpty { return String(localized: "No matches for “\(query)”.") }
        return store.access == .granted
            ? String(localized: "No calendars on this Mac.") : String(localized: "Nothing to show yet.")
    }
}

private struct CalendarRow: View {
    let calendar: MeetingCalendar
    @Environment(CalendarStore.self) private var store

    var body: some View {
        SettingsRow(title: calendar.title, subtitle: calendar.accountName) {
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel("Include \(calendar.title) in meetings")
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { store.isEnabled(calendar) },
            set: { store.setEnabled($0, for: calendar) }
        )
    }
}
