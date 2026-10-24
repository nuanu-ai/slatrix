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
            case message(ChatMessage, grouped: Bool, time: String)
        }
        let id: String
        let kind: Kind
    }

    /// `unreadBoundaryEventID` is the event the "New messages" line goes above; `groups` is false in compact density.
    static func rows(
        _ messages: [ChatMessage], unreadBoundaryEventID: String?, groups: Bool, now: Date, calendar: Calendar,
        locale: Locale
    ) -> [Row] {
        let time = Date.FormatStyle(
            date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let day = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.wide)
            .month(.wide).day()
        var rows: [Row] = []
        rows.reserveCapacity(messages.count + 4)
        var previous: ChatMessage?
        for message in messages {
            let newDay = previous.map { !calendar.isDate($0.timestamp, inSameDayAs: message.timestamp) } ?? true
            if newDay {
                let components = calendar.dateComponents([.year, .month, .day], from: message.timestamp)
                let label =
                    calendar.isDate(message.timestamp, inSameDayAs: now)
                    ? "Today"
                    : calendar.date(byAdding: .day, value: -1, to: now).map {
                        calendar.isDate(message.timestamp, inSameDayAs: $0)
                    } == true ? "Yesterday" : message.timestamp.formatted(day)
                rows.append(
                    Row(
                        id: "day-\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)",
                        kind: .day(label)))
            }
            let unread = unreadBoundaryEventID != nil && message.eventID == unreadBoundaryEventID
            if unread { rows.append(Row(id: "unread", kind: .unread)) }
            let grouped =
                groups && !newDay && !unread
                && previous.map {
                    $0.senderID == message.senderID
                        && message.timestamp.timeIntervalSince($0.timestamp) < groupingInterval
                } == true
            rows.append(
                Row(id: message.id, kind: .message(message, grouped: grouped, time: message.timestamp.formatted(time))))
            previous = message
        }
        return rows
    }
}
