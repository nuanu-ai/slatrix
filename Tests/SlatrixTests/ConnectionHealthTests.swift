import Testing

@testable import Slatrix

struct ConnectionHealthTests {
    struct Case: Decodable {
        let name: String
        let network: Bool?
        let foreground, running, responded, interrupted, previouslyConnected: Bool
        let state: ConnectionHealth
        let label: String
    }
    struct Spec: Decodable { let cases: [Case] }

    @Test func sharedConnectionStates() throws {
        for row in try SharedSpec.decode("spec/connection-state.json", as: Spec.self).cases {
            let state = ConnectionHealth.resolve(
                network: row.network, foreground: row.foreground,
                running: row.running, responded: row.responded, interrupted: row.interrupted,
                previouslyConnected: row.previouslyConnected)
            #expect(state == row.state, "\(row.name)")
            #expect(state.label == row.label, "\(row.name)")
        }
    }

    @MainActor @Test("Only a lost network shows a crossed-out Wi-Fi; reconnecting to the server does not")
    func noticeSymbol() {
        let matrix = MatrixService.scratch()
        matrix.applyConnection(
            MatrixConnectionFeedback(
                state: .offline, isRetrying: true, canRetry: false, errorMessage: ConnectionHealth.reconnecting.label))
        #expect(matrix.connectionSymbol != "wifi.slash")
        matrix.applyConnection(
            MatrixConnectionFeedback(
                state: .offline, isRetrying: false, canRetry: false, errorMessage: ConnectionHealth.offline.label))
        #expect(matrix.connectionSymbol == "wifi.slash")
    }

    // capability: app.own-presence
    @MainActor @Test("Your own dot goes hollow only once the connection is lost, not while it first connects")
    func ownDot() {
        let matrix = MatrixService.scratch()
        matrix.applyConnection(
            MatrixConnectionFeedback(state: .connecting, isRetrying: false, canRetry: false, errorMessage: nil))
        #expect(!matrix.connectionLost)
        matrix.applyConnection(
            MatrixConnectionFeedback(
                state: .offline, isRetrying: false, canRetry: true, errorMessage: ConnectionHealth.offline.label))
        #expect(matrix.connectionLost)
        matrix.applyConnection(
            MatrixConnectionFeedback(state: .running, isRetrying: false, canRetry: false, errorMessage: nil))
        #expect(!matrix.connectionLost)
    }

    @MainActor @Test("Avatar dot is never falsely green before connecting or while reconnecting")
    func honestOwnPresence() {
        let matrix = MatrixService.scratch()
        #expect(matrix.ownPresence(downLongEnough: false) == nil)
        #expect(matrix.ownPresence(downLongEnough: true) == .away)

        matrix.applyConnection(
            MatrixConnectionFeedback(
                state: .connecting, isRetrying: false, canRetry: false,
                errorMessage: ConnectionHealth.connecting.label))
        #expect(matrix.ownPresence(downLongEnough: false) == nil)
        #expect(matrix.ownPresence(downLongEnough: true) == .away)
        #expect(matrix.connectionStatusLabel == "Connecting…")

        matrix.applyConnection(
            MatrixConnectionFeedback(
                state: .connecting, isRetrying: true, canRetry: false,
                errorMessage: ConnectionHealth.reconnecting.label))
        #expect(matrix.connectionLost)
        #expect(matrix.ownPresence(downLongEnough: false) == .away)
        #expect(matrix.connectionStatusLabel == "Reconnecting…")

        matrix.applyConnection(
            MatrixConnectionFeedback(state: .running, isRetrying: false, canRetry: false, errorMessage: nil))
        #expect(matrix.ownPresence(downLongEnough: false) == .active)
        #expect(matrix.connectionStatusLabel == "Connected")
    }

    @Test("Connection banner reassures the user when messages are queued offline")
    func bannerTextWithQueuedMessages() {
        #expect(ConnectionHealth.bannerText(notice: nil, queuedCount: 2) == nil)
        #expect(ConnectionHealth.bannerText(notice: "You’re offline", queuedCount: 0) == "You’re offline")
        #expect(
            ConnectionHealth.bannerText(notice: "You’re offline", queuedCount: 1)
                == "You’re offline · 1 message will send when you reconnect")
        #expect(
            ConnectionHealth.bannerText(notice: "You’re offline", queuedCount: 2)
                == "You’re offline · 2 messages will send when you reconnect")
    }
}
