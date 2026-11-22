import Foundation
import RefereeCore

// Wave 0a placeholder (see Placeholder.swift): no providers yet, and the settings are the plain defaults.

public enum SnapshotSupport {
    /// "mock" (local), "mock-remote" (non-local, destination "mock.example.org"), "mock-fail" (.failsAfterTwoComments),
    /// "mock-stall" (.stallsAfterTwoComments), then one StaticProvider per provider id of section 5.2 in mixed states.
    public static func providers() -> [any LLMProvider] { [] }
    /// DefaultSettings.make() with the four mocks enabled and "mock" as the review default.
    public static func settings() -> AppSettings { DefaultSettings.make() }
}
