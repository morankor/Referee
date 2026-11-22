import SwiftUI

// The find bar over the top of the PDF (plan.md section 7.6): a field, "3 of 17", previous, next, Done. Return goes to
// the next match, Shift-Return to the previous one, Esc closes the bar. Shown for the manuscript (ReaderPane) and in the
// reference viewer, each with its own ReaderFinder.

struct ReaderFindBar: View {
    @Bindable var finder: ReaderFinder
    @FocusState private var fieldIsFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in document", text: $finder.query)
                .textFieldStyle(.plain)
                .focused($fieldIsFocused)
                .frame(minWidth: 80, maxWidth: .infinity)
                .onSubmit {
                    if NSEvent.modifierFlags.contains(.shift) { finder.previous() } else { finder.next() }
                }
                .onChange(of: finder.query) { finder.queryDidChange() }
                .onExitCommand { finder.close() }
            Text(finder.countText)
                .font(Theme.metadataFont)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            ControlGroup {
                Button { finder.previous() } label: { Image(systemName: "chevron.left") }
                    .help("Previous match (⇧⌘G)")
                Button { finder.next() } label: { Image(systemName: "chevron.right") }
                    .help("Next match (⌘G)")
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(finder.resultCount == 0)
            Button("Done") { finder.close() }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardCornerRadius).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .onAppear { fieldIsFocused = true }
        .onChange(of: finder.focusRequest) { fieldIsFocused = true }
    }
}
