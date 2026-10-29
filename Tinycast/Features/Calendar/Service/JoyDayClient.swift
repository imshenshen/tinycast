import AppKit
import CryptoKit
import Foundation

/// Reads JoyDay's calendar out of the page 京ME already has open.
///
/// JoyDay's gateway wants the SSO cookie, which is httpOnly and cannot leave the browser. So the
/// signing happens here and the `fetch` happens inside the JoyDay tab: the page attaches its own
/// cookies, and only the response — never a credential — comes back over AppleScript.
enum JoyDayBridge {
    static let bundleID = "com.jd.TimLine"
    static let calendarAddress = "https://joyday.jd.com/calendar"

    enum BridgeError: LocalizedError {
        case notInstalled
        case noCalendarTab
        case javaScriptFromAppleEventsDisabled
        case automationDenied
        case notSignedIn
        case requestFailed(String)
        case timedOut
        /// 京ME answers tab queries but not JavaScript: its JoyDay tab is wedged.
        case meNotResponding

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                String(localized: "京ME is not installed.")
            case .noCalendarTab:
                String(localized: "Open JoyDay's calendar in 京ME first.")
            case .javaScriptFromAppleEventsDisabled:
                String(
                    localized:
                        "京ME has JavaScript from Apple Events turned off. Enable browser.allow_javascript_apple_events in its Chromium preferences, then reopen 京ME."
                )
            case .automationDenied:
                String(
                    localized:
                        "Allow Tinycast to control 京ME in System Settings ▸ Privacy & Security ▸ Automation."
                )
            case .notSignedIn:
                String(localized: "Sign in to JoyDay in 京ME first.")
            case .requestFailed(let message):
                message
            case .timedOut:
                String(localized: "JoyDay didn't answer in time.")
            case .meNotResponding:
                String(
                    localized:
                        "京ME stopped responding. Close the JoyDay tab in 京ME, open it again, then refresh."
                )
            }
        }
    }

    /// Runs a signed gateway call in the JoyDay tab and returns the raw response text.
    ///
    /// 京ME's session cookie rides along with the page's own credentials; the team header is read
    /// from the page's own cookie so neither value is ever handed to Tinycast. The call is
    /// synchronous inside the page, which lets one `execute` carry the answer back; a Promise
    /// would have to be polled and cannot be returned across AppleScript.
    static func post(url: URL, headers: [String: String], body: String) async throws -> String {
        let javaScript = """
            (function(){
              try {
                var headers = \(json(headers));
                var parts = document.cookie.split(";");
                for (var i = 0; i < parts.length; i++) {
                  var item = parts[i].trim();
                  if (item.indexOf("focus-team-id=") === 0) {
                    headers["x-team-id"] = decodeURIComponent(item.slice(14));
                    break;
                  }
                }
                var request = new XMLHttpRequest();
                request.open("POST", \(json(url.absoluteString)), false);
                request.withCredentials = true;
                for (var key in headers) request.setRequestHeader(key, headers[key]);
                request.send(\(json(body)));
                if (request.status >= 200 && request.status < 300) return request.responseText;
                return "ERR:HTTP " + request.status;
              } catch (error) {
                return "ERR:" + error;
              }
            })()
            """
        let result = try await run(script: script(for: javaScript))
        if result.hasPrefix("ERR:") {
            throw BridgeError.requestFailed(String(result.dropFirst(4)))
        }
        return result
    }

    /// Brings JoyDay up in 京ME, so the next request has a tab to run in.
    static func openCalendar() async throws {
        guard let url = URL(string: calendarAddress) else { return }
        try await open(url)
    }

    /// Brings the existing JoyDay tab forward, opening the calendar only when there is none.
    ///
    /// JoyDay's `mparam` route does nothing: its page ignores it and only the app's own drawer
    /// bus can open an event. Focusing the signed-in page is the honest "Open in 京ME".
    static func focusCalendar() async throws {
        let result = try await execute(source: focusScript)
        if result == "NO_TAB" { try await openCalendar() }
    }

    /// Opens a URL as a tab in 京ME, where JoyDay is already signed in.
    static func open(_ url: URL) async throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            throw BridgeError.notInstalled
        }
        let escaped = url.absoluteString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application id "\(bundleID)"
                activate
                open location "\(escaped)"
            end tell
            """
        _ = try await execute(source: script)
    }

    // MARK: - AppleScript

    /// The tab switch and the AppleScript session are stateful, so calls run one at a time.
    nonisolated(unsafe) private static let scriptLock = NSLock()

    private static func script(for javaScript: String) -> String {
        let escaped = escapeForAppleScript(javaScript)
        // The timeout bounds a wedged tab: without it one call parks for minutes with no reply.
        return """
            with timeout of 20 seconds
                tell application id "\(bundleID)"
                    set targetWindow to 0
                    repeat with wi from 1 to count of windows
                        set candidate to window wi
                        repeat with ti from 1 to count of tabs of candidate
                            if URL of tab ti of candidate starts with "https://joyday.jd.com" then
                                set targetWindow to wi
                                set targetTab to ti
                                exit repeat
                            end if
                        end repeat
                        if targetWindow is not 0 then exit repeat
                    end repeat
                    if targetWindow is 0 then return "NO_TAB"
                    set w to window targetWindow
                    set previousTab to active tab index of w
                    -- A background tab's renderer is usually frozen: try it on a short leash,
                    -- then bring the tab forward once and retry with the full timeout.
                    try
                        with timeout of 3 seconds
                            return execute tab targetTab of w javascript "\(escaped)"
                        end timeout
                    on error errMsg number errNum
                        if errNum is not -1712 then error errMsg number errNum
                    end try
                    if targetTab is not previousTab then
                        set active tab index of w to targetTab
                        delay 1
                    end if
                    try
                        set resultText to execute tab targetTab of w javascript "\(escaped)"
                    on error errMsg number errNum
                        if targetTab is not previousTab then set active tab index of w to previousTab
                        error errMsg number errNum
                    end try
                    if targetTab is not previousTab then set active tab index of w to previousTab
                    return resultText
                end tell
            end timeout
            """
    }

    /// Brings 京ME forward on the tab it already has signed in; opening the calendar is the fallback.
    private static let focusScript = """
        with timeout of 10 seconds
            tell application id "\(bundleID)"
                activate
                repeat with wi from 1 to count of windows
                    set w to window wi
                    repeat with ti from 1 to count of tabs of w
                        if URL of tab ti of w starts with "https://joyday.jd.com" then
                            set active tab index of w to ti
                            return "OK"
                        end if
                    end repeat
                end repeat
            end tell
        end timeout
        return "NO_TAB"
        """

    private static func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(script source: String) async throws -> String {
        let result = try await execute(source: source)
        if result == "NO_TAB" { throw BridgeError.noCalendarTab }
        return result
    }

    private static func execute(source: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            // NSAppleScript runs on whatever thread calls it; one at a time keeps its events
            // in order and off the actor.
            try scriptLock.withLock {
                guard let script = NSAppleScript(source: source) else {
                    throw BridgeError.requestFailed(
                        String(localized: "Tinycast couldn't build the 京ME script."))
                }
                var errorInfo: NSDictionary?
                let result = script.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    let number = errorInfo[NSAppleScript.errorNumber] as? Int
                    let message = errorInfo[NSAppleScript.errorMessage] as? String ?? ""
                    if number == -1743 { throw BridgeError.automationDenied }
                    // errAETimeout: the tab took the event but never answered, so it is wedged.
                    if number == -1712 { throw BridgeError.meNotResponding }
                    if message.localizedCaseInsensitiveContains("JavaScript") {
                        throw BridgeError.javaScriptFromAppleEventsDisabled
                    }
                    throw NSError(
                        domain: "JoyDayBridge", code: number ?? -1,
                        userInfo: [NSLocalizedDescriptionKey: message])
                }
                return result.stringValue ?? ""
            }
        }.value
    }

    /// A Swift string as a JavaScript string literal, quotes included.
    private static func json(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
            let array = String(data: data, encoding: .utf8), array.count >= 2
        else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    /// A header table as a JavaScript object literal.
    private static func json(_ dictionary: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dictionary, options: [.sortedKeys]),
            let object = String(data: data, encoding: .utf8)
        else { return "{}" }
        return object
    }
}

// MARK: - Models

/// How the JoyDay source is doing, for the Settings row.
enum JoyDayStatus: Equatable {
    case off
    case connecting
    case ready(Date)
    case needsAttention(String)
}

struct JoyDayCalendar: Sendable, Hashable {
    let id: String
    let title: String
    let color: String?
    /// JoyDay's CalendarType: 4 is a task list, not a calendar of meetings.
    let type: Int
    let isChecked: Bool
}

struct JoyDayMeeting: Sendable {
    let id: String?
    let url: URL?
    /// The server's own join URL, which knows which client should open the meeting.
    let deepLink: URL?
    let password: String?
    let routeType: String?
}

/// One row of `findAppointmentList`, kept close to the wire so recurrence stays inspectable.
struct JoyDayAppointment: Sendable {
    let scheduleID: String
    let calendarID: String
    let title: String
    let start: Date
    let end: Date
    let location: String?
    let meeting: JoyDayMeeting?
    /// JoyDay's flag (`joymeetingLinked`) that an online meeting is attached; the row itself
    /// never carries its details, which only `getAppointmentDetail` returns.
    let meetingLinked: Bool
    let isDeclined: Bool
    let isAllDay: Bool
    let isCancelled: Bool
    let isDeleted: Bool
    let appointmentType: String
    let repeatType: String?
    let rrule: String?
    let repeatStart: Date?
    let repeatEnd: Date?
    let originalStart: Date?
}

/// One person on a JoyDay event. The organizer's own `user` object carries the same shape.
struct JoyDayPerson: Sendable {
    let name: String
    let email: String?
    let userID: String?
}

struct JoyDayParticipant: Sendable {
    let person: JoyDayPerson
    let status: String?
}

/// `getAppointmentDetail`'s content: what a list row leaves out.
struct JoyDayDetail: Sendable {
    let subject: String?
    let notes: String?
    let location: String?
    let organizer: JoyDayPerson?
    let participants: [JoyDayParticipant]
    let meeting: JoyDayMeeting?
    let meetingLinked: Bool
}

// MARK: - Client

/// JoyDay's gateway signature needs the web client's app id and secret. They are not part of this
/// repository: put `{"webAppID": "…", "webSecret": "…"}` in `joyday-signing.json` next to the
/// settings file, then restart the app.
enum JoyDaySigning {
    struct Credentials: Sendable {
        let webAppID: String
        let webSecret: String
    }

    static var fileURL: URL {
        AppPaths.settingsFile()
            .deletingLastPathComponent()
            .appending(path: "joyday-signing.json", directoryHint: .notDirectory)
    }

    static func load() -> Credentials? {
        guard let data = try? Data(contentsOf: fileURL),
            let raw = try? JSONSerialization.jsonObject(with: data),
            let object = raw as? [String: String],
            let webAppID = object["webAppID"], !webAppID.isEmpty,
            let webSecret = object["webSecret"], !webSecret.isEmpty
        else { return nil }
        return Credentials(webAppID: webAppID, webSecret: webSecret)
    }
}

/// Signing and transport for JoyDay's gateway. Mirrors the web app's own request layer:
/// `x-sign` is the MD5 of `2&webAppId&secret&api&ts&nonce&WEB`, and the body is form-encoded.
@MainActor
struct JoyDayClient {
    private static let signing = JoyDaySigning.load()
    private static let appID = "JOYDAY_WEB"
    private static let appVersion = "6.48.0"
    private static let clientVersion = "8.10.0"
    private static let language = "zh_CN"
    private static let endpoint = URL(string: "https://api.m.jd.com/api")!

    enum ClientError: LocalizedError {
        case notSignedIn
        case signingNotConfigured
        case gateway(code: String, message: String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .notSignedIn: String(localized: "Sign in to JoyDay in 京ME first.")
            case .signingNotConfigured:
                "JoyDay signing is not configured. Add webAppID and webSecret to \(JoyDaySigning.fileURL.path)."
            case .gateway(_, let message): message
            case .malformedResponse: String(localized: "JoyDay returned an unexpected response.")
            }
        }
    }

    // MARK: Reading

    func calendars() async throws -> [JoyDayCalendar] {
        // Every type the web app asks for; task lists are filtered out by the caller.
        let content = try await call(
            "joyday.calendar.getCalendarList", body: ["types": [1, 2, 3, 4, 5, 6]])
        let list = content["calendarInfoList"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let id = Self.string(item["calendarId"]), !id.isEmpty else { return nil }
            let title = Self.string(item["title"]) ?? Self.string(item["name"])
            return JoyDayCalendar(
                id: id,
                title: title?.isEmpty == false ? title! : String(localized: "JoyDay"),
                color: Self.string(item["color"]),
                type: Self.int(item["type"]) ?? 0,
                isChecked: Self.int(item["checkedStatus"]) == 1)
        }
    }

    func appointments(
        from start: Date, to end: Date, calendarIDs: [String]
    ) async throws -> [JoyDayAppointment] {
        var body: [String: Any] = [
            "start": Int(start.timeIntervalSince1970 * 1000),
            "end": Int(end.timeIntervalSince1970 * 1000),
        ]
        // The web client joins the ids into one comma-separated string.
        if !calendarIDs.isEmpty { body["calendarIds"] = calendarIDs.joined(separator: ",") }
        let content = try await call("joyday.appt.findAppointmentList", body: body)
        let list = content["appointmentList"] as? [[String: Any]] ?? []
        return list.compactMap(Self.appointment(from:))
    }

    /// One occurrence's full record: description, participants and the meeting link a row lacks.
    ///
    /// `start`/`end` must be the occurrence's own times: a recurring series is keyed by them, and
    /// the wrong day returns a different instance's meeting info.
    func detail(
        scheduleID: String, calendarID: String, start: Date, end: Date, originalStart: Date? = nil
    ) async throws -> JoyDayDetail {
        var body: [String: Any] = [
            "scheduleId": scheduleID,
            "calendarId": calendarID,
            "start": Int(start.timeIntervalSince1970 * 1000),
            "end": Int(end.timeIntervalSince1970 * 1000),
        ]
        if let originalStart {
            body["originalStart"] = Int(originalStart.timeIntervalSince1970 * 1000)
        }
        let content = try await call("joyday.appt.getAppointmentDetail", body: body)
        let participants = (content["participants"] as? [[String: Any]] ?? []).compactMap {
            item -> JoyDayParticipant? in
            guard let person = Self.person(from: item["user"]) else { return nil }
            return JoyDayParticipant(person: person, status: Self.string(item["resStatus"]))
        }
        let organizer =
            Self.person(from: content["user"])
            ?? Self.string(content["organizer"]).map {
                JoyDayPerson(name: $0, email: $0, userID: Self.string(content["organizerUserId"]))
            }
        return JoyDayDetail(
            subject: Self.string(content["subject"]),
            notes: Self.string(content["description"]),
            location: Self.string(content["location"]),
            organizer: organizer,
            participants: participants,
            meeting: (content["meetingInfo"] as? [String: Any]).map(Self.meeting(from:)),
            meetingLinked: (Self.int(content["joymeetingLinked"]) ?? 0) > 0)
    }

    // MARK: Transport

    private func call(_ api: String, body: [String: Any]) async throws -> [String: Any] {
        guard let signing = Self.signing else { throw ClientError.signingNotConfigured }
        let now = Date()
        let milliseconds = Int(now.timeIntervalSince1970 * 1000)
        let nonce = String(milliseconds, radix: 36)
        let signSource =
            "2&\(signing.webAppID)&\(signing.webSecret)&\(api)&\(milliseconds)&\(nonce)&WEB"
        let signature = Insecure.MD5.hash(data: Data(signSource.utf8))
            .map { String(format: "%02x", $0) }.joined()

        var payload = body
        payload["jdmeAppId"] = "ee"
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"

        let form = [
            ("body", payloadJSON),
            ("functionId", api),
            ("appid", Self.appID),
            ("t", String(milliseconds)),
            ("loginType", "15"),
            ("uuid", "tinycast"),
            ("lang", Self.language),
            ("clientVersion", Self.clientVersion),
        ]
        .map { "\($0.0)=\(Self.formEscape($0.1))" }
        .joined(separator: "&")

        let headers: [String: String] = [
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "*/*",
            "x-api": api,
            "x-nonce": nonce,
            "x-ts": String(milliseconds),
            "x-gw-version": "2",
            "x-stage": "PROD",
            "x-app": signing.webAppID,
            "x-app-version": Self.appVersion,
            "x-language": Self.language,
            "x-client-version": "",
            "x-sign-headers": signSource,
            "x-sign": signature,
            "x-client": "web",
        ]

        let url = Self.endpoint.appending(queryItems: [
            URLQueryItem(name: "functionId", value: api)
        ])
        let text: String
        do {
            text = try await JoyDayBridge.post(url: url, headers: headers, body: form)
        } catch {
            Self.dump(error: error, api: api)
            throw error
        }
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ClientError.malformedResponse }

        let code = Self.string(object["errorCode"]) ?? Self.string(object["code"])
        if let code, code != "0", code != "200" {
            // 0002 is an expired session, 1003 an unknown user: both mean "sign in again".
            if code == "0002" || code == "1003" { throw ClientError.notSignedIn }
            throw ClientError.gateway(
                code: code,
                message: Self.string(object["errorMsg"]) ?? Self.string(object["echo"])
                    ?? String(localized: "JoyDay rejected the request."))
        }
        if let status = Self.string(object["status"]), status != "success" {
            throw ClientError.gateway(
                code: Self.string(object["errorCode"]) ?? status,
                message: Self.string(object["errorMsg"])
                    ?? String(localized: "JoyDay rejected the request."))
        }
        let content =
            (object["content"] as? [String: Any])
            ?? (object["data"] as? [String: Any]) ?? object
        Self.dump(content, api: api)
        return content
    }

    /// Opt-in sample dump (`TINYCAST_JOYDAY_DUMP=1`) so the parser can be checked against a real
    /// payload. Off by default: a launch never writes the calendar to disk.
    private static func dump(_ content: [String: Any], api: String) {
        guard ProcessInfo.processInfo.environment["TINYCAST_JOYDAY_DUMP"] != nil,
            let data = try? JSONSerialization.data(
                withJSONObject: content, options: [.prettyPrinted, .sortedKeys])
        else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Tinycast", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: "\(api).json"))
    }

    /// The failure counterpart of `dump`, so a broken bridge is diagnosable without the UI.
    private static func dump(error: Error, api: String) {
        guard ProcessInfo.processInfo.environment["TINYCAST_JOYDAY_DUMP"] != nil else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Tinycast", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = "\(Date())\n\(error.localizedDescription)\n"
        try? text.write(
            to: directory.appending(path: "\(api).error.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Parsing

    private static func appointment(from item: [String: Any]) -> JoyDayAppointment? {
        guard let scheduleID = string(item["scheduleId"]), !scheduleID.isEmpty,
            let start = milliseconds(item["start"]),
            let end = milliseconds(item["end"])
        else { return nil }
        let calendarID = string(item["calendarId"]) ?? string(item["calendarGroupId"]) ?? ""

        return JoyDayAppointment(
            scheduleID: scheduleID,
            calendarID: calendarID,
            title: string(item["subject"]) ?? String(localized: "(No Title)"),
            start: start,
            end: end,
            location: string(item["location"]),
            meeting: (item["meetingInfo"] as? [String: Any]).map(Self.meeting(from:)),
            meetingLinked: (int(item["joymeetingLinked"]) ?? 0) > 0,
            isDeclined: string(item["responseType"]) == "Reject"
                || int(item["responseType"]) == 2,
            isAllDay: int(item["allDayEvent"]).map { $0 == 1 }
                ?? isAllDay(start: start, end: end),
            isCancelled: int(item["cancelled"]) == 1,
            isDeleted: int(item["deleted"]) == 1,
            appointmentType: string(item["appointmentType"]) ?? "Single",
            repeatType: string(item["repeatType"]),
            rrule: string(item["rrule"]),
            repeatStart: milliseconds(item["repeatStart"]),
            repeatEnd: milliseconds(item["repeatEnd"]),
            originalStart: milliseconds(item["originalStart"]))
    }

    /// `deepLink` arrives as a JSON *string* holding `{"desktopUrl": "…"}`, not as a URL.
    private static func meeting(from item: [String: Any]) -> JoyDayMeeting {
        JoyDayMeeting(
            id: string(item["meetingId"]),
            url: string(item["meetingurl"]).flatMap(URL.init(string:)),
            deepLink: deepLinkURL(from: item["deepLink"]),
            password: string(item["password"]),
            routeType: string(item["routeType"]))
    }

    private static func deepLinkURL(from value: Any?) -> URL? {
        guard let raw = string(value) else { return nil }
        if let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            for key in ["desktopUrl", "webUrl", "url", "mobileDeeplink"] {
                if let url = string(object[key]).flatMap(URL.init(string:)) { return url }
            }
        }
        return URL(string: raw)
    }

    private static func person(from value: Any?) -> JoyDayPerson? {
        guard let item = value as? [String: Any] else { return nil }
        guard
            let name =
                string(item["realName"]) ?? string(item["name"]) ?? string(item["account"])
                ?? string(item["email"])
        else { return nil }
        return JoyDayPerson(
            name: name, email: string(item["email"]), userID: string(item["userId"]))
    }

    /// JoyDay marks an all-day row as midnight-to-midnight, possibly several days wide.
    private static func isAllDay(start: Date, end: Date) -> Bool {
        let calendar = Calendar.current
        guard calendar.component(.hour, from: start) == 0,
            calendar.component(.minute, from: start) == 0
        else { return false }
        return end.timeIntervalSince(start) >= 24 * 60 * 60
            && end.timeIntervalSince(start)
                .truncatingRemainder(dividingBy: 24 * 60 * 60) < 1
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.isEmpty ? nil : string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private static func milliseconds(_ value: Any?) -> Date? {
        guard let number = double(value) else { return nil }
        // Some payloads carry seconds; anything this small is not a plausible millisecond stamp.
        let seconds = number > 100_000_000_000 ? number / 1000 : number
        return Date(timeIntervalSince1970: seconds)
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    /// Strict, so a `&` or `=` inside the JSON body never breaks the form.
    private static func formEscape(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
