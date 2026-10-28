import Foundation

/// Reads the files both apps test against: `design/tokens.json` and the product rules in `spec/`.
enum SharedSpec {
    static func decode<Value: Decodable>(_ path: String, as type: Value.Type = Value.self) throws -> Value {
        // Support/ → SlatrixTests/ → Tests/ → the repository.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(type, from: Data(contentsOf: root.appendingPathComponent(path)))
    }
}
