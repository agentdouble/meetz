import CaptureCore
import MeetingDomain
import SwiftUI

struct MeetingRootView: View {
    @EnvironmentObject private var controller: MeetingController
    @EnvironmentObject private var aiController: MeetingAIController
    @AppStorage(MeetingPreferenceKeys.showsTranscriptPanelDuringRecording)
    private var showsTranscriptPanelDuringRecording = true
    @State private var isShowingVoiceProfiles = false
    @State private var meetingToDelete: MeetingRecord?

    var body: some View {
        HStack(spacing: 0) {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
            } detail: {
                if controller.isRecording, !showsTranscriptPanelDuringRecording {
                    CompactRecordingStatusView(
                        microphoneLevel: controller.microphoneLevel,
                        systemLevel: controller.systemLevel,
                        status: controller.status,
                        onOpenAssistant: aiController.openPanel,
                        onShowTranscript: {
                            showsTranscriptPanelDuringRecording = true
                        }
                    )
                } else {
                    transcriptView
                }
            }

            if aiController.isShowingPanel {
                Divider()
                MeetingAIPanelView()
                    .environmentObject(controller)
                    .environmentObject(aiController)
                    .frame(minWidth: 340, idealWidth: 390, maxWidth: 460)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(minWidth: 1_040, minHeight: 620)
        .animation(.easeInOut(duration: 0.18), value: aiController.isShowingPanel)
        .task {
            await controller.load()
            await aiController.loadResults(meetingID: controller.selectedMeetingID)
            await aiController.reconcileAutomaticTitles()
        }
        .sheet(isPresented: $isShowingVoiceProfiles) {
            VoiceProfilesView()
                .environmentObject(controller)
        }
        .sheet(isPresented: $aiController.isShowingSettings) {
            MeetingAISettingsView()
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
                .help("Discuter du transcript — \(aiController.shortcut.displayValue)")
                .accessibilityLabel("Ouvrir le chat du transcript")

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

            if controller.isLiveTranscriptSession {
                liveTranscriptContent
            } else if controller.storedSegmentsForDisplay.isEmpty {
                emptyState
            } else {
                storedTranscriptContent
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var liveTranscriptContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(controller.historicalSegmentsDuringLive) { segment in
                        transcriptSegmentView(segment)
                            .id(segment.id)
                    }

                    LiveTranscriptView(
                        segments: controller.realtimeSegments,
                        microphoneDraft: controller.microphoneDraft,
                        systemDraft: controller.systemDraft,
                        audioActivityStartedAt: controller.realtimeAudioActivityStartedAt,
                        lastTextAt: controller.lastRealtimeTextAt,
                        processingLag: controller.realtimeProcessingLag
                    )
                    .id("live-transcript")
                }
                .padding(32)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                proxy.scrollTo("live-transcript", anchor: .bottom)
            }
            .onChange(of: controller.realtimeSegments.map(\.text)) {
                proxy.scrollTo("live-transcript", anchor: .bottom)
            }
            .onChange(of: controller.microphoneDraft) {
                proxy.scrollTo("live-transcript", anchor: .bottom)
            }
            .onChange(of: controller.systemDraft) {
                proxy.scrollTo("live-transcript", anchor: .bottom)
            }
        }
    }

    private var storedTranscriptContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(controller.storedSegmentsForDisplay) { segment in
                        transcriptSegmentView(segment)
                            .id(segment.id)
                    }
                }
                .padding(32)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: controller.storedSegmentsForDisplay.count) {
                if let last = controller.storedSegmentsForDisplay.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func transcriptSegmentView(_ segment: TranscriptSegment) -> some View {
        TranscriptSegmentView(segment: segment) { displayName in
            controller.renameSpeaker(
                segment: segment,
                displayName: displayName
            )
        }
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

                Button {
                    showsTranscriptPanelDuringRecording = false
                } label: {
                    Image(systemName: "rectangle.compress.vertical")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Fermer le panneau de transcription")
                .accessibilityLabel("Fermer le panneau de transcription pendant l’enregistrement")
            }

            if controller.selectedMeetingID != nil {
                Button {
                    aiController.openPanel()
                } label: {
                    Label("Discuter", systemImage: "bubble.left.and.bubble.right")
                }
                .buttonStyle(.borderless)
                .help("Discuter du transcript")
            }

            if controller.canResumeSelectedMeeting {
                Button {
                    controller.resumeSelectedMeeting()
                } label: {
                    Label("Reprendre", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reprendre cette réunion et ajouter la suite au transcript")
                .accessibilityLabel("Reprendre la réunion depuis ce transcript")
            }

            phaseIndicator
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
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
