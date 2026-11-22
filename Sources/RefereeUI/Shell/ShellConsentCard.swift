import SwiftUI
import AppKit
import RefereeCore
import AppCore

/// The consent card of plan.md section 9.7: an overlay over the whole window that blocks it until it is answered,
/// shown while `model.consentRequest` is set. It is drawn in the window, not as a sheet, so that the snapshot mode
/// captures it (section 10.1).
///
/// Send is not the default button: Return must not send a confidential manuscript by accident. Esc cancels (the
/// window's key monitor also answers Esc while the card is up).
struct ConsentCard: View {
    let model: ReviewSessionModel

    var body: some View {
        if let request = model.consentRequest {
            ZStack {
                Color.black.opacity(0.28)
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
                    Text(text.provider)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(text.what)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(text.again)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let retention = text.retention {
                    Label(retention, systemImage: "terminal")
                        .labelStyle(ShellLeadingIconLabelStyle())
                }
                ForEach(text.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .labelStyle(ShellLeadingIconLabelStyle())
                        .foregroundStyle(.secondary)
                }
                if let blocking = text.blockingReason {
                    Text(blocking)
                        .foregroundStyle(.red)
                }
            }
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            Text(text.policy)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Toggle("Ask again next time", isOn: $askAgain)
                    .toggleStyle(.checkbox)
                Spacer(minLength: 12)
                Button("Cancel") { model.answerConsent(granted: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Send") { model.answerConsent(granted: true, askAgain: askAgain) }
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
