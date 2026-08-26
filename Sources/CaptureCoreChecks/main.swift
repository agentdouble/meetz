import AudioJournal
import CaptureCore
import Darwin
import Foundation
import MeetingDomain
import TranscriptStore

private struct CheckFailure: Error {
    let message: String
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

    let journalRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("meeting-audio-journal-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: journalRoot) }
    let journal = try DurableAudioJournal(
        rootURL: journalRoot,
        configuration: .init(
            minimumBlockDuration: 0.5,
            maximumBlockDuration: 1,
            quietRootMeanSquare: 0.001,
            synchronizationInterval: 0.1
        )
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
