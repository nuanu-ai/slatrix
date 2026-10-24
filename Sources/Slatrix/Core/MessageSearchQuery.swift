import Foundation

/// Serializes text for the SDK's existing Tantivy query parser. Phrase mode
/// uses one literal: the pinned grammar consumes backslash + any character
/// inside double quotes (tantivy-query-grammar 0.26, simple_term).
struct MessageSearchQuery: Hashable {
    enum Mode: String, CaseIterable, Hashable {
        case query = "Query"
        case phrase = "Phrase"
    }
    let text: String
    let mode: Mode
    let sdkQuery: String?

    init(_ input: String, mode: Mode = .query) {
        text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mode = mode
        guard !text.isEmpty else {
            sdkQuery = nil
            return
        }
        switch mode {
        case .query: sdkQuery = text
        case .phrase:
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            sdkQuery = "\"" + escaped + "\""
        }
    }
}
