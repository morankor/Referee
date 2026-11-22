import Foundation
import RefereeCore

// Wave 0a placeholder (see Placeholder.swift).

/// Scripted availability and model list; `stream` throws .notConfigured.
public struct StaticProvider: LLMProvider {
    public let descriptor: ProviderDescriptor
    private let scriptedAvailability: ProviderAvailability
    private let scriptedModels: [ModelInfo]

    public init(descriptor: ProviderDescriptor, availability: ProviderAvailability, models: [ModelInfo]) {
        self.descriptor = descriptor
        self.scriptedAvailability = availability
        self.scriptedModels = models
    }

    public func availability() async -> ProviderAvailability { scriptedAvailability }

    public func listModels() async throws -> [ModelInfo] { scriptedModels }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: LLMError.notConfigured("this provider only reports a status"))
        }
    }
}
