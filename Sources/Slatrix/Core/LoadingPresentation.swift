/// When waiting shows. A quick load just appears; an indicator would only flash.
enum LoadingPresentation {
    static let indicatorDelay = Duration.milliseconds(400)

    static func showsIndicator(waited: Duration, hasContent: Bool) -> Bool {
        !hasContent && waited >= indicatorDelay
    }
}
