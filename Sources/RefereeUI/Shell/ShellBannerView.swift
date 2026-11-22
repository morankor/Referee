import SwiftUI
import AppKit
import RefereeCore
import AppCore

/// The banner of plan.md section 9.9: one message at a time, above the PDF in the detail column, dismissible, with at
/// most one action. The model decides which banner shows and fades notices after 6 s; this view only draws it. When
/// the model has none, a notice of the Shell's own (an export that failed) takes the place.
///
/// The banner declares no minimum width (`.frame(minWidth: 0)`): a minimum here would be added to the window's
/// smallest width, as one on the PDF would (section 9.2).
struct BannerView: View {
    let model: ReviewSessionModel
    let windowState: ShellReviewWindowState
    let services: ShellWindowServices

    var body: some View {
        if let banner = model.banner {
            ShellBannerRow(style: banner.style, message: banner.message, action: banner.action.map(actionButton),
                           dismiss: { model.dismissBanner() })
        } else if let notice = windowState.notice {
            ShellBannerRow(style: notice.style, message: notice.message, action: nil, dismiss: { windowState.notice = nil })
        }
    }

    private func actionButton(_ action: Banner.Action) -> ShellBannerRow.Action {
        switch action {
        case .retry:
            return ShellBannerRow.Action(title: "Retry") { model.retryLastFailedJob() }
        case .openSettings:
            return ShellBannerRow.Action(title: "Open Settings") {
                services.openSettings(.providers)
            }
        }
    }
}

/// One banner line: icon, message, the action, the close button.
struct ShellBannerRow: View {
    struct Action {
        var title: String
        var perform: () -> Void
    }

    let style: Banner.Style
    let message: String
    let action: Action?
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.body.weight(.semibold))
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let action {
                Button(action.title, action: action.perform)
                    .controlSize(.small)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 0, maxWidth: .infinity)
        .background(background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(color.opacity(0.35)).frame(height: 1)
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityPrefix + message))
    }

    private var symbol: String {
        switch style {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    /// The icon's colour; the warning icon is orange because yellow does not read on a light background.
    private var color: Color {
        switch style {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }

    /// Section 9.9 calls the warning banner yellow.
    private var background: Color {
        switch style {
        case .info: return Color.blue.opacity(0.12)
        case .warning: return Color.yellow.opacity(0.22)
        case .error: return Color.red.opacity(0.13)
        }
    }

    private var accessibilityPrefix: String {
        switch style {
        case .info: return ""
        case .warning: return "Warning: "
        case .error: return "Error: "
        }
    }
}
