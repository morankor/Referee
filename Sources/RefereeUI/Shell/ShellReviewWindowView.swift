import SwiftUI
import RefereeCore
import AppCore

// Wave 0 placeholder (plan.md section 11.4, WP0b): the three columns composed as section 9.2 prescribes, and nothing
// else. WP11 writes the window: toolbar, destination indicator, banner, consent card.

public struct ReviewWindowView: View {
    private let model: ReviewSessionModel
    private let reader: ReaderController
    @State private var showSidebar = true

    public init(model: ReviewSessionModel, reader: ReaderController) {
        self.model = model
        self.reader = reader
    }

    public var body: some View {
        NavigationSplitView {
            NavigatorPane(controller: reader)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 240)
        } detail: {
            VStack(spacing: 0) {
                // The banner of section 9.9 goes here, above the PDF.
                ReaderPane(controller: reader)
            }
        }
        .inspector(isPresented: $showSidebar) {
            ReviewSidebar(model: model)
                .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
        }
    }
}
