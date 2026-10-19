import SwiftUI

/// Tiny modal that prompts for a section name. Used for both rename and
/// new-section flows so the look stays consistent. With `choices`, it offers
/// those sections first and a new name as the last choice: mrk mode asks it
/// which section the formulae it is adding go in.
struct SectionNameSheet: View {
    let title: String
    let message: String?
    let confirmLabel: String
    let initial: String
    let choices: [String]
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var choice: String
    @FocusState private var fieldFocused: Bool

    private static let newSection = "__new__"

    init(
        title: String,
        message: String? = nil,
        confirmLabel: String = "OK",
        initial: String = "",
        choices: [String] = [],
        onSubmit: @escaping (String) -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.initial = initial
        self.choices = choices
        self.onSubmit = onSubmit
        _text = State(initialValue: initial)
        _choice = State(initialValue: choices.first ?? Self.newSection)
    }

    private var typing: Bool { choices.isEmpty || choice == Self.newSection }

    private var result: String {
        (typing ? text : choice).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !choices.isEmpty {
                Picker("", selection: $choice) {
                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                    Text("New Section…").tag(Self.newSection)
                }
                .labelsHidden()
            }
            if typing {
                TextField("Section name", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { submit() }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(result.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { fieldFocused = typing }
    }

    private func submit() {
        let chosen = result
        guard !chosen.isEmpty else { return }
        onSubmit(chosen)
        dismiss()
    }
}
