/// When waiting shows. A quick load just appears; an indicator would only flash.
enum LoadingPresentation {
    static let indicatorDelay = Duration.milliseconds(400)
    /// A picture that lands before an indicator would have shown reads as already there; fading it in would blink.
    static func fadesIn(waited: Duration) -> Bool { waited >= indicatorDelay }
    /// How long the previous conversation may stay up while the next one reads its cached rows. Past this the
    /// header changes and the rows follow.
    static let handoff = Duration.milliseconds(100)

    /// The SDK restores most drops within a moment; only one that lasts gets the connection notice.
    static let connectionNoticeDelay = Duration.seconds(2)

    static func showsConnectionNotice(downFor: Duration) -> Bool { downFor >= connectionNoticeDelay }

    /// Most sends land well within this; only a slow one gets Slack's clock beside it.
    static let sendingClockDelay = Duration.seconds(2)

    static func showsSendingClock(sendingFor: Duration) -> Bool { sendingFor >= sendingClockDelay }

    /// Offline, a network wait lasts until the connection returns; the connection notice says so instead.
    static func showsIndicator(waited: Duration, hasContent: Bool, offline: Bool = false) -> Bool {
        !hasContent && !offline && waited >= indicatorDelay
    }
}
