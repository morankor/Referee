import SwiftUI
import RefereeCore
import AppCore

// Wave 0 placeholder (plan.md section 11.4, WP0b): a label that marks the column. WP9 writes the pane
// (Pages / Outline / References; section 7.6).

public struct NavigatorPane: View {       // Pages / Outline / References
    public init(controller: ReaderController) {}

    public var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "sidebar.left")
                .font(.title2)
            Text("Navigator")
                .font(Theme.cardTitleFont)
            Text("Pages, outline and references will appear here.")
                .font(Theme.metadataFont)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(Theme.sidebarPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
