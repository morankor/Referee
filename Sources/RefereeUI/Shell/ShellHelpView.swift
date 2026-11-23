import SwiftUI
import AppKit

/// Help ▸ Referee Help: the keys of section 9.4 and the commands of the menus, and a button that opens the README: in
/// the app's resources, where `scripts/bundle.sh` puts it (Wave 3), or next to a build in the checkout.
struct ShellHelpView: View {
    let readme: URL?

    static let triageKeys: [(String, String)] = [
        ("J / K", "Next / previous comment"),
        ("A", "Approve, then go to the next pending comment"),
        ("R or X", "Reject, then go on"),
        ("U", "Back to pending"),
        ("D", "Discuss the comment with the model"),
        ("E", "Edit the comment"),
        ("Return", "Show the passage in the PDF again"),
        ("N", "New comment of your own, on the selection if there is one"),
        ("1 2 3 4", "Kind: major, minor, question, strength"),
        ("Esc", "Close the open card, editor, thread or find bar, then clear the selection"),
    ]

    static let commands: [(String, String)] = [
        ("⌘R", "Run the review"), ("⌘.", "Cancel"), ("⇧⌘R", "Generate the report"), ("⇧⌘E", "Export the report"),
        ("⌘F  ⌘G", "Find, find next"), ("⌘1 ⌘2 ⌘3", "Comments, Chat, Report"), ("⌘+ ⌘− ⌘0", "Zoom in, out, fit width"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keys for triage")
                .font(.headline)
            Text("They work while the PDF or the comment list has the keyboard, not while you type.")
                .font(.callout)
                .foregroundStyle(.secondary)
            keyTable(Self.triageKeys)
            Text("Commands")
                .font(.headline)
            keyTable(Self.commands)
            Text("Every review is saved on this Mac as you work. A document's first send to a remote provider asks you first; "
                 + "the toolbar always shows where the text goes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let readme {
                Button("Open the README") { NSWorkspace.shared.open(readme) }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func keyTable(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .gridColumnAlignment(.trailing)
                    Text(row.1)
                }
            }
        }
    }

    /// The README: in the app's resources (`Contents/Resources/README.md`, copied by `scripts/bundle.sh`), or in the
    /// checkout the running binary was built in (scripts/run.sh), found by walking up from the executable to a folder
    /// that holds both README.md and Package.swift.
    static func findReadme() -> URL? {
        if let bundled = Bundle.main.url(forResource: "README", withExtension: "md") { return bundled }
        var folder = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<8 {
            guard let current = folder else { return nil }
            let readme = current.appendingPathComponent("README.md")
            if FileManager.default.fileExists(atPath: readme.path),
               FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) { return readme }
            folder = current.deletingLastPathComponent()
        }
        return nil
    }
}
