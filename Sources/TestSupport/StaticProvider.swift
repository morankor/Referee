import Foundation
import RefereeCore

/// Scripted availability and model list; `stream` throws .notConfigured.
///
/// It stands for a provider in the settings scenes of the snapshot mode: it has a status and models to show, and it
/// can never send anything.
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
