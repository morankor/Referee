import SwiftUI

/// A small tag in one colour (plan.md section 9.10; step 5, design review D16): its text in `Theme.tagFont` and the
/// colour, on a capsule of the colour at 15%. The one look of "You", "verify", "Revision proposed", "Open access" and
/// "Experimental", so that the three panes draw small tags alike. It keeps its size: it neither wraps nor truncates.
///
///     CommonTag("Open access", color: .green)
public struct CommonTag: View {
    let text: String
    let color: Color

    public init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(Theme.tagFont)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .fixedSize()
    }
}
