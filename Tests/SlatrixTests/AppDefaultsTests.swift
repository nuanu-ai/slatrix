import Foundation
import Testing

@testable import Slatrix

struct AppDefaultsTests {
    @Test("macOS doesn't guess AutoFill for Slatrix's fields, such as contacts under Find members")
    func autoFillGuessesOff() throws {
        let name = "SlatrixTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        SlatrixEntry.registerDefaults(defaults)

        #expect(defaults.object(forKey: "NSAutoFillHeuristicsEnabled") as? Bool == false)
    }
}
