/// When waiting shows. A quick load just appears; an indicator would only flash.
enum LoadingPresentation {
    static let indicatorDelay = Duration.milliseconds(400)
    /// How long the previous conversation may stay up while the next one reads its cached rows. Past this the
    /// header changes and the rows follow.
    static let handoff = Duration.milliseconds(100)

    static func showsIndicator(waited: Duration, hasContent: Bool) -> Bool {
        !hasContent && waited >= indicatorDelay
    }
}
