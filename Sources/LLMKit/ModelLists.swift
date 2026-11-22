import Foundation
import RefereeCore

/// Shared parts of the model listings of plan section 5.4.
enum ModelLists {
    /// The vendor's JSON, or `.malformedResponse`.
    static func decode(_ data: Data) throws -> JSONValue {
        guard let json = JSONValue.parse(data), json.objectValue != nil else {
            throw LLMError.malformedResponse("the model list could not be read")
        }
        return json
    }

    /// Fetches pages until the vendor gives no next token. A token seen before, or more than 50 pages, also stops it,
    /// so a vendor that repeats itself cannot keep the app asking.
    static func paginate(maxPages: Int = 50,
                         _ fetchPage: (_ token: String?) async throws -> (models: [ModelInfo], next: String?)) async throws -> [ModelInfo] {
        var models: [ModelInfo] = []
        var token: String?
        var seen = Set<String>()
        for _ in 0..<maxPages {
            let page = try await fetchPage(token)
            models += page.models
            guard let next = page.next, !next.isEmpty, seen.insert(next).inserted else { break }
            token = next
        }
        return models
    }

    /// The models whose ids contain none of `words` (case-insensitive), unless `showAll` (the "Show all" toggle of
    /// sections 5.4.2, 5.4.4 and 9.6).
    static func hiding(_ models: [ModelInfo], idsContaining words: [String], showAll: Bool) -> [ModelInfo] {
        guard !showAll else { return models }
        return models.filter { model in
            let id = model.id.lowercased()
            return !words.contains { id.contains($0) }
        }
    }
}
