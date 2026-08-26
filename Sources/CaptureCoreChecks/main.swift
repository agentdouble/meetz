import AudioJournal
import CaptureCore
import Darwin
import Foundation
import MeetingDomain
import TranscriptStore
import TranscriptionCore

private struct CheckFailure: Error {
    let message: String
}

private final class LockedFanoutRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var inputsBySink: [Int: [AudioInputKind]] = [:]

    func record(sink: Int, input: AudioInputKind) {
        lock.lock()
        inputsBySink[sink, default: []].append(input)
        lock.unlock()
    }

    func inputs(for sink: Int) -> [AudioInputKind] {
        lock.lock()
        defer { lock.unlock() }
        return inputsBySink[sink, default: []]
    }
}

private final class LockedAudioLevelRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[AudioLevelSnapshot]] = []

    func record(_ snapshots: [AudioLevelSnapshot]) {
        lock.lock()
        batches.append(snapshots)
        lock.unlock()
    }

    func recordedBatches() -> [[AudioLevelSnapshot]] {
        lock.lock()
        defer { lock.unlock() }
        return batches
    }
}

private final class LockedAudioProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[AudioProcessingProgress]] = []

    func record(_ snapshots: [AudioProcessingProgress]) {
        lock.lock()
        batches.append(snapshots)
        lock.unlock()
    }

    func recordedBatches() -> [[AudioProcessingProgress]] {
        lock.lock()
        defer { lock.unlock() }
        return batches
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw CheckFailure(message: message)
    }
}

do {
    try expect(
        AudioMath.rootMeanSquare(of: [Float]()) == 0,
        "Le silence vide doit avoir un RMS nul"
    )
    try expect(
        AudioMath.rootMeanSquare(of: [0, 0, 0]) == 0,
        "Le silence doit avoir un RMS nul"
    )

    let squareSignalResult = AudioMath.rootMeanSquare(
        of: [Float(0.5), -0.5, 0.5, -0.5]
    )
    try expect(
        abs(squareSignalResult - 0.5) < 0.000_001,
        "Le RMS du signal carre doit conserver son amplitude"
    )

    try expect(
        AudioMath.meterLevel(fromRootMeanSquare: 0) == 0,
        "Le vumetre doit retourner zero pour le silence"
    )
    try expect(
        AudioMath.meterLevel(fromRootMeanSquare: 1) == 1,
        "Le vumetre doit atteindre un au niveau maximal"
    )
    try expect(
        AudioMath.meterLevel(fromRootMeanSquare: 10) == 1,
        "Le vumetre doit borner les niveaux superieurs a un"
    )

    let levelCoalescer = AudioLevelCoalescer(updatesPerSecond: 30)
    let levelRecorder = LockedAudioLevelRecorder()
    for count in 1...500 {
        levelCoalescer.submit(
            AudioLevelSnapshot(
                input: .microphone,
                linearLevel: Double(count) / 500,
                bufferCount: UInt64(count)
            ),
            handler: levelRecorder.record
        )
        levelCoalescer.submit(
            AudioLevelSnapshot(
                input: .system,
                linearLevel: Double(count) / 1_000,
                bufferCount: UInt64(count)
            ),
            handler: levelRecorder.record
        )
    }
    try await Task.sleep(for: .milliseconds(80))
    let coalescedLevelBatches = levelRecorder.recordedBatches()
    try expect(
        coalescedLevelBatches.count == 1,
        "Mille niveaux rapproches doivent produire une seule livraison UI"
    )
    try expect(
        coalescedLevelBatches[0].first { $0.input == .microphone }?.bufferCount == 500
            && coalescedLevelBatches[0].first { $0.input == .system }?.bufferCount == 500,
        "Le coalescer doit livrer le niveau le plus recent de chaque entree"
    )
    levelCoalescer.submit(
        AudioLevelSnapshot(input: .microphone, linearLevel: 1, bufferCount: 501),
        handler: levelRecorder.record
    )
    levelCoalescer.cancel()
    try await Task.sleep(for: .milliseconds(80))
    try expect(
        levelRecorder.recordedBatches().count == 1,
        "Une livraison invalidee ne doit pas contaminer la capture suivante"
    )

    let progressCoalescer = AudioProgressCoalescer(updatesPerSecond: 30)
    let progressRecorder = LockedAudioProgressRecorder()
    for count in 1...500 {
        progressCoalescer.submit(
            AudioProcessingProgress(
                input: .microphone,
                processedDuration: Double(count) / 10
            ),
            handler: progressRecorder.record
        )
        progressCoalescer.submit(
            AudioProcessingProgress(
                input: .system,
                processedDuration: Double(count) / 20
            ),
            handler: progressRecorder.record
        )
    }
    try await Task.sleep(for: .milliseconds(80))
    let coalescedProgressBatches = progressRecorder.recordedBatches()
    try expect(
        coalescedProgressBatches.count == 1,
        "Mille progressions ASR ne doivent produire qu'une livraison UI"
    )
    try expect(
        coalescedProgressBatches[0].first { $0.input == .microphone }?.processedDuration == 50
            && coalescedProgressBatches[0].first { $0.input == .system }?.processedDuration == 25,
        "Le coalescer doit conserver la progression ASR la plus recente"
    )

    var resumedSegmenter = RealtimeTranscriptSegmenter(
        meetingID: UUID(),
        input: .system,
        timeOffset: 63.5
    )
    let resumedRealtimeSegment = resumedSegmenter.ingest(
        cumulativeText: "La reunion reprend maintenant.",
        processedAudioDuration: 2.24
    )
    try expect(
        resumedRealtimeSegment?.startTime == 63.5
            && abs((resumedRealtimeSegment?.endTime ?? 0) - 65.74) < 0.000_001,
        "Le direct repris doit continuer les horodatages existants"
    )

    let presentationNow = Date(timeIntervalSince1970: 100)
    let listeningPresentation = LiveTranscriptPresentation(
        segments: [],
        microphoneDraft: "",
        systemDraft: "",
        audioActivityStartedAt: nil,
        lastTextAt: nil,
        now: presentationNow
    )
    try expect(
        listeningPresentation.activity == .listening
            && listeningPresentation.text.isEmpty,
        "Le direct sans son doit afficher un etat d'ecoute explicite"
    )
    let processingPresentation = LiveTranscriptPresentation(
        segments: [],
        microphoneDraft: "",
        systemDraft: "",
        audioActivityStartedAt: presentationNow.addingTimeInterval(-5),
        lastTextAt: nil,
        now: presentationNow
    )
    try expect(
        processingPresentation.activity == .transcribing,
        "Le direct doit confirmer que le son detecte est en cours de transcription"
    )
    let delayedPresentation = LiveTranscriptPresentation(
        segments: [],
        microphoneDraft: "",
        systemDraft: "",
        audioActivityStartedAt: presentationNow.addingTimeInterval(-20),
        lastTextAt: nil,
        now: presentationNow
    )
    try expect(
        delayedPresentation.activity == .delayed,
        "Le direct muet depuis douze secondes doit signaler son retard sans paraitre bloque"
    )
    let draftPresentation = LiveTranscriptPresentation(
        segments: [],
        microphoneDraft: "Brouillon microphone",
        systemDraft: "Brouillon systeme",
        audioActivityStartedAt: presentationNow.addingTimeInterval(-20),
        lastTextAt: presentationNow,
        now: presentationNow
    )
    try expect(
        draftPresentation.activity == .live
            && draftPresentation.text == "Brouillon microphone\n\nBrouillon systeme",
        "Les brouillons moteur doivent rester un secours visible avant la persistence"
    )
    let laggingTextPresentation = LiveTranscriptPresentation(
        segments: [],
        microphoneDraft: "Texte deja visible",
        systemDraft: "",
        audioActivityStartedAt: presentationNow.addingTimeInterval(-20),
        lastTextAt: presentationNow,
        processingLag: 13,
        now: presentationNow
    )
    try expect(
        laggingTextPresentation.activity == .delayed
            && laggingTextPresentation.processingLag == 13,
        "Un texte ancien ne doit pas masquer un retard reel du moteur direct"
    )

    var realtimeBatcher = RealtimeAudioChunkBatcher()
    var realtimeBatches: [AudioChunk] = []
    for index in 0..<10 {
        realtimeBatches += realtimeBatcher.append(
            AudioChunk(
                input: .microphone,
                samples: Array(repeating: Float(index), count: 160),
                sampleRate: 16_000,
                startTime: Double(index) * 0.01
            )
        )
    }
    try expect(
        realtimeBatches.count == 1
            && realtimeBatches[0].samples.count == 1_600
            && realtimeBatches[0].startTime == 0,
        "Les micro-buffers doivent former un paquet ASR continu de cent millisecondes"
    )
    _ = realtimeBatcher.append(
        AudioChunk(
            input: .microphone,
            samples: Array(repeating: 1, count: 320),
            sampleRate: 16_000,
            startTime: 0.1
        )
    )
    let realtimeRemainder = realtimeBatcher.finish()
    try expect(
        realtimeRemainder?.samples.count == 320
            && abs((realtimeRemainder?.startTime ?? 0) - 0.1) < 0.000_001,
        "La fin de reunion doit transmettre le dernier paquet ASR incomplet"
    )
    var discontinuousBatcher = RealtimeAudioChunkBatcher()
    _ = discontinuousBatcher.append(
        AudioChunk(
            input: .system,
            samples: Array(repeating: 0.25, count: 1_280),
            sampleRate: 16_000,
            startTime: 0
        )
    )
    let discontinuousBatches = discontinuousBatcher.append(
        AudioChunk(
            input: .system,
            samples: Array(repeating: 0.5, count: 1_600),
            sampleRate: 16_000,
            startTime: 1
        )
    )
    try expect(
        discontinuousBatches.count == 2
            && discontinuousBatches[0].samples.count == 1_280
            && discontinuousBatches[0].startTime == 0
            && discontinuousBatches[1].samples.count == 1_600
            && discontinuousBatches[1].startTime == 1,
        "Une file directe bornee ne doit pas recoller artificiellement deux intervalles discontinus"
    )

    let fanoutRecorder = LockedFanoutRecorder()
    let fanout = AudioChunkFanout(
        sinks: [
            { fanoutRecorder.record(sink: 0, input: $0.input) },
            { fanoutRecorder.record(sink: 1, input: $0.input) },
        ]
    )
    fanout.yield(
        AudioChunk(
            input: .system,
            samples: [0.25],
            sampleRate: 16_000,
            startTime: 0
        )
    )
    try expect(
        fanoutRecorder.inputs(for: 0) == [.system]
            && fanoutRecorder.inputs(for: 1) == [.system],
        "Le journal et le direct doivent recevoir independamment chaque paquet capture"
    )
    let dropCounter = AudioChunkDropCounter()
    DispatchQueue.concurrentPerform(iterations: 1_000) { index in
        dropCounter.record(input: index.isMultiple(of: 2) ? .microphone : .system)
    }
    try expect(
        dropCounter.count(for: .microphone) == 500
            && dropCounter.count(for: .system) == 500,
        "Le compteur de saturation direct doit rester exact depuis les files de capture concurrentes"
    )

    let journalRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("meeting-audio-journal-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: journalRoot) }
    let journalConfiguration = DurableAudioJournal.Configuration(
        minimumBlockDuration: 0.5,
        maximumBlockDuration: 1,
        quietRootMeanSquare: 0.001,
        synchronizationInterval: 0.1
    )
    let journal = try DurableAudioJournal(
        rootURL: journalRoot,
        configuration: journalConfiguration,
        sessionIdentifier: "sessionA"
    )
    let journalMeetingID = UUID()
    let journalSamples = (0..<4_000).map { index in
        Float(0.1 * sin(2 * .pi * 220 * Double(index) / 16_000))
    }
    var finalizedBlocks: [RecordedAudioBlock] = []
    for index in 0..<4 {
        finalizedBlocks += try await journal.append(
            AudioChunk(
                input: .microphone,
                samples: journalSamples,
                sampleRate: 16_000,
                startTime: Double(index) * 0.25
            ),
            meetingID: journalMeetingID
        )
    }
    try expect(finalizedBlocks.count == 1, "Le journal doit fermer un bloc a la duree maximale")
    let recordedBlock = finalizedBlocks[0]
    let wavPrefix = try Data(contentsOf: recordedBlock.fileURL).prefix(4)
    try expect(String(data: wavPrefix, encoding: .ascii) == "RIFF", "Le bloc doit etre un WAV lisible")
    let interruptedURL = recordedBlock.fileURL.appendingPathExtension("part")
    try FileManager.default.moveItem(at: recordedBlock.fileURL, to: interruptedURL)
    let recoveredBlocks = try await journal.recoverPendingBlocks()
    try expect(
        recoveredBlocks.count == 1
            && recoveredBlocks[0].id == recordedBlock.id
            && recoveredBlocks[0].duration == recordedBlock.duration,
        "Un bloc non acquitte doit etre repris apres interruption"
    )
    try await journal.acknowledge(recoveredBlocks[0])
    try expect(
        !FileManager.default.fileExists(atPath: recordedBlock.fileURL.path),
        "Un bloc acquitte doit etre supprime"
    )
    let resumedJournal = try DurableAudioJournal(
        rootURL: journalRoot,
        configuration: journalConfiguration,
        sessionIdentifier: "sessionB"
    )
    var resumedBlocks: [RecordedAudioBlock] = []
    for index in 0..<4 {
        resumedBlocks += try await resumedJournal.append(
            AudioChunk(
                input: .microphone,
                samples: journalSamples,
                sampleRate: 16_000,
                startTime: Double(index) * 0.25
            ),
            meetingID: journalMeetingID
        )
    }
    try expect(
        resumedBlocks.count == 1 && resumedBlocks[0].id != recordedBlock.id,
        "Une reprise doit creer un identifiant de bloc distinct apres relance"
    )
    try await resumedJournal.acknowledge(resumedBlocks[0])

    let deferredQueue = DeferredAudioBlockQueue()
    let laterBlock = RecordedAudioBlock(
        id: "later",
        meetingID: journalMeetingID,
        input: .system,
        sequence: 1,
        startTime: 20,
        duration: 20,
        sampleRate: 16_000,
        fileURL: journalRoot.appendingPathComponent("later.wav")
    )
    let earlierBlock = RecordedAudioBlock(
        id: "earlier",
        meetingID: journalMeetingID,
        input: .microphone,
        sequence: 0,
        startTime: 0,
        duration: 20,
        sampleRate: 16_000,
        fileURL: journalRoot.appendingPathComponent("earlier.wav")
    )
    await deferredQueue.enqueue(laterBlock)
    await deferredQueue.enqueue(contentsOf: [earlierBlock, laterBlock])
    let drainedBlocks = await deferredQueue.drain()
    try expect(
        drainedBlocks.map(\.id) == ["earlier", "later"],
        "Les blocs differes doivent etre dedoublonnes et consolides dans l'ordre audio"
    )
    let drainedAgain = await deferredQueue.drain()
    try expect(
        drainedAgain.isEmpty,
        "La file de blocs differes doit etre vide apres sa consolidation"
    )

    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("meeting-check-\(UUID().uuidString).sqlite")
    let store = try SQLiteTranscriptStore(databaseURL: databaseURL)
    let realtimeMeeting = try await store.createMeeting(title: "Controle temps reel")
    let realtimeID = UUID()
    let realtimeFirst = TranscriptSegment(
        id: realtimeID,
        meetingID: realtimeMeeting.id,
        speakerID: "realtime-microphone",
        speakerName: "Micro du Mac",
        startTime: 0,
        endTime: 2.24,
        text: "Texte direct",
        confidence: 0,
        inputKind: .microphone,
        audioBlockID: "realtime:microphone:0",
        source: .realtime
    )
    let realtimeUpdated = TranscriptSegment(
        id: realtimeID,
        meetingID: realtimeMeeting.id,
        speakerID: "realtime-microphone",
        speakerName: "Micro du Mac",
        startTime: 0,
        endTime: 4.48,
        text: "Texte direct mis a jour",
        confidence: 0,
        inputKind: .microphone,
        audioBlockID: "realtime:microphone:0",
        source: .realtime
    )
    let persistedPresentation = LiveTranscriptPresentation(
        segments: [realtimeUpdated],
        microphoneDraft: "Brouillon plus ancien",
        systemDraft: "",
        audioActivityStartedAt: Date(),
        lastTextAt: Date(),
        now: Date()
    )
    try expect(
        persistedPresentation.text == realtimeUpdated.text,
        "Le segment direct persiste doit etre la source d'affichage prioritaire"
    )
    try await store.upsertRealtimeSegment(realtimeFirst)
    try await store.upsertRealtimeSegment(realtimeUpdated)
    let storedRealtime = try await store.segments(meetingID: realtimeMeeting.id)
    try expect(
        storedRealtime.count == 1
            && storedRealtime[0].source == .realtime
            && storedRealtime[0].text == realtimeUpdated.text,
        "Le transcript Nemotron doit etre mis a jour sans doublon dans SQLite"
    )
    let canonicalDuringConsolidation = TranscriptSegment(
        meetingID: realtimeMeeting.id,
        speakerID: "canonical-speaker",
        speakerName: "Voix 1",
        startTime: 0,
        endTime: 20,
        text: "Segment canonique partiel",
        confidence: 0.9,
        source: .canonical
    )
    let preferredDuringConsolidation = ExploitableTranscriptSelection.preferredSegments(
        from: storedRealtime + [canonicalDuringConsolidation]
    )
    try expect(
        preferredDuringConsolidation.count == 1
            && preferredDuringConsolidation[0].source == .realtime,
        "Le direct doit rester la seule source exploitable pendant la consolidation"
    )
    let historicalCanonical = TranscriptSegment(
        meetingID: realtimeMeeting.id,
        speakerID: "historical",
        speakerName: "Voix 1",
        startTime: 0,
        endTime: 40,
        text: "Premiere partie de la reunion.",
        confidence: 0.9,
        source: .canonical
    )
    let resumedRealtime = TranscriptSegment(
        meetingID: realtimeMeeting.id,
        speakerID: "realtime-system",
        speakerName: "Participant",
        startTime: 40,
        endTime: 44,
        text: "Suite en direct.",
        confidence: 0,
        source: .realtime
    )
    let consolidatingResume = TranscriptSegment(
        meetingID: realtimeMeeting.id,
        speakerID: "current",
        speakerName: "Voix 2",
        startTime: 40,
        endTime: 43,
        text: "Suite canonique encore en consolidation.",
        confidence: 0.9,
        source: .canonical
    )
    let preferredDuringResume = ExploitableTranscriptSelection.preferredSegments(
        from: [historicalCanonical, consolidatingResume, resumedRealtime]
    )
    try expect(
        preferredDuringResume.map(\.id) == [historicalCanonical.id, resumedRealtime.id],
        "Une reprise doit conserver l'historique sans doubler la consolidation courante"
    )
    try await store.deleteRealtimeSegments(meetingID: realtimeMeeting.id)
    let realtimeAfterDeletion = try await store.segments(meetingID: realtimeMeeting.id)
    try expect(
        realtimeAfterDeletion.isEmpty,
        "La consolidation doit pouvoir remplacer les segments temps reel"
    )
    try await store.deleteMeeting(id: realtimeMeeting.id)

    let meeting = try await store.createMeeting(title: "Controle local")
    try await store.updateMeetingMetadata(
        id: meeting.id,
        title: "Controle renomme",
        context: "Contexte local conserve pour les traitements futurs.",
        titleOrigin: .user
    )
    let segment = TranscriptSegment(
        meetingID: meeting.id,
        speakerID: "local",
        speakerName: "Moi",
        startTime: 0,
        endTime: 1.5,
        text: "Bonjour, ceci est un controle local.",
        confidence: 0.95
    )
    try await store.insertSegment(segment)
    let batchSegment = TranscriptSegment(
        meetingID: meeting.id,
        speakerID: "local",
        speakerName: "Moi",
        startTime: 2,
        endTime: 3,
        text: "Ce segment vient du journal audio.",
        confidence: 0.97,
        inputKind: .microphone,
        audioBlockID: "block-check"
    )
    let firstBlockCommit = try await store.commitAudioBlock(
        id: "block-check",
        meetingID: meeting.id,
        inputKind: .microphone,
        segments: [batchSegment],
        voiceProfiles: []
    )
    let duplicateBlockCommit = try await store.commitAudioBlock(
        id: "block-check",
        meetingID: meeting.id,
        inputKind: .microphone,
        segments: [batchSegment],
        voiceProfiles: []
    )
    try await store.renameSpeaker(
        meetingID: meeting.id,
        speakerID: segment.speakerID,
        displayName: "Jeremy"
    )
    try await store.finishMeeting(id: meeting.id)
    let resumedMeeting = try await store.resumeMeeting(id: meeting.id)
    var refusedResumeWhileRecording = false
    do {
        _ = try await store.resumeMeeting(id: meeting.id)
    } catch TranscriptStoreError.meetingCannotResume {
        refusedResumeWhileRecording = true
    }
    try await store.finishMeeting(id: meeting.id)

    let aiResult = MeetingAIResult(
        meetingID: meeting.id,
        kind: .summary,
        payloadJSON: "{\"summary\":\"Resume local\"}",
        sourceSegmentCount: 1,
        createdAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    try await store.saveAIResult(aiResult)
    let chatQuestion = MeetingAIChatMessage(
        meetingID: meeting.id,
        role: .user,
        content: "Quelles sont les prochaines etapes ?",
        createdAt: Date(timeIntervalSince1970: 1_700_000_101)
    )
    let chatAnswer = MeetingAIChatMessage(
        meetingID: meeting.id,
        role: .assistant,
        content: "Le transcript ne precise pas encore de prochaine etape.",
        createdAt: Date(timeIntervalSince1970: 1_700_000_102)
    )
    try await store.saveAIChatMessage(chatQuestion)
    try await store.saveAIChatMessage(chatAnswer)
    try await store.enqueueAIJobs(meetingID: meeting.id, kinds: [.title, .summary, .title])

    let automaticTitleMeeting = try await store.createMeeting()
    let appliedAutomaticTitle = try await store.applyAITitleIfAutomatic(
        id: automaticTitleMeeting.id,
        title: "Titre propose par Codex"
    )
    let refusedSecondAutomaticTitle = try await store.applyAITitleIfAutomatic(
        id: automaticTitleMeeting.id,
        title: "Titre qui ne doit pas remplacer le premier"
    )
    try await store.deleteMeeting(id: automaticTitleMeeting.id)

    let interruptedMeeting = try await store.createMeeting(title: "Controle interruption")
    let disposableMeeting = try await store.createMeeting(title: "A supprimer")
    try await store.deleteMeeting(id: disposableMeeting.id)
    let recoveryDate = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.recoverInterruptedMeetings(at: recoveryDate)
    let voiceProfile = VoiceProfile(
        embedding: [0.25, -0.5, 0.75],
        sampleCount: 3,
        updatedAt: recoveryDate
    )
    try await store.saveVoiceProfile(voiceProfile)
    let participantProfile = VoiceProfile(
        id: "participant-test",
        displayName: "Voix 1",
        embedding: [-0.2, 0.4, 0.8],
        sampleCount: 2,
        updatedAt: recoveryDate
    )
    try await store.saveVoiceProfile(participantProfile)
    try await store.renameVoiceProfile(id: participantProfile.id, displayName: "Alice")

    let storedMeetings = try await store.meetings()
    let storedSegments = try await store.segments(meetingID: meeting.id)
    let storedVoiceProfile = try await store.voiceProfile()
    let storedVoiceProfiles = try await store.voiceProfiles()
    let storedAIResults = try await store.aiResults(meetingID: meeting.id)
    let storedChatMessages = try await store.aiChatMessages(meetingID: meeting.id)
    let pendingAIJobs = try await store.pendingAIJobs()
    try expect(storedMeetings.count == 2, "Les reunions doivent etre sauvegardees")
    let completedMeeting = storedMeetings.first { $0.id == meeting.id }
    let recoveredMeeting = storedMeetings.first { $0.id == interruptedMeeting.id }
    try expect(completedMeeting?.state == .completed, "La reunion doit etre finalisee")
    try expect(
        resumedMeeting.state == .recording && resumedMeeting.endedAt == nil,
        "Une reunion terminee doit pouvoir repasser atomiquement en enregistrement"
    )
    try expect(
        refusedResumeWhileRecording,
        "Une reunion deja en cours ne doit pas pouvoir etre reprise une seconde fois"
    )
    try expect(completedMeeting?.title == "Controle renomme", "La reunion doit pouvoir etre renommee")
    try expect(completedMeeting?.titleOrigin == .user, "Un titre saisi doit etre marque comme utilisateur")
    try expect(
        completedMeeting?.context == "Contexte local conserve pour les traitements futurs.",
        "Le contexte de la reunion doit etre conserve"
    )
    try expect(
        recoveredMeeting?.state == .interrupted,
        "Une reunion orpheline doit etre marquee interrompue"
    )
    try expect(
        recoveredMeeting?.endedAt == recoveryDate,
        "La recuperation doit dater la fin de la reunion interrompue"
    )
    try expect(storedSegments.count == 2, "Les segments direct et batch doivent etre sauvegardes")
    try expect(storedSegments[0].id == segment.id, "L'identifiant du segment doit etre conserve")
    try expect(storedSegments[0].text == segment.text, "Le texte du segment doit etre conserve")
    try expect(storedSegments[0].speakerName == "Jeremy", "Un interlocuteur doit pouvoir etre renomme dans son transcript")
    try expect(firstBlockCommit, "Le premier traitement du bloc audio doit etre valide")
    try expect(!duplicateBlockCommit, "Un bloc audio rejoue ne doit pas dupliquer le transcript")
    try expect(
        storedSegments[1].inputKind == .microphone
            && storedSegments[1].audioBlockID == "block-check",
        "Le canal et le bloc source doivent etre auditables"
    )
    try expect(storedVoiceProfile == voiceProfile, "L'empreinte vocale doit etre conservee")
    try expect(storedVoiceProfiles.count == 2, "Plusieurs voix doivent etre conservees")
    try expect(appliedAutomaticTitle, "Codex doit pouvoir remplacer un titre automatique")
    try expect(!refusedSecondAutomaticTitle, "Codex ne doit jamais remplacer un titre non automatique")
    try expect(storedAIResults == [aiResult], "Le resultat IA doit etre conserve avec la reunion")
    try expect(
        storedChatMessages == [chatQuestion, chatAnswer],
        "La conversation IA doit etre conservee dans son ordre avec la reunion"
    )
    try expect(pendingAIJobs.map(\.kind) == [.title, .summary], "Les jobs IA doivent etre durables et dedoublonnes")
    try await store.completeAIJob(meetingID: meeting.id, kind: .title)
    let remainingAIJobs = try await store.pendingAIJobs()
    try expect(remainingAIJobs.map(\.kind) == [.summary], "Un job IA termine doit quitter la file")
    try expect(
        storedVoiceProfiles.contains { $0.id == participantProfile.id && $0.displayName == "Alice" },
        "Une voix connue doit pouvoir etre renommee"
    )
    try await store.deleteVoiceProfile(id: participantProfile.id)
    let profilesAfterDeletion = try await store.voiceProfiles()
    try expect(
        profilesAfterDeletion.count == 1,
        "Une voix connue doit pouvoir etre oubliee"
    )

    print("OK: CaptureCore checks passed")
} catch let failure as CheckFailure {
    fputs("FAIL: \(failure.message)\n", stderr)
    exit(EXIT_FAILURE)
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
