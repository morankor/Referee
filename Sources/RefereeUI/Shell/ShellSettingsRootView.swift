import SwiftUI
import RefereeCore
import AppCore

// Wave 0 placeholder (plan.md section 11.4, WP0b): a label and the number of providers. WP11 writes the settings
// window (section 9.6).

public struct SettingsRootView: View {
    private let model: SettingsModel

    public init(model: SettingsModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "gearshape")
                .font(.title2)
            Text("Settings")
                .font(Theme.cardTitleFont)
            Text("Providers: \(model.providers.count)")
                .font(Theme.metadataFont)
        }
        .foregroundStyle(.secondary)
        .padding(Theme.sidebarPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
