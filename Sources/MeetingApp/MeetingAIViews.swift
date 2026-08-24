import MeetingAI
import MeetingDomain
import SwiftUI

struct MeetingAISettingsView: View {
    @EnvironmentObject private var aiController: MeetingAIController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RÉGLAGES")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                    Text("Intelligence artificielle")
                        .font(.title2.weight(.semibold))
                }
                Spacer()
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(22)

            Divider()

            Form {
                Section("Lanceur") {
                    LabeledContent("Raccourci global") {
                        AIShortcutRecorder(shortcut: aiController.shortcut) {
                            aiController.updateShortcut($0)
                        }
                        .frame(width: 180, height: 28)
                    }
                    Text("Ce raccourci ouvre les actions IA depuis n’importe quelle application.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Automatisations de fin de réunion") {
                    Toggle("Donner un nom si le titre n’a pas été modifié", isOn: $aiController.automaticallyGenerateTitle)
                    Toggle("Créer automatiquement un résumé", isOn: $aiController.automaticallyGenerateSummary)
                }

                Section("Codex headless") {
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
                    Text("Le transcript sélectionné est transmis à Codex pour ces traitements. Aucun fichier audio n’est envoyé.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)
        }
        .frame(width: 620, height: 540)
    }
}

struct MeetingAIPanelView: View {
    @EnvironmentObject private var aiController: MeetingAIController
    @EnvironmentObject private var meetingController: MeetingController
    @Environment(\.dismiss) private var dismiss
    @State private var selectedKind: MeetingAIJobKind = .summary

    private var meetingID: UUID? { meetingController.selectedMeetingID }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CODEX HEADLESS")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                    Text(meetingController.selectedMeeting?.title ?? "Actions IA")
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer()
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(22)

            Divider()

            HStack(spacing: 8) {
                actionTab(.summary, title: "Résumé", icon: "text.alignleft")
                actionTab(.questions, title: "Questions", icon: "questionmark.bubble")
                actionTab(.nextSteps, title: "Prochaines étapes", icon: "arrow.right.circle")
                Spacer()
            }
            .padding(16)

            Divider()

            Group {
                if let result = aiController.latestResult(for: selectedKind) {
                    ScrollView {
                        Text(aiController.displayText(for: result))
                            .font(.body)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
                    }
                } else if aiController.runningKinds.contains(selectedKind) {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Codex analyse le transcript…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: icon(for: selectedKind))
                            .font(.system(size: 34, weight: .light))
                        Text(emptyMessage(for: selectedKind))
                            .font(.headline)
                        Text("Le résultat sera conservé localement avec cette réunion.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay(alignment: .bottom) {
                if let error = aiController.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(.thinMaterial)
                        .accessibilityLabel("Erreur IA : \(error)")
                }
            }

            Divider()

            HStack {
                let segmentCount = meetingController.realtimeSegments.isEmpty
                    ? meetingController.segments.count
                    : meetingController.realtimeSegments.count
                Text("\(segmentCount) segment\(segmentCount > 1 ? "s" : "") exploitable\(segmentCount > 1 ? "s" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(aiController.latestResult(for: selectedKind) == nil ? "Lancer" : "Regénérer") {
                    runSelectedAction()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    meetingID == nil
                    || (meetingController.segments.isEmpty
                        && meetingController.realtimeSegments.isEmpty)
                    || aiController.runningKinds.contains(selectedKind)
                )
            }
            .padding(16)
        }
        .frame(width: 720, height: 560)
        .task { await aiController.loadResults(meetingID: meetingID) }
        .onChange(of: meetingID) {
            Task { await aiController.loadResults(meetingID: meetingID) }
        }
        .onChange(of: aiController.lastCompletedKind) {
            if let kind = aiController.lastCompletedKind, kind != .title {
                selectedKind = kind
            }
        }
    }

    private func actionTab(
        _ kind: MeetingAIJobKind,
        title: String,
        icon: String
    ) -> some View {
        Button {
            selectedKind = kind
        } label: {
            Label(title, systemImage: icon)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(selectedKind == kind ? Color.primary : Color.clear)
                .foregroundStyle(selectedKind == kind ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedKind == kind ? .isSelected : [])
    }

    private func runSelectedAction() {
        guard let meetingID else { return }
        aiController.run(selectedKind, meetingID: meetingID)
    }

    private func icon(for kind: MeetingAIJobKind) -> String {
        switch kind {
        case .summary: "text.alignleft"
        case .questions: "questionmark.bubble"
        case .nextSteps: "arrow.right.circle"
        case .title: "character.cursor.ibeam"
        }
    }

    private func emptyMessage(for kind: MeetingAIJobKind) -> String {
        switch kind {
        case .summary: "Aucun résumé généré"
        case .questions: "Aucune question proposée"
        case .nextSteps: "Aucune prochaine étape proposée"
        case .title: "Aucun titre proposé"
        }
    }
}
