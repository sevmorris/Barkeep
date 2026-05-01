import SwiftUI

/// Tiny modal that prompts for a section name. Used for both rename and
/// new-section flows so the look stays consistent.
struct SectionNameSheet: View {
    let title: String
    let confirmLabel: String
    let initial: String
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var fieldFocused: Bool

    init(
        title: String,
        confirmLabel: String = "OK",
        initial: String = "",
        onSubmit: @escaping (String) -> Void
    ) {
        self.title = title
        self.confirmLabel = confirmLabel
        self.initial = initial
        self.onSubmit = onSubmit
        _text = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Section name", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { submit() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        dismiss()
    }
}
