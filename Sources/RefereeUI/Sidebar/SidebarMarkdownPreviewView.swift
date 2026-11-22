import SwiftUI

/// The report rendered (plan.md section 9.8, the Preview toggle): headings, paragraphs and list items from
/// `SidebarMarkdown.blocks`, whose text went through `AttributedString(markdown:)`.
struct SidebarMarkdownPreviewView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(SidebarMarkdown.blocks(from: markdown)) { block in
                    blockView(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder private func blockView(_ block: SidebarMarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text)
                .font(headingFont(level))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, block.id == 0 ? 0 : 6)
        case .paragraph:
            Text(block.text)
                .font(.system(size: SidebarMarkdownEditor.fontSize))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .numberedItem(let marker):
            item(marker: marker, block.text)
        case .bulletItem:
            item(marker: "•", block.text)
        case .rule:
            Divider()
        }
    }

    private func item(marker: String, _ text: AttributedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .monospacedDigit()
                .frame(minWidth: 16, alignment: .trailing)
            Text(text)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: SidebarMarkdownEditor.fontSize))
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.bold)
        case 2: return .title3.weight(.semibold)
        default: return .headline
        }
    }
}
