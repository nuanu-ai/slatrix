import Foundation

/// The rows a conversation or thread timeline shows: day dividers, the unread line and messages with their grouping
/// and time labels. Computed once per change of the messages, never per row render.
enum TimelineLayout {
    /// A message joins the one above it when the same person sent it this soon after, as Slack does.
    static let groupingInterval: TimeInterval = 300

    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            case day(String)
            case unread
            /// Under a thread's root, as Slack sets the root apart from its replies.
            case replies(Int)
            case message(ChatMessage, grouped: Bool, time: String)
        }
        let id: String
        let kind: Kind
    }

    /// A hovered message's time in the gutter, which has room for the hour and minute only, as Slack writes it there.
    static func gutterTime(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        // Asking the format style to omit AM and PM pads the hour: "01:05".
        var time = date.formatted(
            Date.FormatStyle(
                date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone
            )
            .attributed)
        for (field, range) in time.runs[\.dateField] where field == .amPM { time.removeSubrange(range) }
        return String(time.characters).trimmingCharacters(in: .whitespaces)
    }

    /// `unreadBoundaryEventID` is the event the "New messages" line goes above; `groups` is false in compact density;
    /// `threadRootEventID` is a thread's root, which gets the line counting its replies once it has loaded.
    static func rows(
        _ messages: [ChatMessage], unreadBoundaryEventID: String?, groups: Bool, threadRootEventID: String? = nil,
        now: Date, calendar: Calendar, locale: Locale
    ) -> [Row] {
        let time = Date.FormatStyle(
            date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let day = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.wide)
            .month(.wide).day()
        var rows: [Row] = []
        rows.reserveCapacity(messages.count + 4)
        var previous: ChatMessage?
        // The previous message's day; one calendar lookup per day rather than per message.
        var currentDay: DateInterval?
        var days: [(row: Int, id: String)] = []
        for (index, message) in messages.enumerated() {
            let newDay = currentDay.map { !($0.start <= message.timestamp && message.timestamp < $0.end) } ?? true
            if newDay {
                currentDay = calendar.dateInterval(of: .day, for: message.timestamp)
                let components = calendar.dateComponents([.year, .month, .day], from: message.timestamp)
                let label =
                    calendar.isDate(message.timestamp, inSameDayAs: now)
                    ? "Today"
                    : calendar.date(byAdding: .day, value: -1, to: now).map {
                        calendar.isDate(message.timestamp, inSameDayAs: $0)
                    } == true ? "Yesterday" : message.timestamp.formatted(day)
                let dayID = "day-\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
                days.append((rows.count, dayID))
                rows.append(Row(id: "\(dayID)-\(message.id)", kind: .day(label)))
            }
            let unread = unreadBoundaryEventID != nil && message.eventID == unreadBoundaryEventID
            if unread { rows.append(Row(id: "unread", kind: .unread)) }
            let grouped =
                groups && !newDay && !unread && (threadRootEventID == nil || previous?.eventID != threadRootEventID)
                && previous.map {
                    $0.senderID == message.senderID
                        && message.timestamp.timeIntervalSince($0.timestamp) < groupingInterval
                } == true
            rows.append(
                Row(id: message.id, kind: .message(message, grouped: grouped, time: message.timestamp.formatted(time))))
            previous = message
            if message.eventID == threadRootEventID {
                rows.append(Row(id: "replies", kind: .replies(messages.count - index - 1)))
            }
        }
        // Server timestamps can return to a day already shown. Its newest line takes the day's own ID, so older history
        // arriving above never hands that ID to another line.
        var seen = Set<String>()
        for day in days.reversed() where seen.insert(day.id).inserted {
            rows[day.row] = Row(id: day.id, kind: rows[day.row].kind)
        }
        return rows
    }
}
