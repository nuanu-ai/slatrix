import Foundation

/// A queued refresh and its debounced continuation belong to the same visible
/// search request and Matrix session; they cannot revive a dismissed search.
struct SearchRequestOwner: Equatable {
    let sessionID: UUID
    let revision: Int
    func isCurrent(_ current: SearchRequestOwner, isPresented: Bool) -> Bool {
        isPresented && self == current
    }
}
