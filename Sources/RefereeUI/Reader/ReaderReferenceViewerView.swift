import SwiftUI
import RefereeCore
import AppCore

// Wave 0 placeholder (plan.md section 11.4, WP0b): a label with the title. WP9 writes the viewer (section 7.7).

public struct ReferenceViewerView: View {  // read-only viewer for a cited paper
    private let title: String

    public init(fileURL: URL, title: String) { self.title = title }

    public var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.title2)
            Text(title)
                .font(Theme.cardTitleFont)
            Text("The cited paper will be shown here.")
                .font(Theme.metadataFont)
        }
        .foregroundStyle(.secondary)
        .padding(Theme.sidebarPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
