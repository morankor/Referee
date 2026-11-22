import SwiftUI
import RefereeCore
import AppCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP11 writes the welcome window (section 9.1).

public struct WelcomeView: View {
    public init(recent: [SessionSummary], open: @escaping (URL?) -> Void) {}   // nil = show the open panel

    public var body: some View { EmptyView() }
}
