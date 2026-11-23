import SwiftUI
import AppKit
import RefereeCore
import AppCore

/// The consent card of plan.md section 9.7: an overlay over the whole window that blocks it until it is answered,
/// shown while `model.consentRequest` is set. It is drawn in the window, not as a sheet, so that the snapshot mode
/// captures it (section 10.1).
///
/// Design review D12: what is sent, to whom, in how many requests and who keeps it, as a grid of facts under the title;
/// "Don't Send" (Esc) and "Send to <vendor>". Send is not the default button: Return must not send a confidential
/// manuscript by accident. The window's key monitor also answers Esc while the card is up. The scrim is darker in dark
/// mode, where 28% black barely dims the sidebar.
struct ConsentCard: View {
    let model: ReviewSessionModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let request = model.consentRequest {
            ZStack {
                Color.black.opacity(colorScheme == .dark ? 0.5 : 0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}                   // the window is blocked: clicks behind the card do nothing
                    .accessibilityHidden(true)
                ShellConsentPanel(model: model, request: request,
                                  text: ShellPlanText.consent(request: request, pageCount: model.paper?.ref.pageCount ?? 0,
                                                              byteCount: model.paper?.ref.byteCount ?? model.paper?.data.count ?? 0))
                    .id(request.id)                    // a new request starts with "Ask again" unticked
            }
            .transition(.opacity)
        }
    }
}

/// The card itself.
private struct ShellConsentPanel: View {
    let model: ReviewSessionModel
    let request: ConsentRequest
    let text: ShellConsentText
    @State private var askAgain = false
    @AccessibilityFocusState private var titleFocused: Bool     // D22: VoiceOver starts at the question

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "paperplane.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(text.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($titleFocused)
                    Text(text.provider)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ShellFactsGrid(facts: text.facts, valueFont: .body)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(text.what))
                .accessibilityValue(Text(text.facts.first { $0.label == "Kept" }?.value ?? ""))
            VStack(alignment: .leading, spacing: 8) {
                Text(text.again)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(text.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .labelStyle(ShellLeadingIconLabelStyle())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let blocking = text.blockingReason {
                    Text(blocking)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.body)
            Text(text.policy)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 10) {
                Toggle("Ask again next time", isOn: $askAgain)
                    .toggleStyle(.checkbox)
                Spacer(minLength: 12)
                Button(ShellPlanText.dontSend) { model.answerConsent(granted: false) }
                    .keyboardShortcut(.cancelAction)
                Button(text.sendButton) { model.answerConsent(granted: true, askAgain: askAgain) }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear { titleFocused = true }
    }
}

/// The facts of a send plan in two columns (D12, D24): the labels right-aligned in the secondary colour, the values
/// wrapping beside them; the warning row with an orange triangle in place of its label, all of it orange.
struct ShellFactsGrid: View {
    let facts: [ShellConsentFact]
    let valueFont: Font

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                GridRow {
                    Group {
                        if fact.isWarning {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        } else {
                            Text(fact.label)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .gridColumnAlignment(.trailing)
                    Text(fact.value)
                        .font(valueFont)
                        .foregroundStyle(fact.isWarning ? Color.orange : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// A label whose icon sits at the top of a text that may wrap.
struct ShellLeadingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}
