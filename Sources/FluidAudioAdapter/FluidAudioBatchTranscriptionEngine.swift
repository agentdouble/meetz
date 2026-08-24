import CaptureCore
import FluidAudio
import Foundation
import MeetingDomain
import OSLog
import TranscriptionCore

public actor FluidAudioBatchTranscriptionEngine: RecordedAudioTranscriptionEngine {
    private struct SpeakerInterval: Sendable {
        let speakerIndex: Int
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    private struct WordGroup: Sendable {
        var speakerIndex: Int
        var words: [String]
        var startTime: TimeInterval
        var endTime: TimeInterval
    }

    private struct ResolvedSpeaker: Sendable {
        let id: String
        let name: String
        let profileUpdate: VoiceProfile?
        let similarity: Float?
    }

    private let logger = Logger(
        subsystem: "com.jeremy.meeting",
        category: "BatchTranscription"
    )
    private var models: AsrModels?
    private var asrManager: AsrManager?
    private var diarizer: LSEENDDiarizer?
    private var voiceIdentityEngine: CampPlusVoiceIdentityEngine?
    private var voiceProfileTracker: OnlineVoiceProfileTracker
    private var isPrepared = false

    public init(voiceProfiles: [VoiceProfile]) {
        voiceProfileTracker = OnlineVoiceProfileTracker(profiles: voiceProfiles)
    }

    public func prepare(
        statusHandler: @escaping @Sendable (TranscriptionEngineStatus) -> Void
    ) async throws {
        guard !isPrepared else { return }

        statusHandler(.loadingModels(nil))
        let models = try await AsrModels.downloadAndLoad { progress in
            statusHandler(.loadingModels(FluidAudioProgressMapper.map(progress)))
        }
        self.models = models
        asrManager = AsrManager(
            config: ASRConfig(
                streamingEnabled: true,
                streamingThreshold: 480_000,
                melChunkContext: false,
                dualDecodeArbitration: false,
                seamGapRepair: true
            ),
            models: models
        )

        statusHandler(.loadingDiarization(nil))
        do {
            try FluidAudioModelCacheRepair.removeInterruptedLSEENDDihard3Bundles()
            let diarizer = LSEENDDiarizer()
            try await diarizer.initialize(
                variant: .dihard3,
                stepSize: .step200ms,
                computeUnits: .cpuOnly,
                progressHandler: { progress in
                    statusHandler(.loadingDiarization(FluidAudioProgressMapper.map(progress)))
                }
            )
            self.diarizer = diarizer
        } catch {
            diarizer = nil
            statusHandler(
                .warning(
                    "La diarisation locale n'a pas pu etre chargee. "
                        + "Les participants distants seront regroupes. Raison : "
                        + error.localizedDescription
                )
            )
        }

        statusHandler(.loadingVoiceIdentity(nil))
        do {
            voiceIdentityEngine = try await CampPlusVoiceIdentityEngine.load { progress in
                statusHandler(.loadingVoiceIdentity(progress))
            }
        } catch {
            voiceIdentityEngine = nil
            statusHandler(
                .warning(
                    "Les signatures vocales automatiques ne sont pas disponibles. "
                        + "La transcription continuera avec des etiquettes temporaires."
                )
            )
        }

        isPrepared = true
        statusHandler(.ready(diarizationEnabled: diarizer != nil))
    }

    public func transcribe(
        _ block: RecordedAudioBlock
    ) async throws -> [LiveTranscriptionUpdate] {
        guard isPrepared, let asrManager else {
            throw FluidAudioBatchEngineError.notPrepared
        }

        let decoderLayerCount = await asrManager.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayerCount)
        let startedAt = ContinuousClock.now
        let result = try await asrManager.transcribe(
            block.fileURL,
            decoderState: &decoderState,
            language: nil
        )
        let normalizedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            logger.info(
                "Audio block contains no detected speech block=\(block.id, privacy: .public) input=\(block.input.rawValue, privacy: .public)"
            )
            return []
        }

        let samples = try AudioConverter().resampleAudioFile(block.fileURL)
        let elapsed = startedAt.duration(to: .now)
        logger.info(
            "Audio block transcribed block=\(block.id, privacy: .public) input=\(block.input.rawValue, privacy: .public) audio_seconds=\(String(format: "%.2f", block.duration), privacy: .public) elapsed=\(String(describing: elapsed), privacy: .public) confidence=\(String(format: "%.3f", result.confidence), privacy: .public)"
        )

        switch block.input {
        case .microphone:
            return [
                await microphoneUpdate(
                    block: block,
                    result: result,
                    text: normalizedText,
                    samples: samples
                )
            ]
        case .system:
            return await systemUpdates(
                block: block,
                result: result,
                text: normalizedText,
                samples: samples
            )
        }
    }

    public func finish() async {
        diarizer?.cleanup()
        models = nil
        asrManager = nil
        diarizer = nil
        voiceIdentityEngine = nil
        isPrepared = false
    }

    private func microphoneUpdate(
        block: RecordedAudioBlock,
        result: ASRResult,
        text: String,
        samples: [Float]
    ) async -> LiveTranscriptionUpdate {
        let bounds = transcriptBounds(
            tokenTimings: result.tokenTimings,
            fallbackDuration: block.duration
        )
        let speaker = await resolveSpeaker(
            input: .microphone,
            speakerIndex: nil,
            fixedClusterKey: nil,
            samples: sampleSlice(samples, start: bounds.start, end: bounds.end)
        )
        return LiveTranscriptionUpdate(
            input: .microphone,
            text: text,
            isFinal: true,
            confidence: result.confidence,
            startTime: block.startTime + bounds.start,
            endTime: block.startTime + bounds.end,
            speakerID: speaker.id,
            speakerName: speaker.name,
            voiceProfileUpdate: speaker.profileUpdate,
            speakerSimilarity: speaker.similarity
        )
    }

    private func systemUpdates(
        block: RecordedAudioBlock,
        result: ASRResult,
        text: String,
        samples: [Float]
    ) async -> [LiveTranscriptionUpdate] {
        let intervals = diarizationIntervals(for: block)
        let words = buildWordTimings(from: result.tokenTimings ?? [])
        let groups = groupWords(words, intervals: intervals)

        guard !groups.isEmpty else {
            let bounds = transcriptBounds(
                tokenTimings: result.tokenTimings,
                fallbackDuration: block.duration
            )
            let speakerIndex = bestSpeakerIndex(
                startTime: bounds.start,
                endTime: bounds.end,
                intervals: intervals
            ) ?? 0
            let speaker = await resolveSpeaker(
                input: .system,
                speakerIndex: speakerIndex,
                fixedClusterKey: "\(block.id)-speaker-\(speakerIndex)",
                samples: sampleSlice(samples, start: bounds.start, end: bounds.end)
            )
            return [
                LiveTranscriptionUpdate(
                    input: .system,
                    text: text,
                    isFinal: true,
                    confidence: result.confidence,
                    startTime: block.startTime + bounds.start,
                    endTime: block.startTime + bounds.end,
                    speakerID: speaker.id,
                    speakerName: speaker.name,
                    voiceProfileUpdate: speaker.profileUpdate,
                    speakerSimilarity: speaker.similarity
                )
            ]
        }

        var updates: [LiveTranscriptionUpdate] = []
        updates.reserveCapacity(groups.count)
        for group in groups {
            let speaker = await resolveSpeaker(
                input: .system,
                speakerIndex: group.speakerIndex,
                fixedClusterKey: "\(block.id)-speaker-\(group.speakerIndex)",
                samples: sampleSlice(samples, start: group.startTime, end: group.endTime)
            )
            updates.append(
                LiveTranscriptionUpdate(
                    input: .system,
                    text: group.words.joined(separator: " "),
                    isFinal: true,
                    confidence: result.confidence,
                    startTime: block.startTime + group.startTime,
                    endTime: block.startTime + group.endTime,
                    speakerID: speaker.id,
                    speakerName: speaker.name,
                    voiceProfileUpdate: speaker.profileUpdate,
                    speakerSimilarity: speaker.similarity
                )
            )
        }
        return updates
    }

    private func diarizationIntervals(for block: RecordedAudioBlock) -> [SpeakerInterval] {
        guard let diarizer else { return [] }
        do {
            let timeline = try diarizer.processComplete(
                audioFileURL: block.fileURL,
                keepingEnrolledSpeakers: false,
                finalizeOnCompletion: true
            )
            return timeline.speakers.values.flatMap { speaker in
                speaker.finalizedSegments.map {
                    SpeakerInterval(
                        speakerIndex: $0.speakerIndex,
                        startTime: TimeInterval($0.startTime),
                        endTime: TimeInterval($0.endTime)
                    )
                }
            }
        } catch {
            logger.error(
                "Diarization failed for block=\(block.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    private func groupWords(
        _ words: [WordTiming],
        intervals: [SpeakerInterval]
    ) -> [WordGroup] {
        var groups: [WordGroup] = []
        for word in words {
            let speakerIndex = bestSpeakerIndex(
                startTime: word.startTime,
                endTime: word.endTime,
                intervals: intervals
            ) ?? 0
            if var last = groups.last, last.speakerIndex == speakerIndex {
                last.words.append(word.word)
                last.endTime = word.endTime
                groups[groups.count - 1] = last
            } else {
                groups.append(
                    WordGroup(
                        speakerIndex: speakerIndex,
                        words: [word.word],
                        startTime: word.startTime,
                        endTime: word.endTime
                    )
                )
            }
        }
        return groups
    }

    private func bestSpeakerIndex(
        startTime: TimeInterval,
        endTime: TimeInterval,
        intervals: [SpeakerInterval]
    ) -> Int? {
        intervals.max { first, second in
            overlap(first, startTime: startTime, endTime: endTime)
                < overlap(second, startTime: startTime, endTime: endTime)
        }?.speakerIndex
    }

    private func overlap(
        _ interval: SpeakerInterval,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> TimeInterval {
        max(0, min(interval.endTime, endTime) - max(interval.startTime, startTime))
    }

    private func resolveSpeaker(
        input: AudioInputKind,
        speakerIndex: Int?,
        fixedClusterKey: String?,
        samples: [Float]
    ) async -> ResolvedSpeaker {
        let fallback: ResolvedSpeaker = input == .microphone
            ? ResolvedSpeaker(
                id: "microphone",
                name: "Micro du Mac",
                profileUpdate: nil,
                similarity: nil
            )
            : ResolvedSpeaker(
                id: "remote-\(speakerIndex ?? 0)",
                name: "Intervenant \((speakerIndex ?? 0) + 1)",
                profileUpdate: nil,
                similarity: nil
            )

        guard VoiceIdentitySamplePolicy.accepts(samples),
              let voiceIdentityEngine
        else { return fallback }

        do {
            let embedding = try await voiceIdentityEngine.embedding(samples: samples)
            let resolution = voiceProfileTracker.resolve(
                embedding: embedding,
                fixedClusterKey: fixedClusterKey
            )
            return ResolvedSpeaker(
                id: resolution.profile.id,
                name: resolution.profile.displayName,
                profileUpdate: resolution.profile,
                similarity: resolution.similarity
            )
        } catch {
            logger.error(
                "Voice identity failed input=\(input.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return fallback
        }
    }

    private func transcriptBounds(
        tokenTimings: [TokenTiming]?,
        fallbackDuration: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval) {
        guard let tokenTimings, !tokenTimings.isEmpty else {
            return (0, fallbackDuration)
        }
        let start = max(0, tokenTimings.first?.startTime ?? 0)
        let end = min(
            fallbackDuration,
            max(start, tokenTimings.last?.endTime ?? fallbackDuration)
        )
        return (start, end)
    }

    private func sampleSlice(
        _ samples: [Float],
        start: TimeInterval,
        end: TimeInterval
    ) -> [Float] {
        let startIndex = min(samples.count, max(0, Int(start * 16_000)))
        let endIndex = min(samples.count, max(startIndex, Int(end * 16_000)))
        return Array(samples[startIndex..<endIndex])
    }
}

public enum FluidAudioBatchEngineError: LocalizedError, Sendable {
    case notPrepared

    public var errorDescription: String? {
        "Le moteur batch local n'est pas prepare."
    }
}
