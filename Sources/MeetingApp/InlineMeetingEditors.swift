import SwiftUI

struct InlineEditableTitle: View {
    let value: String
    let placeholder: String
    let font: Font
    let lineLimit: Int
    let accessibilityLabel: String
    let onCommit: (String) -> Void

    @State private var isEditing = false
    @State private var draftValue: String
    @FocusState private var isFieldFocused: Bool

    init(
        value: String,
        placeholder: String,
        font: Font,
        lineLimit: Int,
        accessibilityLabel: String,
        onCommit: @escaping (String) -> Void
    ) {
        self.value = value
        self.placeholder = placeholder
        self.font = font
        self.lineLimit = lineLimit
        self.accessibilityLabel = accessibilityLabel
        self.onCommit = onCommit
        _draftValue = State(initialValue: value)
    }

    var body: some View {
        Group {
            if isEditing {
                TextField(placeholder, text: $draftValue)
                    .textFieldStyle(.plain)
                    .font(font)
                    .lineLimit(1)
                    .focused($isFieldFocused)
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
            } else {
                Button(action: beginEditing) {
                    Text(value)
                        .font(font)
                        .lineLimit(lineLimit)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(accessibilityLabel)
                .accessibilityLabel(accessibilityLabel)
            }
        }
        .onChange(of: isFieldFocused) {
            if !isFieldFocused, isEditing {
                commit()
            }
        }
        .onChange(of: value) {
            if !isEditing {
                draftValue = value
            }
        }
    }

    private var normalizedDraftValue: String {
        draftValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginEditing() {
        draftValue = value
        isEditing = true
        DispatchQueue.main.async {
            isFieldFocused = true
        }
    }

    private func commit() {
        guard !normalizedDraftValue.isEmpty else {
            cancel()
            return
        }
        let newValue = normalizedDraftValue
        isEditing = false
        isFieldFocused = false
        if newValue != value {
            onCommit(newValue)
        }
    }

    private func cancel() {
        draftValue = value
        isEditing = false
        isFieldFocused = false
    }
}

struct InlineEditableMeetingContext: View {
    let context: String
    let onCommit: (String) -> Void

    @State private var isEditing = false
    @State private var draftContext: String
    @FocusState private var isEditorFocused: Bool

    init(context: String, onCommit: @escaping (String) -> Void) {
        self.context = context
        self.onCommit = onCommit
        _draftContext = State(initialValue: context)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CONTEXTE")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(.secondary)

            if isEditing {
                TextEditor(text: $draftContext)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                    }
                    .frame(minHeight: 66, maxHeight: 110)
                    .focused($isEditorFocused)
                    .onExitCommand(perform: cancel)
                    .accessibilityLabel("Contexte de la réunion")
            } else {
                Button(action: beginEditing) {
                    Text(context.isEmpty ? "Ajouter du contexte…" : context)
                        .font(.callout)
                        .foregroundStyle(context.isEmpty ? .secondary : .primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Modifier le contexte de la réunion")
                .accessibilityLabel("Modifier le contexte de la réunion")
            }
        }
        .onChange(of: isEditorFocused) {
            if !isEditorFocused, isEditing {
                commit()
            }
        }
        .onChange(of: context) {
            if !isEditing {
                draftContext = context
            }
        }
    }

    private func beginEditing() {
        draftContext = context
        isEditing = true
        DispatchQueue.main.async {
            isEditorFocused = true
        }
    }

    private func commit() {
        let newContext = draftContext.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        isEditorFocused = false
        if newContext != context {
            onCommit(newContext)
        }
    }

    private func cancel() {
        draftContext = context
        isEditing = false
        isEditorFocused = false
    }
}
