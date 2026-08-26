import MeetingAI
import MeetingDomain
import SwiftUI

struct MeetingAISettingsView: View {
    @EnvironmentObject private var aiController: MeetingAIController
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MeetingPreferenceKeys.showsTranscriptPanelDuringRecording)
    private var showsTranscriptPanelDuringRecording = true

    private let modelOptions = [
        ("", "Configuration Codex"),
        ("gpt-5.3-codex-spark", "GPT-5.3 Codex Spark — très rapide"),
        ("gpt-5.6-luna", "GPT-5.6 Luna — rapide"),
        ("gpt-5.6-terra", "GPT-5.6 Terra — équilibré"),
        ("gpt-5.6-sol", "GPT-5.6 Sol — qualité"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RÉGLAGES")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                    Text("Préférences")
                        .font(.title2.weight(.semibold))
                }
                Spacer()
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(22)

            Divider()

            Form {
                Section("Affichage") {
                    Toggle(
                        "Afficher le panneau de transcription pendant l’enregistrement",
                        isOn: $showsTranscriptPanelDuringRecording
                    )
                    Text("Quand il est fermé, un indicateur compact reste visible. La transcription et la sauvegarde locale continuent, puis le panneau complet réapparaît à l’arrêt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Lanceur") {
                    LabeledContent("Raccourci global") {
                        AIShortcutRecorder(shortcut: aiController.shortcut) {
                            aiController.updateShortcut($0)
                        }
                        .frame(width: 180, height: 28)
                    }
                    Text("Ce raccourci ouvre le chat du transcript depuis n’importe quelle application.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Automatisations de fin de réunion") {
                    Toggle("Donner un nom si le titre n’a pas été modifié", isOn: $aiController.automaticallyGenerateTitle)
                    Toggle("Créer automatiquement un résumé", isOn: $aiController.automaticallyGenerateSummary)
                }

                Section("Codex headless") {
                    Picker("Modèle", selection: $aiController.codexModel) {
                        ForEach(modelOptions, id: \.0) { value, label in
                            Text(label).tag(value)
                        }
                    }

                    Picker("Effort", selection: $aiController.codexReasoningEffort) {
                        ForEach(CodexReasoningEffort.allCases) { effort in
                            Text(effort.displayName).tag(effort)
                        }
                    }

                    TextField("Chemin vers codex", text: $aiController.codexExecutablePath)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Label(
                            aiController.isCodexAvailable ? "Codex disponible" : "Codex introuvable",
                            systemImage: aiController.isCodexAvailable ? "checkmark.circle" : "exclamationmark.triangle"
                        )
                        .foregroundStyle(aiController.isCodexAvailable ? .primary : .secondary)
                        Spacer()
                        Button("Détecter", action: aiController.detectCodexAgain)
                    }
                    Text("Le modèle et l’effort s’appliquent au chat et aux traitements automatiques. Seul le texte du transcript est transmis à Codex, jamais l’audio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)
        }
        .frame(width: 620, height: 620)
    }
}

struct MeetingAIPanelView: View {
    @EnvironmentObject private var aiController: MeetingAIController
    @EnvironmentObject private var meetingController: MeetingController
    @State private var draft = ""

    private var meetingID: UUID? { meetingController.selectedMeetingID }
    private var hasTranscript: Bool {
        !meetingController.segments.isEmpty || !meetingController.realtimeSegments.isEmpty
    }

    private let quickActions = [
        ChatQuickAction(
            title: "Résumé",
            icon: "text.alignleft",
            prompt: "Résume cette réunion en faisant ressortir son objectif, les points importants et les conclusions."
        ),
        ChatQuickAction(
            title: "Prochaines étapes",
            icon: "arrow.right.circle",
            prompt: "Liste les prochaines étapes concrètes. N’attribue un responsable ou une échéance que si le transcript les mentionne."
        ),
        ChatQuickAction(
            title: "Questions à poser",
            icon: "questionmark.bubble",
            prompt: "Propose les questions utiles à poser pour clarifier les zones floues, les décisions et les risques."
        ),
        ChatQuickAction(
            title: "Problèmes à résoudre",
            icon: "exclamationmark.bubble",
            prompt: "Identifie les problèmes, blocages, risques ou désaccords qui restent à résoudre d’après le transcript."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            Divider()
            quickActionGrid
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await aiController.loadResults(meetingID: meetingID) }
        .onChange(of: meetingID) {
            draft = ""
            Task { await aiController.loadResults(meetingID: meetingID) }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("Assistant")
                .font(.title2.weight(.semibold))
            Spacer()
            Button(action: aiController.closePanel) {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Fermer le chat")
            .accessibilityLabel("Fermer le chat")
        }
        .padding(18)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if aiController.chatMessages.isEmpty && !aiController.isChatRunning {
                        chatEmptyState
                    } else {
                        ForEach(aiController.chatMessages) { message in
                            ChatMessageBubble(message: message)
                                .id(message.id)
                        }
                    }

                    if aiController.isChatRunning {
                        HStack(spacing: 9) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Codex analyse le transcript…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.045))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .id("chat-progress")
                        .accessibilityElement(children: .combine)
                    }

                    if let error = aiController.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.035))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(16)
            }
            .onChange(of: aiController.chatMessages.map(\.id)) {
                if let last = aiController.chatMessages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: aiController.isChatRunning) {
                if aiController.isChatRunning {
                    withAnimation { proxy.scrollTo("chat-progress", anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatEmptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 30, weight: .light))
            Text(meetingID == nil ? "Sélectionne une réunion" : "Que veux-tu savoir ?")
                .font(.headline)
            Text(
                meetingID == nil
                    ? "Le chat utilisera le transcript sélectionné."
                    : "Pose une question libre ou lance l’une des analyses ci-dessous."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
    }

    private var quickActionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(quickActions) { action in
                Button {
                    send(action.prompt)
                } label: {
                    Label(action.title, systemImage: action.icon)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(Color.primary.opacity(0.045))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Question sur cette réunion…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.045))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onSubmit { sendDraft() }
                .accessibilityLabel("Question sur le transcript")

            Button(action: sendDraft) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .background(Color.primary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Envoyer")
            .accessibilityLabel("Envoyer la question")
        }
        .padding(14)
    }

    private var canSend: Bool {
        meetingID != nil && hasTranscript && !aiController.isChatRunning && aiController.isCodexAvailable
    }

    private func sendDraft() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        send(question)
    }

    private func send(_ question: String) {
        guard let meetingID, canSend else { return }
        aiController.sendChat(question, meetingID: meetingID)
    }
}

private struct ChatQuickAction: Identifiable {
    let title: String
    let icon: String
    let prompt: String

    var id: String { title }
}

private struct ChatMessageBubble: View {
    let message: MeetingAIChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 42) }
            Text(message.content)
                .font(.callout)
                .lineSpacing(3)
                .textSelection(.enabled)
                .foregroundStyle(message.role == .user ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(message.role == .user ? Color.primary : Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if message.role == .assistant { Spacer(minLength: 28) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.role == .user ? "Vous : \(message.content)" : "Assistant : \(message.content)")
    }
}

private extension CodexReasoningEffort {
    var displayName: String {
        switch self {
        case .inherit: "Effort Codex"
        case .low: "Faible"
        case .medium: "Moyen"
        case .high: "Élevé"
        case .xhigh: "Très élevé"
        case .max: "Maximum"
        }
    }
}
