import Foundation
import RefereeCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP5 deletes this file when the real adapters exist.

/// Stands in for a subscription CLI provider that has not been written yet: it reports that it needs setting up,
/// lists no models and refuses to stream. It never looks for a binary and never starts a process.
struct UnimplementedCLIProvider: LLMProvider {
    let descriptor: ProviderDescriptor

    func availability() async -> ProviderAvailability {
        .needsSetup(reason: "not implemented", hint: "This provider is not part of this build yet.")
    }

    func listModels() async throws -> [ModelInfo] { [] }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: LLMError.notConfigured("not implemented"))
        }
    }
}
