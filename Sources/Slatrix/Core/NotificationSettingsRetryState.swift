import Combine
import Foundation

@MainActor
final class NotificationSettingsRetryState: ObservableObject {
    enum Target: Equatable {
        case room(id: String, choice: RoomNotificationChoice)
        case account(category: AccountNotificationCategory, mode: AccountNotificationMode)
    }
    struct Ticket: Equatable {
        fileprivate let generation: UUID
        fileprivate let id: UUID
        fileprivate let target: Target
    }

    @Published private(set) var roomChoices: [String: RoomNotificationChoice] = [:]
    @Published private(set) var defaultModes: [AccountNotificationCategory: AccountNotificationMode] = [:]
    @Published private(set) var isWriting = false
    @Published private(set) var revision = 0
    private var generation = UUID()
    private var active: Ticket?

    func begin(_ target: Target) throws -> Ticket {
        guard active == nil else {
            throw MatrixServiceError.request(
                "Notification settings are already being updated. Wait for that update to finish.")
        }
        let ticket = Ticket(generation: generation, id: UUID(), target: target)
        active = ticket
        isWriting = true
        revision += 1
        return ticket
    }

    func recordFailure(_ ticket: Ticket) {
        guard active == ticket, ticket.generation == generation else { return }
        switch ticket.target {
        case .room(let id, let choice): roomChoices[id] = choice
        case .account(let category, let mode): defaultModes[category] = mode
        }
        revision += 1
    }

    func accepted(_ ticket: Ticket) {
        guard active == ticket, ticket.generation == generation else { return }
        switch ticket.target {
        case .room(let id, _): roomChoices.removeValue(forKey: id)
        case .account(let category, _): defaultModes.removeValue(forKey: category)
        }
        revision += 1
    }

    func end(_ ticket: Ticket) {
        guard active == ticket, ticket.generation == generation else { return }
        active = nil
        isWriting = false
        revision += 1
    }

    func reset() {
        generation = UUID()
        active = nil
        roomChoices = [:]
        defaultModes = [:]
        isWriting = false
        revision += 1
    }

    // Reading a matching cached value cannot acknowledge a failed multi-rule write.
    func decorate(_ snapshot: RoomNotificationSnapshot) -> RoomNotificationSnapshot {
        var snapshot = snapshot
        snapshot.pendingRetryChoice = roomChoices[snapshot.roomID]
        return snapshot
    }
    func decorate(_ snapshot: AccountNotificationDefaultsSnapshot) -> AccountNotificationDefaultsSnapshot {
        var snapshot = snapshot
        snapshot.pendingRetryModes = defaultModes
        return snapshot
    }
}
