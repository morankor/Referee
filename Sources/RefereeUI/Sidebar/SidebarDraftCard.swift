import SwiftUI
import RefereeCore
import AppCore

/// A comment the model is still writing (plan.md section 9.3, "draft (streaming)"): title and body grow as text
/// arrives, the kind badge shows once the kind is known, there are no buttons, and the left bar pulses. Its header
/// names the provider and model of the review that writes it, as a finished comment's does (step 5b).
struct SidebarDraftCard: View {
    let draft: DraftComment
    let rubric: [RubricCategory]
    var source: SidebarSource?

    @State private var isPulsing = false

    var body: some View {
        let state = SidebarDraftState.make(for: draft, rubric: rubric)
        VStack(alignment: .leading, spacing: 6) {
            SidebarCardHeader(hasFacts: source != nil) {
                HStack(spacing: 5) {
                    if let kind = state.kind {
                        SidebarKindBadge(kind: kind)
                    }
                    if let category = state.categoryTitle {
                        Text(category)
                            .font(Theme.metadataFont)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } location: {
                if let page = state.pageLabel {
                    Text(page)
                        .font(Theme.metadataFont)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            } facts: {
                if let source {
                    SidebarSourceLabel(source: source)
                }
            }
            if let title = state.title {
                Text(title)
                    .font(Theme.cardTitleFont)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let quote = state.quote {
                Text(SidebarText.quoted(quote))
                    .font(Theme.quoteFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let body = state.body {
                Text(body)
                    .font(Theme.bodyFont)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let suggestion = state.suggestion {
                Text(SidebarText.labelled("Suggestion:", suggestion))
                    .font(Theme.bodyFont)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.isWaitingForText {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Writing the title and the comment…")
                        .font(Theme.metadataFont)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sidebarCardChrome(bar: Theme.statusColor(.pending), barOpacity: isPulsing ? 0.3 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { isPulsing = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Comment being written")
    }
}
