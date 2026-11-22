import SwiftUI
import RefereeCore
import AppCore

// Wave 0 placeholder (plan.md section 11.4, WP0b): a label that marks the column. WP10 writes the sidebar
// (Comments / Chat / Report; sections 9.3, 9.5 and 9.8).

public struct ReviewSidebar: View {
    public init(model: ReviewSessionModel) {}

    public var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .font(.title2)
            Text("Sidebar")
                .font(Theme.cardTitleFont)
            Text("Comments, chat and the report will appear here.")
                .font(Theme.metadataFont)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(Theme.sidebarPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
