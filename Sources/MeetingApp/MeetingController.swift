import AppKit
import AudioJournal
import CaptureCore
import FluidAudioAdapter
import Foundation
import MeetingDomain
import OSLog
import ScreenCaptureAdapter
import TranscriptStore
import TranscriptionCore

@MainActor
final class MeetingController: ObservableObject {
    private struct MeetingSpeakerKey: Hashable {
        let meetingID: UUID
        let speakerID: String
    }

    private let logger = Logger(subsystem: "com.jeremy.meeting", category: "MeetingController")

    enum Phase: Equatable {
        case idle
        case preparing
        case enrolling
        case recording
        case stopping
        case failed(String)
    }

    @Published private(set) var meetings: [MeetingRecord] = []
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var realtimeSegments: [TranscriptSegment] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "Pret"
    @Published private(set) var areModelsReady = false
    @Published private(set) var preparationProgress: Double?
    @Published private(set) var voiceEnrollmentProgress: Double?
    @Published private(set) var hasVoiceProfile = false
    @Published private(set) var voiceProfiles: [VoiceProfile] = []
    @Published private(set) var microphoneLevel = 0.0
    @Published private(set) var systemLevel = 0.0
    @Published private(set) var microphoneDraft = ""
    @Published private(set) var microphoneDraftSpeaker = "Micro du Mac"
    @Published private(set) var systemDraft = ""
    @Published private(set) var realtimeAudioActivityStartedAt: Date?
    @Published private(set) var lastRealtimeTextAt: Date?
    @Published private(set) var realtimeProcessingLag: TimeInterval = 0
    @Published var selectedMeetingID: UUID?

    private let captureSource: any AudioCaptureSource
    private let store: SQLiteTranscriptStore?
    private let audioJournal: DurableAudioJournal?
    private var engine: FluidAudioBatchTranscriptionEngine?
    private var previewEngine: FluidAudioRealtimePreviewEngine?
    private var currentMeeting: MeetingRecord?
    private var microphoneAudioContinuation: AsyncStream<AudioChunk>.Continuation?
    private var systemAudioContinuation: AsyncStream<AudioChunk>.Continuation?
    private var microphonePreviewContinuation: AsyncStream<AudioChunk>.Continuation?
    private var systemPreviewContinuation: AsyncStream<AudioChunk>.Continuation?
    private var microphoneJournalTask: Task<Void, Never>?
    private var systemJournalTask: Task<Void, Never>?
    private var microphonePreviewTask: Task<Void, Never>?
    private var systemPreviewTask: Task<Void, Never>?
    private var deferredAudioBlockQueue: DeferredAudioBlockQueue?
    private var realtimeSegmenters: [AudioInputKind: RealtimeTranscriptSegmenter] = [:]
    private var realtimePersistenceTask: Task<Void, Never>?
    private var pipelineFailureMessage: String?
    private var didRecoverInterruptedMeetings = false
    private var enrollmentContinuation: AsyncStream<AudioChunk>.Continuation?
    private var enrollmentTask: Task<Void, Never>?
    private var profileNameOverrides: [String: String] = [:]
    private var meetingSpeakerNameOverrides: [MeetingSpeakerKey: String] = [:]
    private var realtimePreviewCounts: [AudioInputKind: Int] = [:]
    private var realtimeProcessedDurations: [AudioInputKind: TimeInterval] = [:]
    private var realtimeCaptureStartedAt: Date?
    private var didLogRealtimeLagWarning = false

    init(
        captureSource: any AudioCaptureSource = ScreenCaptureAudioSource()
    ) {
        self.captureSource = captureSource
        do {
            let store = try SQLiteTranscriptStore()
            let audioJournal = try DurableAudioJournal()
            self.store = store
            self.audioJournal = audioJournal
        } catch {
            self.store = nil
            self.audioJournal = nil
            phase = .failed(error.localizedDescription)
            status = "Base locale indisponible"
        }
    }

    var isRecording: Bool { phase == .recording }
    var isLiveTranscriptSession: Bool { phase == .recording || phase == .stopping }
    var isEnrolling: Bool { phase == .enrolling }
    var isBusy: Bool { phase == .preparing || phase == .enrolling || phase == .stopping }
    var canManageVoiceProfile: Bool {
        phase == .idle || isFailed || phase == .enrolling
    }
    var selectedMeeting: MeetingRecord? {
        meetings.first { $0.id == selectedMeetingID }
    }
    var canDeleteSelectedMeeting: Bool { currentMeeting == nil && !isBusy }
    var canResumeSelectedMeeting: Bool {
        currentMeeting == nil
            && !isBusy
            && selectedMeeting?.state == .completed
    }
    var historicalSegmentsDuringLive: [TranscriptSegment] {
        guard !realtimeSegments.isEmpty else { return segments }
        return ExploitableTranscriptSelection.preferredSegments(
            from: segments + realtimeSegments
        ).filter { $0.source == .canonical }
    }
    var storedSegmentsForDisplay: [TranscriptSegment] {
        ExploitableTranscriptSelection.preferredSegments(
            from: segments + realtimeSegments
        )
    }

    func load() async {
        if !didRecoverInterruptedMeetings {
            didRecoverInterruptedMeetings = true
            do {
                try await store?.recoverInterruptedMeetings()
                voiceProfiles = try await store?.voiceProfiles() ?? []
                hasVoiceProfile = voiceProfiles.contains { $0.id == "local-user" }
                try await recoverPendingAudio()
            } catch {
                phase = .failed(error.localizedDescription)
                status = "Recuperation des transcripts interrompus impossible"
            }
        }
        await reloadMeetings()
        if selectedMeetingID == nil {
            selectedMeetingID = meetings.first?.id
        }
        await loadSelectedMeeting()
        if currentMeeting == nil, !areModelsReady, phase != .preparing {
            await preloadTranscriptionEngines()
        }
    }

    func selectMeeting(_ id: UUID?) {
        selectedMeetingID = id
        Task { await loadSelectedMeeting() }
    }

    func startMeeting() {
        beginMeeting(resuming: nil)
    }

    func resumeSelectedMeeting() {
        guard canResumeSelectedMeeting, let selectedMeeting else { return }
        beginMeeting(resuming: selectedMeeting)
    }

    private func beginMeeting(resuming meetingToResume: MeetingRecord?) {
        guard phase == .idle || isFailed else { return }
        guard let store, let audioJournal else {
            phase = .failed("Le stockage local n'est pas disponible.")
            return
        }

        phase = .preparing
        logger.info("Meeting preparation started resumed=\(meetingToResume != nil, privacy: .public)")
        status = meetingToResume == nil
            ? "Demarrage de la capture..."
            : "Preparation de la reprise..."
        preparationProgress = nil
        microphoneDraft = ""
        systemDraft = ""
        realtimeAudioActivityStartedAt = nil
        lastRealtimeTextAt = nil
        realtimeProcessingLag = 0
        realtimePreviewCounts = [:]
        realtimeProcessedDurations = [:]
        realtimeCaptureStartedAt = nil
        didLogRealtimeLagWarning = false
        realtimeSegments = []
        if meetingToResume == nil {
            segments = []
        }

        Task {
            do {
                let meeting: MeetingRecord
                let timeOffset: TimeInterval
                if let meetingToResume {
                    let storedSegments = try await store.segments(meetingID: meetingToResume.id)
                    meeting = try await store.resumeMeeting(id: meetingToResume.id)
                    timeOffset = Self.resumeOffset(from: storedSegments)
                    segments = storedSegments.filter { $0.source == .canonical }
                    if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
                        meetings[index] = meeting
                    }
                } else {
                    meeting = try await store.createMeeting()
                    timeOffset = 0
                    meetings.insert(meeting, at: 0)
                }

                currentMeeting = meeting
                selectedMeetingID = meeting.id
                realtimeSegmenters = [
                    .microphone: RealtimeTranscriptSegmenter(
                        meetingID: meeting.id,
                        input: .microphone,
                        timeOffset: timeOffset
                    ),
                    .system: RealtimeTranscriptSegmenter(
                        meetingID: meeting.id,
                        input: .system,
                        timeOffset: timeOffset
                    ),
                ]

                let (_, previewEngine) = try await preparedTranscriptionEngines()
                try await previewEngine.start { [weak self] preview in
                    Task { @MainActor [weak self] in
                        self?.acceptRealtimePreview(preview)
                    }
                }
                let audioFanout = configureAudioPipeline(
                    meetingID: meeting.id,
                    journal: audioJournal,
                    previewEngine: previewEngine,
                    timeOffset: timeOffset
                )

                try await captureSource.start { [weak self] event in
                    switch event {
                    case let .samples(chunk):
                        audioFanout.yield(chunk)
                    case .level, .stopped:
                        Task { @MainActor [weak self] in
                            self?.acceptCaptureEvent(event)
                        }
                    }
                }

                realtimeCaptureStartedAt = Date()
                phase = .recording
                status = meetingToResume == nil
                    ? "Transcription temps reel · sauvegarde locale robuste"
                    : "Reunion reprise à \(Self.formatTimestamp(timeOffset)) · sauvegarde locale"
                preparationProgress = nil
                logger.info("Meeting capture and transcription active")
            } catch {
                await failCurrentMeeting(error)
            }
        }
    }

    func startVoiceEnrollment() {
        guard phase == .idle || isFailed, let store else { return }

        phase = .enrolling
        logger.info("Voice enrollment started")
        status = "Parlez naturellement pendant quelques secondes..."
        voiceEnrollmentProgress = 0
        microphoneLevel = 0
        let collector = VoiceEnrollmentSession()
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        enrollmentContinuation = continuation

        enrollmentTask = Task {
            do {
                try await captureSource.start { [weak self] event in
                    switch event {
                    case let .samples(chunk) where chunk.input == .microphone:
                        continuation.yield(chunk)
                    case .level, .stopped:
                        if case .stopped = event {
                            continuation.finish()
                        }
                        Task { @MainActor [weak self] in
                            self?.acceptCaptureEvent(event)
                        }
                    case .samples:
                        break
                    }
                }

                for await chunk in stream {
                    try Task.checkCancellation()
                    let progress = await collector.append(chunk)
                    voiceEnrollmentProgress = progress
                    status = "Enregistrement de votre voix — \(Int((progress * 100).rounded())) %"
                    if progress >= 1 { break }
                }

                try Task.checkCancellation()
                await captureSource.stop()
                continuation.finish()

                let samples = await collector.samples()
                status = "Creation de l'empreinte vocale locale..."
                voiceEnrollmentProgress = nil
                let identityEngine = try await CampPlusVoiceIdentityEngine.load { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.voiceEnrollmentProgress = progress.fractionCompleted
                    }
                }
                let profile = try await identityEngine.createProfile(
                    samples: samples,
                    sampleRate: VoiceEnrollmentSession.targetSampleRate
                )
                try await store.saveVoiceProfile(profile)

                upsertVoiceProfile(profile)
                hasVoiceProfile = true
                phase = .idle
                status = "Empreinte vocale enregistree localement"
                logger.info("Voice enrollment completed; numerical profile saved")
            } catch is CancellationError {
                await captureSource.stop()
                phase = .idle
                status = "Enregistrement de la voix annule"
            } catch {
                logger.error("Voice enrollment failed: \(error.localizedDescription, privacy: .public)")
                await captureSource.stop()
                phase = .failed(error.localizedDescription)
                status = "Creation de l'empreinte impossible"
            }

            enrollmentContinuation = nil
            enrollmentTask = nil
            voiceEnrollmentProgress = nil
            microphoneLevel = 0
        }
    }

    func cancelVoiceEnrollment() {
        guard phase == .enrolling else { return }
        enrollmentTask?.cancel()
        enrollmentContinuation?.finish()
    }

    func renameVoiceProfile(id: String, displayName: String) {
        guard let store else { return }
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }

        profileNameOverrides[id] = normalizedName
        replaceVisibleSpeakerName(speakerID: id, displayName: normalizedName)
        Task {
            do {
                try await store.renameVoiceProfile(id: id, displayName: normalizedName)
                voiceProfiles = try await store.voiceProfiles()
                status = "Profil vocal renomme"
            } catch {
                profileNameOverrides.removeValue(forKey: id)
                await reloadVisibleSegments()
                logger.error("Voice profile rename failed: \(error.localizedDescription, privacy: .public)")
                status = "Renommage du profil impossible"
            }
        }
    }

    func renameSpeaker(segment: TranscriptSegment, displayName: String) {
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, let store else { return }

        if voiceProfiles.contains(where: { $0.id == segment.speakerID }) {
            renameVoiceProfile(id: segment.speakerID, displayName: normalizedName)
            return
        }

        let key = MeetingSpeakerKey(
            meetingID: segment.meetingID,
            speakerID: segment.speakerID
        )
        meetingSpeakerNameOverrides[key] = normalizedName
        replaceVisibleSpeakerName(
            speakerID: segment.speakerID,
            displayName: normalizedName,
            meetingID: segment.meetingID
        )

        Task {
            do {
                try await store.renameSpeaker(
                    meetingID: segment.meetingID,
                    speakerID: segment.speakerID,
                    displayName: normalizedName
                )
                status = "Interlocuteur renomme"
            } catch {
                meetingSpeakerNameOverrides.removeValue(forKey: key)
                await reloadVisibleSegments()
                logger.error("Speaker rename failed: \(error.localizedDescription, privacy: .public)")
                status = "Renommage de l'interlocuteur impossible"
            }
        }
    }

    func forgetVoiceProfile(id: String) {
        guard let store else { return }
        Task {
            do {
                try await store.deleteVoiceProfile(id: id)
                voiceProfiles.removeAll { $0.id == id }
                if id == "local-user" {
                    hasVoiceProfile = false
                }
                status = "Profil vocal oublie"
            } catch {
                phase = .failed(error.localizedDescription)
                status = "Suppression du profil impossible"
            }
        }
    }

    func updateMeetingMetadata(
        id: UUID,
        title: String,
        context: String,
        marksTitleAsUser: Bool = false
    ) {
        guard let store else { return }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return }
        let normalizedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)

        if let index = meetings.firstIndex(where: { $0.id == id }) {
            meetings[index].title = normalizedTitle
            if marksTitleAsUser {
                meetings[index].titleOrigin = .user
            }
            meetings[index].context = normalizedContext
        }
        if currentMeeting?.id == id {
            currentMeeting?.title = normalizedTitle
            if marksTitleAsUser {
                currentMeeting?.titleOrigin = .user
            }
            currentMeeting?.context = normalizedContext
        }

        Task {
            do {
                try await store.updateMeetingMetadata(
                    id: id,
                    title: normalizedTitle,
                    context: normalizedContext,
                    titleOrigin: marksTitleAsUser ? .user : nil
                )
                status = "Informations de la reunion enregistrees"
                await reloadMeetings()
            } catch {
                logger.error("Meeting metadata update failed: \(error.localizedDescription, privacy: .public)")
                status = "Modification de la reunion impossible"
                await reloadMeetings()
            }
        }
    }

    func deleteMeeting(id: UUID) {
        guard currentMeeting == nil, let store else { return }
        Task {
            do {
                try await store.deleteMeeting(id: id)
                try await audioJournal?.discardMeeting(id)
                if selectedMeetingID == id {
                    selectedMeetingID = nil
                    segments = []
                    realtimeSegments = []
                }
                await reloadMeetings()
                if selectedMeetingID == nil {
                    selectedMeetingID = meetings.first?.id
                }
                await loadSelectedMeeting()
                status = "Reunion supprimee"
            } catch {
                logger.error("Meeting deletion failed: \(error.localizedDescription, privacy: .public)")
                status = "Suppression de la reunion impossible"
            }
        }
    }

    func stopMeeting() {
        guard phase == .recording else { return }
        phase = .stopping
        status = "Finalisation des derniers mots..."

        Task {
            await captureSource.stop()
            await finalizeCurrentMeeting(requestedState: .completed)
        }
    }

    func refreshAfterAIUpdate() async {
        await reloadMeetings()
        await loadSelectedMeeting()
    }

    func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func apply(_ engineStatus: TranscriptionEngineStatus) {
        switch engineStatus {
        case let .loadingModels(progress):
            applyPreparationProgress(
                progress,
                subject: "modele francais local"
            )
        case let .loadingRealtime(progress):
            applyPreparationProgress(
                progress,
                subject: "modele temps reel francais et anglais"
            )
        case let .loadingDiarization(progress):
            applyPreparationProgress(
                progress,
                subject: "distinction des intervenants"
            )
        case let .loadingVoiceIdentity(progress):
            applyPreparationProgress(
                progress,
                subject: "reconnaissance de votre voix"
            )
        case let .ready(diarizationEnabled):
            preparationProgress = nil
            status = diarizationEnabled
                ? "Modeles locaux prets"
                : "Transcription prete, intervenants distants regroupes"
        case let .warning(message):
            status = message
        }
    }

    private func applyPreparationProgress(
        _ progress: ModelPreparationProgress?,
        subject: String
    ) {
        guard let progress else {
            preparationProgress = nil
            status = "Verification du \(subject)..."
            return
        }

        preparationProgress = progress.fractionCompleted
        let percentage = Int((progress.fractionCompleted * 100).rounded())

        switch progress.activity {
        case .listing:
            status = "Verification du \(subject)..."
        case let .downloading(completedFiles, totalFiles):
            let files = totalFiles > 1 ? " · \(completedFiles)/\(totalFiles) fichiers" : ""
            status = "Telechargement du \(subject) — \(percentage) %\(files)"
        case .compiling:
            status = "Preparation du \(subject) — \(percentage) %"
        }
    }

    private func acceptCaptureEvent(_ event: AudioCaptureEvent) {
        switch event {
        case let .level(snapshot):
            if snapshot.bufferCount.isMultiple(of: 250) {
                logger.info(
                    "Audio input active input=\(snapshot.input.rawValue, privacy: .public) buffers=\(snapshot.bufferCount, privacy: .public) level=\(String(format: "%.4f", snapshot.linearLevel), privacy: .public)"
                )
            }
            switch snapshot.input {
            case .microphone:
                microphoneLevel = snapshot.linearLevel
            case .system:
                systemLevel = snapshot.linearLevel
            }
            if snapshot.linearLevel >= 0.008, realtimeAudioActivityStartedAt == nil {
                realtimeAudioActivityStartedAt = Date()
            }
        case let .stopped(reason):
            logger.error(
                "Capture source stopped phase=\(String(describing: self.phase), privacy: .public) reason=\(reason, privacy: .public)"
            )
            if phase == .recording {
                phase = .stopping
                status = "Capture interrompue · sauvegarde du son restant"
                Task { [weak self] in
                    await self?.finalizeCurrentMeeting(
                        requestedState: .interrupted,
                        interruptionReason: reason
                    )
                }
            }
        case .samples:
            break
        }
    }

    private func acceptRealtimePreview(_ preview: RealtimeTranscriptPreview) {
        let normalizedText = preview.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedText.isEmpty {
            lastRealtimeTextAt = Date()
            realtimePreviewCounts[preview.input, default: 0] += 1
            if realtimePreviewCounts[preview.input] == 1 {
                let processedSeconds = String(
                    format: "%.2f",
                    preview.processedAudioDuration
                )
                logger.info(
                    "First realtime text input=\(preview.input.rawValue, privacy: .public) processed_seconds=\(processedSeconds, privacy: .public) characters=\(normalizedText.count, privacy: .public)"
                )
            }
        }
        switch preview.input {
        case .microphone:
            microphoneDraft = normalizedText
            microphoneDraftSpeaker = "Micro du Mac · direct"
        case .system:
            systemDraft = normalizedText
        }

        guard let meetingID = currentMeeting?.id,
              var segmenter = realtimeSegmenters[preview.input],
              let segment = segmenter.ingest(
                  cumulativeText: normalizedText,
                  processedAudioDuration: preview.processedAudioDuration
              )
        else { return }
        realtimeSegmenters[preview.input] = segmenter
        upsertVisibleRealtimeSegment(segment)
        let updateCount = realtimePreviewCounts[preview.input, default: 0]
        if updateCount == 1 || updateCount.isMultiple(of: 10) {
            let detectedLanguage = preview.detectedLanguage ?? "unknown"
            logger.info(
                "Realtime text published input=\(preview.input.rawValue, privacy: .public) language=\(detectedLanguage, privacy: .public) updates=\(updateCount, privacy: .public) visible_segments=\(self.realtimeSegments.count, privacy: .public) characters=\(normalizedText.count, privacy: .public)"
            )
        }
        enqueueRealtimePersistence(segment, meetingID: meetingID)
    }

    private func upsertVisibleRealtimeSegment(_ segment: TranscriptSegment) {
        var updatedSegments = realtimeSegments
        if let index = updatedSegments.firstIndex(where: { $0.id == segment.id }) {
            updatedSegments[index] = segment
        } else {
            updatedSegments.append(segment)
        }
        realtimeSegments = updatedSegments.sorted {
            if $0.startTime == $1.startTime { return $0.createdAt < $1.createdAt }
            return $0.startTime < $1.startTime
        }
    }

    private func enqueueRealtimePersistence(
        _ segment: TranscriptSegment,
        meetingID: UUID
    ) {
        let previousTask = realtimePersistenceTask
        let store = self.store
        realtimePersistenceTask = Task { [weak self] in
            await previousTask?.value
            do {
                guard self?.currentMeeting?.id == meetingID else { return }
                try await store?.upsertRealtimeSegment(segment)
            } catch {
                self?.recordRealtimePersistenceFailure(error)
            }
        }
    }

    private func accept(
        _ update: LiveTranscriptionUpdate,
        meetingID: UUID,
        audioBlockID: String
    ) -> TranscriptSegment {
        let effectiveSpeakerName = resolvedSpeakerName(
            meetingID: meetingID,
            speakerID: update.speakerID,
            fallback: update.speakerName
        )

        let segment = TranscriptSegment(
            meetingID: meetingID,
            speakerID: update.speakerID,
            speakerName: effectiveSpeakerName,
            startTime: update.startTime,
            endTime: update.endTime,
            text: update.text,
            confidence: update.confidence,
            inputKind: TranscriptInputKind(rawValue: update.input.rawValue),
            audioBlockID: audioBlockID
        )

        switch update.input {
        case .microphone:
            microphoneDraft = update.isFinal ? "" : update.text
            microphoneDraftSpeaker = effectiveSpeakerName
        case .system:
            systemDraft = update.isFinal ? "" : update.text
        }
        return segment
    }

    private func upsertVoiceProfile(_ profile: VoiceProfile) {
        if let index = voiceProfiles.firstIndex(where: { $0.id == profile.id }) {
            voiceProfiles[index] = profile
        } else {
            voiceProfiles.append(profile)
        }
        voiceProfiles.sort {
            if $0.id == "local-user" { return true }
            if $1.id == "local-user" { return false }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func resolvedSpeakerName(
        meetingID: UUID,
        speakerID: String,
        fallback: String
    ) -> String {
        if let profileName = profileNameOverrides[speakerID] {
            return profileName
        }
        let key = MeetingSpeakerKey(meetingID: meetingID, speakerID: speakerID)
        return meetingSpeakerNameOverrides[key] ?? fallback
    }

    private func renamedProfileIfNeeded(_ profile: VoiceProfile?) -> VoiceProfile? {
        guard let profile,
              let overriddenName = profileNameOverrides[profile.id]
        else { return profile }

        return VoiceProfile(
            id: profile.id,
            displayName: overriddenName,
            embedding: profile.embedding,
            sampleCount: profile.sampleCount,
            updatedAt: profile.updatedAt
        )
    }

    private func replaceVisibleSpeakerName(
        speakerID: String,
        displayName: String,
        meetingID: UUID? = nil
    ) {
        segments = segments.map { segment in
            guard segment.speakerID == speakerID,
                  meetingID == nil || segment.meetingID == meetingID
            else { return segment }

            return TranscriptSegment(
                id: segment.id,
                meetingID: segment.meetingID,
                speakerID: segment.speakerID,
                speakerName: displayName,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text,
                confidence: segment.confidence,
                inputKind: segment.inputKind,
                audioBlockID: segment.audioBlockID,
                createdAt: segment.createdAt
            )
        }
    }

    private func configureAudioPipeline(
        meetingID: UUID,
        journal: DurableAudioJournal,
        previewEngine: any RealtimePreviewTranscriptionEngine,
        timeOffset: TimeInterval
    ) -> AudioChunkFanout {
        pipelineFailureMessage = nil
        let (microphoneStream, microphoneContinuation) = AsyncStream<AudioChunk>.makeStream(
            bufferingPolicy: .unbounded
        )
        let (systemStream, systemContinuation) = AsyncStream<AudioChunk>.makeStream(
            bufferingPolicy: .unbounded
        )
        let (microphonePreviewStream, microphonePreviewContinuation) = AsyncStream<AudioChunk>.makeStream(
            bufferingPolicy: .bufferingNewest(600)
        )
        let (systemPreviewStream, systemPreviewContinuation) = AsyncStream<AudioChunk>.makeStream(
            bufferingPolicy: .bufferingNewest(300)
        )
        let deferredAudioBlockQueue = DeferredAudioBlockQueue()
        let previewDropCounter = AudioChunkDropCounter()

        microphoneAudioContinuation = microphoneContinuation
        systemAudioContinuation = systemContinuation
        self.microphonePreviewContinuation = microphonePreviewContinuation
        self.systemPreviewContinuation = systemPreviewContinuation
        self.deferredAudioBlockQueue = deferredAudioBlockQueue

        microphoneJournalTask = Task { [weak self] in
            var batcher = RealtimeAudioChunkBatcher()
            for await chunk in microphoneStream {
                for batch in batcher.append(chunk) {
                    await self?.appendToJournal(
                        batch,
                        meetingID: meetingID,
                        timeOffset: timeOffset,
                        journal: journal,
                        deferredQueue: deferredAudioBlockQueue
                    )
                }
            }
            if let remainder = batcher.finish() {
                await self?.appendToJournal(
                    remainder,
                    meetingID: meetingID,
                    timeOffset: timeOffset,
                    journal: journal,
                    deferredQueue: deferredAudioBlockQueue
                )
            }
        }
        systemJournalTask = Task { [weak self] in
            var batcher = RealtimeAudioChunkBatcher()
            for await chunk in systemStream {
                for batch in batcher.append(chunk) {
                    await self?.appendToJournal(
                        batch,
                        meetingID: meetingID,
                        timeOffset: timeOffset,
                        journal: journal,
                        deferredQueue: deferredAudioBlockQueue
                    )
                }
            }
            if let remainder = batcher.finish() {
                await self?.appendToJournal(
                    remainder,
                    meetingID: meetingID,
                    timeOffset: timeOffset,
                    journal: journal,
                    deferredQueue: deferredAudioBlockQueue
                )
            }
        }
        microphonePreviewTask = Task { [weak self] in
            var batcher = RealtimeAudioChunkBatcher()
            for await chunk in microphonePreviewStream {
                for batch in batcher.append(chunk) {
                    do {
                        try await previewEngine.ingest(batch)
                        self?.acceptRealtimeProgress(batch)
                    } catch {
                        self?.recordPreviewFailure(error)
                    }
                }
            }
            if let remainder = batcher.finish() {
                do {
                    try await previewEngine.ingest(remainder)
                    self?.acceptRealtimeProgress(remainder)
                } catch {
                    self?.recordPreviewFailure(error)
                }
            }
        }
        systemPreviewTask = Task { [weak self] in
            var batcher = RealtimeAudioChunkBatcher()
            for await chunk in systemPreviewStream {
                for batch in batcher.append(chunk) {
                    do {
                        try await previewEngine.ingest(batch)
                        self?.acceptRealtimeProgress(batch)
                    } catch {
                        self?.recordPreviewFailure(error)
                    }
                }
            }
            if let remainder = batcher.finish() {
                do {
                    try await previewEngine.ingest(remainder)
                    self?.acceptRealtimeProgress(remainder)
                } catch {
                    self?.recordPreviewFailure(error)
                }
            }
        }

        return AudioChunkFanout(
            sinks: [
                { chunk in
                    switch chunk.input {
                    case .microphone:
                        microphoneContinuation.yield(chunk)
                    case .system:
                        systemContinuation.yield(chunk)
                    }
                },
                { chunk in
                    let result: AsyncStream<AudioChunk>.Continuation.YieldResult
                    switch chunk.input {
                    case .microphone:
                        result = microphonePreviewContinuation.yield(chunk)
                    case .system:
                        result = systemPreviewContinuation.yield(chunk)
                    }
                    if case .dropped = result {
                        let count = previewDropCounter.record(input: chunk.input)
                        if count == 1 || count.isMultiple(of: 100) {
                            Task { @MainActor [weak self] in
                                self?.recordPreviewDrop(input: chunk.input, count: count)
                            }
                        }
                    }
                },
            ]
        )
    }

    private func acceptRealtimeProgress(_ chunk: AudioChunk) {
        let processedDuration = max(0, chunk.startTime + chunk.duration)
        realtimeProcessedDurations[chunk.input] = max(
            realtimeProcessedDurations[chunk.input, default: 0],
            processedDuration
        )
        guard let realtimeCaptureStartedAt else { return }

        let captureDuration = Date().timeIntervalSince(realtimeCaptureStartedAt)
        let slowestProcessedDuration = AudioInputKind.allCases
            .compactMap { realtimeProcessedDurations[$0] }
            .min() ?? 0
        realtimeProcessingLag = max(0, captureDuration - slowestProcessedDuration)
        if realtimeProcessingLag >= LiveTranscriptPresentation.delayWarningInterval,
           !didLogRealtimeLagWarning {
            didLogRealtimeLagWarning = true
            let lagSeconds = String(format: "%.2f", realtimeProcessingLag)
            logger.warning(
                "Realtime transcription lagging seconds=\(lagSeconds, privacy: .public)"
            )
        } else if realtimeProcessingLag < 3 {
            didLogRealtimeLagWarning = false
        }
    }

    private func recordPreviewDrop(input: AudioInputKind, count: Int) {
        logger.warning(
            "Realtime preview backlog bounded input=\(input.rawValue, privacy: .public) dropped_chunks=\(count, privacy: .public)"
        )
        if phase == .recording {
            status = "Direct en retard · audio integral protege pour la consolidation"
        }
    }

    private func appendToJournal(
        _ chunk: AudioChunk,
        meetingID: UUID,
        timeOffset: TimeInterval,
        journal: DurableAudioJournal,
        deferredQueue: DeferredAudioBlockQueue
    ) async {
        do {
            let journalChunk = Self.offset(chunk, by: timeOffset)
            let blocks = try await journal.append(journalChunk, meetingID: meetingID)
            await deferredQueue.enqueue(contentsOf: blocks)
        } catch {
            recordPipelineFailure(error)
        }
    }

    private func processAudioBlock(
        _ block: RecordedAudioBlock,
        engine: any RecordedAudioTranscriptionEngine
    ) async throws {
        guard let store, let audioJournal else {
            throw MeetingPipelineError.localStorageUnavailable
        }
        guard try await store.meetingExists(id: block.meetingID) else {
            try await audioJournal.acknowledge(block)
            return
        }
        if try await store.isAudioBlockProcessed(id: block.id) {
            try await audioJournal.acknowledge(block)
            return
        }

        let updates = try await engine.transcribe(block)
        let profiles = updates.compactMap { renamedProfileIfNeeded($0.voiceProfileUpdate) }
        let transcriptSegments = updates.map {
            accept($0, meetingID: block.meetingID, audioBlockID: block.id)
        }
        let inputKind = TranscriptInputKind(rawValue: block.input.rawValue) ?? .system
        let committed = try await store.commitAudioBlock(
            id: block.id,
            meetingID: block.meetingID,
            inputKind: inputKind,
            segments: transcriptSegments,
            voiceProfiles: profiles
        )
        try await audioJournal.acknowledge(block)

        guard committed else { return }
        for profile in profiles { upsertVoiceProfile(profile) }
        if currentMeeting?.id == block.meetingID || selectedMeetingID == block.meetingID {
            segments.append(contentsOf: transcriptSegments)
            segments.sort {
                if $0.startTime == $1.startTime { return $0.createdAt < $1.createdAt }
                return $0.startTime < $1.startTime
            }
        }
        if phase == .recording {
            status = "Enregistrement local · transcript sauvegarde par blocs"
        }
    }

    private func finalizeCurrentMeeting(
        requestedState: MeetingState,
        interruptionReason: String? = nil
    ) async {
        guard let meetingID = currentMeeting?.id else { return }

        microphoneAudioContinuation?.finish()
        systemAudioContinuation?.finish()
        await microphoneJournalTask?.value
        await systemJournalTask?.value
        microphoneAudioContinuation = nil
        systemAudioContinuation = nil
        microphoneJournalTask = nil
        systemJournalTask = nil

        microphonePreviewContinuation?.finish()
        systemPreviewContinuation?.finish()
        await microphonePreviewTask?.value
        await systemPreviewTask?.value
        microphonePreviewContinuation = nil
        systemPreviewContinuation = nil
        microphonePreviewTask = nil
        systemPreviewTask = nil

        await previewEngine?.stopSession()
        await realtimePersistenceTask?.value
        realtimePersistenceTask = nil

        do {
            let finalBlocks = try await audioJournal?.finish(meetingID: meetingID) ?? []
            await deferredAudioBlockQueue?.enqueue(contentsOf: finalBlocks)
        } catch {
            recordPipelineFailure(error)
        }

        let deferredBlocks = await deferredAudioBlockQueue?.drain() ?? []
        deferredAudioBlockQueue = nil
        if !deferredBlocks.isEmpty {
            status = "Finalisation locale · \(deferredBlocks.count) bloc(s) audio"
        }
        if let engine {
            for block in deferredBlocks {
                do {
                    try await processAudioBlock(block, engine: engine)
                } catch {
                    recordPipelineFailure(error)
                }
            }
        } else if !deferredBlocks.isEmpty {
            recordPipelineFailure(MeetingPipelineError.transcriptionEngineUnavailable)
        }
        if pipelineFailureMessage == nil {
            do {
                try await store?.deleteRealtimeSegments(meetingID: meetingID)
                realtimeSegments = []
            } catch {
                recordPipelineFailure(error)
            }
        }

        let finalState: MeetingState = pipelineFailureMessage == nil
            ? requestedState
            : .interrupted
        do {
            try await store?.finishMeeting(id: meetingID, state: finalState)
        } catch {
            recordPipelineFailure(error)
        }

        currentMeeting = nil
        microphoneLevel = 0
        systemLevel = 0
        microphoneDraft = ""
        microphoneDraftSpeaker = "Micro du Mac"
        systemDraft = ""
        realtimeAudioActivityStartedAt = nil
        lastRealtimeTextAt = nil
        realtimeProcessingLag = 0
        realtimePreviewCounts = [:]
        realtimeProcessedDurations = [:]
        realtimeCaptureStartedAt = nil
        didLogRealtimeLagWarning = false
        realtimeSegmenters = [:]
        phase = .idle
        preparationProgress = nil

        if let pipelineFailureMessage {
            status = "Audio local conserve · reprise necessaire : \(pipelineFailureMessage)"
        } else if let interruptionReason {
            status = "Capture interrompue · transcript sauvegarde (\(interruptionReason))"
        } else {
            status = "Transcript sauvegarde · audio temporaire supprime"
        }

        await reloadMeetings()
        await loadSelectedMeeting()
        NotificationCenter.default.post(
            name: .meetingDidFinish,
            object: meetingID
        )
        pipelineFailureMessage = nil
    }

    private func recoverPendingAudio() async throws {
        guard let store, let audioJournal else { return }
        let pendingBlocks = try await audioJournal.recoverPendingBlocks()
        guard !pendingBlocks.isEmpty else { return }

        var recoverableBlocks: [RecordedAudioBlock] = []
        for block in pendingBlocks {
            guard try await store.meetingExists(id: block.meetingID) else {
                try await audioJournal.acknowledge(block)
                continue
            }
            if try await store.isAudioBlockProcessed(id: block.id) {
                try await audioJournal.acknowledge(block)
            } else {
                recoverableBlocks.append(block)
            }
        }
        guard !recoverableBlocks.isEmpty else { return }

        phase = .preparing
        status = "Reprise de \(recoverableBlocks.count) bloc(s) audio local(aux)..."
        let recoveryEngine = FluidAudioBatchTranscriptionEngine(voiceProfiles: voiceProfiles)
        try await recoveryEngine.prepare { [weak self] engineStatus in
            Task { @MainActor [weak self] in self?.apply(engineStatus) }
        }

        var failureCount = 0
        var failedMeetingIDs: Set<UUID> = []
        for block in recoverableBlocks {
            do {
                try await processAudioBlock(block, engine: recoveryEngine)
            } catch {
                failureCount += 1
                failedMeetingIDs.insert(block.meetingID)
                logger.error(
                    "Pending audio recovery failed block=\(block.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
        for meetingID in Set(recoverableBlocks.map(\.meetingID))
            where !failedMeetingIDs.contains(meetingID) {
            try await store.deleteRealtimeSegments(meetingID: meetingID)
        }
        await recoveryEngine.finish()
        voiceProfiles = try await store.voiceProfiles()
        hasVoiceProfile = voiceProfiles.contains { $0.id == "local-user" }
        phase = .idle
        preparationProgress = nil
        status = failureCount == 0
            ? "Audio interrompu recupere et transcrit"
            : "\(failureCount) bloc(s) audio restent a reprendre"
    }

    private func preloadTranscriptionEngines() async {
        guard store != nil else { return }

        phase = .preparing
        status = "Chargement des modeles locaux..."
        preparationProgress = nil
        do {
            _ = try await preparedTranscriptionEngines()
            areModelsReady = true
            phase = .idle
            preparationProgress = nil
            status = "Modeles locaux prets"
            logger.info("Transcription models preloaded and retained for immediate capture")
        } catch {
            logger.error(
                "Model preload failed: \(error.localizedDescription, privacy: .public)"
            )
            await releaseTranscriptionEngines()
            phase = .failed(error.localizedDescription)
            status = "Chargement des modeles locaux impossible"
            preparationProgress = nil
        }
    }

    private func preparedTranscriptionEngines() async throws -> (
        FluidAudioBatchTranscriptionEngine,
        FluidAudioRealtimePreviewEngine
    ) {
        let batchEngine: FluidAudioBatchTranscriptionEngine
        if let engine {
            batchEngine = engine
            try await batchEngine.prepare { [weak self] engineStatus in
                Task { @MainActor [weak self] in self?.apply(engineStatus) }
            }
        } else {
            let candidate = FluidAudioBatchTranscriptionEngine(voiceProfiles: voiceProfiles)
            do {
                try await candidate.prepare { [weak self] engineStatus in
                    Task { @MainActor [weak self] in self?.apply(engineStatus) }
                }
                engine = candidate
                batchEngine = candidate
            } catch {
                await candidate.finish()
                throw error
            }
        }
        await batchEngine.replaceVoiceProfiles(voiceProfiles)

        let realtimeEngine: FluidAudioRealtimePreviewEngine
        if let previewEngine {
            realtimeEngine = previewEngine
            try await realtimeEngine.prepare { [weak self] engineStatus in
                Task { @MainActor [weak self] in self?.apply(engineStatus) }
            }
        } else {
            let candidate = FluidAudioRealtimePreviewEngine()
            do {
                try await candidate.prepare { [weak self] engineStatus in
                    Task { @MainActor [weak self] in self?.apply(engineStatus) }
                }
                previewEngine = candidate
                realtimeEngine = candidate
            } catch {
                await candidate.finish()
                throw error
            }
        }

        let isBatchReady = await batchEngine.isReady
        let isRealtimeReady = await realtimeEngine.isReady
        areModelsReady = isBatchReady && isRealtimeReady
        return (batchEngine, realtimeEngine)
    }

    private func releaseTranscriptionEngines() async {
        await previewEngine?.finish()
        await engine?.finish()
        previewEngine = nil
        engine = nil
        areModelsReady = false
    }

    private func recordPipelineFailure(_ error: Error) {
        logger.error("Audio pipeline failed: \(error.localizedDescription, privacy: .public)")
        if pipelineFailureMessage == nil {
            pipelineFailureMessage = error.localizedDescription
        }
    }

    private func recordPreviewFailure(_ error: Error) {
        logger.error(
            "Realtime preview failed without affecting durable audio: \(error.localizedDescription, privacy: .public)"
        )
        if phase == .recording {
            status = "Apercu temps reel indisponible · audio toujours sauvegarde"
        }
    }

    private func recordRealtimePersistenceFailure(_ error: Error) {
        logger.error(
            "Realtime transcript persistence failed: \(error.localizedDescription, privacy: .public)"
        )
        if phase == .recording {
            status = "Direct visible · sauvegarde texte retardee · audio protege"
        }
    }

    private func reloadVisibleSegments() async {
        guard currentMeeting == nil,
              let selectedMeetingID,
              let store
        else { return }
        if let loaded = try? await store.segments(meetingID: selectedMeetingID) {
            applyLoadedSegments(loaded)
        }
    }

    private func failCurrentMeeting(_ error: Error) async {
        logger.error("Meeting start failed: \(error.localizedDescription, privacy: .public)")
        await captureSource.stop()
        if currentMeeting != nil {
            recordPipelineFailure(error)
            await finalizeCurrentMeeting(
                requestedState: .interrupted,
                interruptionReason: error.localizedDescription
            )
        } else {
            await releaseTranscriptionEngines()
        }
        phase = .failed(error.localizedDescription)
        status = "Demarrage impossible"
        preparationProgress = nil
        await reloadMeetings()
    }

    private func reloadMeetings() async {
        guard let store else { return }
        do {
            meetings = try await store.meetings()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func loadSelectedMeeting() async {
        guard currentMeeting == nil,
              let selectedMeetingID,
              let store
        else { return }
        do {
            applyLoadedSegments(try await store.segments(meetingID: selectedMeetingID))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func applyLoadedSegments(_ loaded: [TranscriptSegment]) {
        segments = loaded.filter { $0.source == .canonical }
        realtimeSegments = loaded.filter { $0.source == .realtime }
    }

    private static func resumeOffset(from segments: [TranscriptSegment]) -> TimeInterval {
        max(0, segments.map(\.endTime).max() ?? 0)
    }

    private static func offset(_ chunk: AudioChunk, by timeOffset: TimeInterval) -> AudioChunk {
        guard timeOffset > 0 else { return chunk }
        return AudioChunk(
            input: chunk.input,
            samples: chunk.samples,
            sampleRate: chunk.sampleRate,
            startTime: chunk.startTime + timeOffset
        )
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private enum MeetingPipelineError: LocalizedError {
    case localStorageUnavailable
    case transcriptionEngineUnavailable

    var errorDescription: String? {
        switch self {
        case .localStorageUnavailable:
            "Le stockage local du transcript ou de l'audio est indisponible."
        case .transcriptionEngineUnavailable:
            "Le moteur de consolidation locale est indisponible."
        }
    }
}
