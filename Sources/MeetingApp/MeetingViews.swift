import CaptureCore
import MeetingDomain
import SwiftUI

struct MeetingRootView: View {
    @EnvironmentObject private var controller: MeetingController
    @EnvironmentObject private var aiController: MeetingAIController
    @State private var isShowingVoiceProfiles = false
    @State private var meetingToDelete: MeetingRecord?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            transcriptView
        }
        .frame(minWidth: 940, minHeight: 620)
        .task {
            await controller.load()
            await aiController.loadResults(meetingID: controller.selectedMeetingID)
            await aiController.resumePendingJobs()
        }
        .sheet(isPresented: $isShowingVoiceProfiles) {
            VoiceProfilesView()
                .environmentObject(controller)
        }
        .sheet(isPresented: $aiController.isShowingSettings) {
            MeetingAISettingsView()
                .environmentObject(aiController)
        }
        .sheet(isPresented: $aiController.isShowingPanel) {
            MeetingAIPanelView()
                .environmentObject(controller)
                .environmentObject(aiController)
        }
        .onChange(of: controller.selectedMeetingID) {
            Task { await aiController.loadResults(meetingID: controller.selectedMeetingID) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingDidFinish)) { notification in
            if let meetingID = notification.object as? UUID {
                aiController.runAutomaticJobs(meetingID: meetingID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingAIDidUpdateMeeting)) { _ in
            Task { await controller.refreshAfterAIUpdate() }
        }
        .confirmationDialog(
            "Supprimer cette reunion ?",
            isPresented: Binding(
                get: { meetingToDelete != nil },
                set: { if !$0 { meetingToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: meetingToDelete
        ) { meeting in
            Button("Supprimer definitivement", role: .destructive) {
                controller.deleteMeeting(id: meeting.id)
                meetingToDelete = nil
            }
            Button("Annuler", role: .cancel) {
                meetingToDelete = nil
            }
        } message: { _ in
            Text("Le transcript et ses segments seront supprimes. Les signatures vocales connues seront conservees.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MEETING")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(2)
                Spacer()
                Button {
                    aiController.openPanel()
                } label: {
                    Image(systemName: "sparkles")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(controller.selectedMeetingID == nil)
                .help("Ouvrir les actions IA — \(aiController.shortcut.displayValue)")
                .accessibilityLabel("Ouvrir les actions IA")

                Button {
                    aiController.isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Réglages")
                .accessibilityLabel("Ouvrir les réglages")
            }
            .padding(18)

            List(selection: Binding(
                get: { controller.selectedMeetingID },
                set: { controller.selectMeeting($0) }
            )) {
                Section("Transcripts") {
                    ForEach(controller.meetings) { meeting in
                        MeetingListRow(
                            meeting: meeting,
                            isSelected: controller.selectedMeetingID == meeting.id,
                            canDelete: controller.canDeleteSelectedMeeting,
                            onRename: { title in
                                controller.updateMeetingMetadata(
                                    id: meeting.id,
                                    title: title,
                                    context: meeting.context,
                                    marksTitleAsUser: true
                                )
                            },
                            onDelete: {
                                meetingToDelete = meeting
                            }
                        )
                            .tag(meeting.id)
                            .contextMenu {
                                Button("Supprimer", role: .destructive) {
                                    meetingToDelete = meeting
                                }
                                .disabled(!controller.canDeleteSelectedMeeting)
                            }
                    }
                }
            }
            .listStyle(.sidebar)

            Button {
                isShowingVoiceProfiles = true
            } label: {
                HStack {
                    Label("Voix connues", systemImage: "person.2")
                    Spacer()
                    Text("\(controller.voiceProfiles.count)")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .disabled(controller.voiceProfiles.isEmpty || controller.isBusy)
            .padding(.horizontal, 14)
            .padding(.top, 8)

            Button(action: toggleMeeting) {
                Label(
                    controller.isRecording ? "Arreter" : "Nouvelle reunion",
                    systemImage: controller.isRecording ? "stop.fill" : "waveform"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .foregroundStyle(controller.isRecording ? Color.primary : Color(nsColor: .windowBackgroundColor))
            .background(controller.isRecording ? Color.primary.opacity(0.08) : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.primary, lineWidth: controller.isRecording ? 1 : 0)
            }
            .disabled(controller.isBusy)
            .padding(14)
        }
        .background(Color.primary.opacity(0.025))
    }

    private var transcriptView: some View {
        VStack(spacing: 0) {
            statusHeader
            if let meeting = controller.selectedMeeting {
                meetingContextBar(meeting)
            }
            Divider()

            if controller.segments.isEmpty,
               controller.realtimeSegments.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            if controller.realtimeSegments.isEmpty {
                                ForEach(controller.segments) { segment in
                                    TranscriptSegmentView(segment: segment) { displayName in
                                        controller.renameSpeaker(
                                            segment: segment,
                                            displayName: displayName
                                        )
                                    }
                                        .id(segment.id)
                                }
                            } else {
                                ForEach(controller.realtimeSegments) { segment in
                                    RealtimeTranscriptSegmentView(segment: segment)
                                        .id(segment.id)
                                }
                            }
                        }
                        .padding(32)
                        .frame(maxWidth: 820, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: controller.segments.count) {
                        if let last = controller.segments.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    .onChange(of: controller.realtimeSegments.last?.text) {
                        if let last = controller.realtimeSegments.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusHeader: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(controller.isRecording ? "REUNION EN DIRECT" : "TRANSCRIPT LOCAL")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
                if let meeting = controller.selectedMeeting {
                    InlineEditableTitle(
                        value: meeting.title,
                        placeholder: "Nom de la réunion",
                        font: .title2.weight(.semibold),
                        lineLimit: 1,
                        accessibilityLabel: "Modifier le titre de la réunion"
                    ) { title in
                        controller.updateMeetingMetadata(
                            id: meeting.id,
                            title: title,
                            context: meeting.context,
                            marksTitleAsUser: true
                        )
                    }
                    .frame(maxWidth: 620, alignment: .leading)
                } else {
                    Text(controller.status)
                        .font(.title2.weight(.semibold))
                }
                if controller.selectedMeeting != nil {
                    Text(controller.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if controller.isRecording || controller.isEnrolling {
                CompactLevel(title: "MIC", level: controller.microphoneLevel)
            }
            if controller.isRecording {
                CompactLevel(title: "MAC", level: controller.systemLevel)
            }

            if let meetingID = controller.selectedMeetingID {
                aiHeaderAction(
                    title: "Questions",
                    systemImage: "questionmark.bubble",
                    kind: .questions,
                    meetingID: meetingID
                )
                aiHeaderAction(
                    title: "Prochaines étapes",
                    systemImage: "arrow.right.circle",
                    kind: .nextSteps,
                    meetingID: meetingID
                )
            }

            phaseIndicator
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private func aiHeaderAction(
        title: String,
        systemImage: String,
        kind: MeetingAIJobKind,
        meetingID: UUID
    ) -> some View {
        Button {
            aiController.run(kind, meetingID: meetingID)
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(
            (controller.segments.isEmpty && controller.realtimeSegments.isEmpty)
                || aiController.runningKinds.contains(kind)
        )
        .help(title)
        .accessibilityLabel(title)
    }

    private func meetingContextBar(_ meeting: MeetingRecord) -> some View {
        InlineEditableMeetingContext(context: meeting.context) { context in
            controller.updateMeetingMetadata(
                id: meeting.id,
                title: meeting.title,
                context: context
            )
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var phaseIndicator: some View {
        switch controller.phase {
        case .preparing:
            if let progress = controller.preparationProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 92)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        case .enrolling:
            if let progress = controller.voiceEnrollmentProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 92)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        case .stopping:
            ProgressView()
                .controlSize(.small)
        case .recording:
            Label("ACTIF", systemImage: "circle.fill")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        case let .failed(message):
            Image(systemName: "exclamationmark.triangle")
                .help(message)
        case .idle:
            EmptyView()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: controller.isRecording ? "waveform" : "text.alignleft")
                .font(.system(size: 38, weight: .light))
            Text(controller.isRecording ? "La transcription va apparaitre ici" : "Aucun transcript selectionne")
                .font(.title3.weight(.medium))
            Text(controller.isRecording
                 ? "Parlez ou lancez une reunion Teams, Webex ou navigateur."
                 : "Demarrez une reunion pour creer votre premier transcript local.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func toggleMeeting() {
        if controller.isRecording {
            controller.stopMeeting()
        } else {
            controller.startMeeting()
        }
    }

}

private struct VoiceProfilesView: View {
    @EnvironmentObject private var controller: MeetingController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VOIX CONNUES")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                    Text("Signatures locales")
                        .font(.title2.weight(.semibold))
                }
                Spacer()
                Button("Fermer") { dismiss() }
            }
            .padding(22)

            Divider()

            List(controller.voiceProfiles, id: \.id) { profile in
                VoiceProfileEditorRow(profile: profile)
            }
            .listStyle(.inset)

            Text("Seul le centroide numerique est conserve. Aucun audio n'est stocke.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(16)
        }
        .frame(width: 520, height: 420)
    }
}

private struct VoiceProfileEditorRow: View {
    @EnvironmentObject private var controller: MeetingController
    let profile: VoiceProfile
    @State private var displayName: String
    @State private var confirmsDeletion = false

    init(profile: VoiceProfile) {
        self.profile = profile
        _displayName = State(initialValue: profile.displayName)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: profile.id == "local-user" ? "person.crop.circle.fill" : "waveform.circle")
                .font(.title2)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Nom de la voix", text: $displayName)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .onSubmit(saveName)
                Text("\(profile.sampleCount) echantillon\(profile.sampleCount > 1 ? "s" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Enregistrer", action: saveName)
                .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button(role: .destructive) {
                confirmsDeletion = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Oublier cette voix")
        }
        .padding(.vertical, 6)
        .confirmationDialog(
            "Oublier \(profile.displayName) ?",
            isPresented: $confirmsDeletion
        ) {
            Button("Oublier cette voix", role: .destructive) {
                controller.forgetVoiceProfile(id: profile.id)
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("La signature numerique sera supprimee. Les anciens transcripts ne seront pas modifies.")
        }
    }

    private func saveName() {
        controller.renameVoiceProfile(id: profile.id, displayName: displayName)
    }
}

private struct MeetingListRow: View {
    let meeting: MeetingRecord
    let isSelected: Bool
    let canDelete: Bool
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    init(
        meeting: MeetingRecord,
        isSelected: Bool,
        canDelete: Bool,
        onRename: @escaping (String) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.meeting = meeting
        self.isSelected = isSelected
        self.canDelete = canDelete
        self.onRename = onRename
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                InlineEditableTitle(
                    value: meeting.title,
                    placeholder: "Nom de la réunion",
                    font: .callout.weight(.medium),
                    lineLimit: 2,
                    accessibilityLabel: "Modifier le titre de \(meeting.title)"
                ) { title in
                    onRename(title)
                }
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 2)

            if showsActions {
                sidebarAction(
                    systemImage: "trash",
                    label: "Supprimer la réunion",
                    action: onDelete
                )
                .disabled(!canDelete)
                .padding(.top, 1)
            }
        }
        .padding(.vertical, 4)
        .onHover { isHovered = $0 }
    }

    private var showsActions: Bool {
        isSelected || isHovered
    }

    private func sidebarAction(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct TranscriptSegmentView: View {
    let segment: TranscriptSegment
    let onRenameSpeaker: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(formatTime(segment.startTime))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)

            VStack(alignment: .leading, spacing: 6) {
                EditableSpeakerLabel(
                    displayName: segment.speakerName,
                    onRename: onRenameSpeaker
                )
                Text(segment.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .lineSpacing(3)
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}

private struct EditableSpeakerLabel: View {
    let displayName: String
    let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var draftName: String
    @FocusState private var isFieldFocused: Bool

    init(displayName: String, onRename: @escaping (String) -> Void) {
        self.displayName = displayName
        self.onRename = onRename
        _draftName = State(initialValue: displayName)
    }

    var body: some View {
        Group {
            if isEditing {
                HStack(spacing: 8) {
                    TextField("Nom de l'interlocuteur", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 180)
                        .focused($isFieldFocused)
                        .onSubmit(commit)

                    Button(action: commit) {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.plain)
                    .disabled(normalizedDraftName.isEmpty)
                    .help("Enregistrer le nom")
                    .accessibilityLabel("Enregistrer le nom de l'interlocuteur")

                    Button(action: cancel) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("Annuler")
                    .accessibilityLabel("Annuler le renommage")
                }
                .onExitCommand(perform: cancel)
                .onAppear { isFieldFocused = true }
            } else {
                Button(action: beginEditing) {
                    HStack(spacing: 6) {
                        Text(displayName.uppercased())
                            .tracking(0.8)
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .help("Renommer cet interlocuteur")
                .accessibilityLabel("Renommer l'interlocuteur \(displayName)")
            }
        }
        .onChange(of: displayName) {
            if !isEditing { draftName = displayName }
        }
    }

    private var normalizedDraftName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginEditing() {
        draftName = displayName
        isEditing = true
    }

    private func commit() {
        guard !normalizedDraftName.isEmpty else { return }
        onRename(normalizedDraftName)
        isEditing = false
    }

    private func cancel() {
        draftName = displayName
        isEditing = false
    }
}

private struct RealtimeTranscriptSegmentView: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(formatTime(segment.startTime))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(segment.speakerName.uppercased())
                        .tracking(0.8)
                    Text("DIRECT")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))

                Text(segment.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .lineSpacing(3)
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}

private struct CompactLevel: View {
    let title: String
    let level: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(Color.primary)
                        .frame(width: max(1, proxy.size.width * level))
                }
            }
            .frame(width: 52, height: 5)
        }
    }
}
