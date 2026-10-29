import Foundation

/// Slack's "Also send to #channel" for a thread reply: the channel gets a rich reply to it without rel_type m.thread,
/// which MSC3440 lets clients show in the main timeline to advertise a thread message.
enum ChannelCopy {
    /// The copy's event content as JSON. Its m.mentions is empty, so whoever the reply mentions hears once, from the
    /// thread.
    static func content(_ message: ComposerFormat.Message, replyTo eventID: String) throws -> String {
        var content: [String: Any] = [
            "msgtype": "m.text", "body": message.body, "m.mentions": [String: Any](),
            "m.relates_to": ["m.in_reply_to": ["event_id": eventID]],
        ]
        if let html = message.html {
            content["format"] = "org.matrix.custom.html"
            content["formatted_body"] = html
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: content), as: UTF8.self)
    }
}
