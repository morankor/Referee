import SwiftUI
import RefereeCore
import AppCore

// Wave 0 placeholder (plan.md section 11.4, WP0b): the name of the app and how many recent reviews it was given.
// WP11 writes the welcome window (section 9.1).

public struct WelcomeView: View {
    private let recent: [SessionSummary]

    public init(recent: [SessionSummary], open: @escaping (URL?) -> Void) { self.recent = recent }   // nil = show the open panel

    public var body: some View {
        VStack(spacing: 6) {
            Text("Referee")
                .font(.largeTitle)
            Text("Open a manuscript with: scripts/run.sh <file.pdf>")
                .font(Theme.bodyFont)
            Text(recent.isEmpty ? "No recent reviews." : "Recent reviews: \(recent.count)")
                .font(Theme.metadataFont)
        }
        .foregroundStyle(.secondary)
        .padding(Theme.sidebarPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
