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
            /// Under a thread's root, as Slack sets the root apart from its replies: the words that count them.
            case replies(String)
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
    /// `threadRootEventID` is a thread's root, which gets the line counting its replies.
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
        var dayIDs = Set<String>()
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
                // Server timestamps can return to a day already shown.
                let id = dayIDs.insert(dayID).inserted ? dayID : "\(dayID)-\(message.id)"
                rows.append(Row(id: id, kind: .day(label)))
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
            if message.eventID == threadRootEventID,
                let label = repliesLabel(message.replyCount ?? 0, replies: messages[(index + 1)...])
            {
                rows.append(Row(id: "replies", kind: .replies(label)))
            }
        }
        return rows
    }

    /// The words under a thread's root, as the channel counts its replies, and nil for no line. The root's count can
    /// lag behind, or already include, a reply of this device's, so the replies held that haven't failed count when
    /// they're more. The cases are in spec/thread-replies.json.
    private static func repliesLabel(_ rootCount: Int, replies: ArraySlice<ChatMessage>) -> String? {
        let count = max(rootCount, replies.count { $0.sendState != "failed" })
        return count == 0 ? nil : count == 1 ? "1 reply" : "\(count) replies"
    }
}
