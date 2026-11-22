import Foundation
import Testing
import RefereeCore
import TestSupport
import LLMKit
import CLIProviders

/// Gate 1: the nine static rows of `SnapshotSupport.providers()` carry the descriptors of the real providers (with the
/// default settings), so that the settings scenes of the snapshot mode show what the app shows. Gate 0 left the CLI rows
/// with their Wave 0 values; WP5's delivery experiment changed the real ones (plan.md section 5.6.6).
@Suite struct SnapshotRowsTests {
    @Test func everyStaticRowHasTheRealProvidersDescriptor() {
        let defaults = DefaultSettings.make()
        let environment = ProviderEnvironment(settings: { defaults.providers[$0] ?? ProviderSettings(enabled: false, inputMode: .auto) },
                                              secrets: InMemorySecretStore(), urlSession: StubURLProtocol.session(), processEnvironment: [:])
        let real = (LLMKitFactory.makeProviders(environment: environment) + CLIProviderFactory.makeProviders(environment: environment)).map(\.descriptor)
        let rows = SnapshotSupport.providers().dropFirst(4).map(\.descriptor)
        #expect(rows.map(\.id) == real.map(\.id))
        for (row, descriptor) in zip(rows, real) {
            #expect(row == descriptor, "\(descriptor.id): the snapshot row differs from the real descriptor")
        }
    }
}
