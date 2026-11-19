import Foundation
import Network

enum NetworkRoute: Equatable, Sendable {
    case offline
    case online(interface: Int?, gateways: Set<NWEndpoint>)
}

enum NetworkConnectivity {
    static func changes() -> AsyncStream<NetworkRoute> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                guard path.status == .satisfied else {
                    continuation.yield(.offline)
                    return
                }
                let interface = path.availableInterfaces.first { path.usesInterfaceType($0.type) }
                continuation.yield(.online(interface: interface?.index, gateways: Set(path.gateways)))
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "ai.nuanu.slatrix.connectivity"))
        }
    }
}
