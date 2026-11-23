import SwiftUI

// What a pane needs from the window shell (plan.md section 9.1). Panes never reach into the shell: the shell sets real
// closures with .environment(\.uiActions, …) on every window's root view. The defaults do nothing, which is what the
// snapshot mode, previews and tests use.

public struct UIActions {
    public var openReferenceViewer: @MainActor (_ fileURL: URL, _ title: String) -> Void = { _, _ in }
    public var openSettings: @MainActor () -> Void = {}
    public var openInBrowser: @MainActor (URL) -> Void = { _ in }
    /// Lets the referee choose the paper's venue: the review window opens its toolbar's venue menu (step 5, G.9; the
    /// Report tab's "Change…").
    public var chooseVenue: @MainActor () -> Void = {}
    public init() {}
}
private struct UIActionsKey: EnvironmentKey { static let defaultValue = UIActions() }
public extension EnvironmentValues {
    var uiActions: UIActions { get { self[UIActionsKey.self] } set { self[UIActionsKey.self] = newValue } }
}
