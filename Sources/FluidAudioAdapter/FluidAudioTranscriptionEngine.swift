import AVFoundation
import CaptureCore
import FluidAudio
import Foundation
import MeetingDomain
import OSLog
import TranscriptionCore

public actor FluidAudioTranscriptionEngine: LiveTranscriptionEngine {
    private let logger = Logger(
        subsystem: "com.jeremy.meeting",
        category: "VoiceIdentity"
    )
    private let transcriptionLogger = Logger(
        subsystem: "com.jeremy.meeting",
        category: "Transcription"
    )

    private struct SpeakerInterval: Sendable {
        let speakerIndex: Int
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    private struct ResolvedSpeaker: Sendable {
        let id: String
        let name: String
        let profileUpdate: VoiceProfile?
        let similarity: Float?
    }

    private var models: AsrModels?
    private var microphoneStream: SlidingWindowAsrManager?
    private var systemStream: SlidingWindowAsrManager?
    private var diarizer: LSEENDDiarizer?
    private var voiceIdentityEngine: CampPlusVoiceIdentityEngine?
    private var voiceProfileTracker: OnlineVoiceProfileTracker
    private var audioChunksByInput: [AudioInputKind: [AudioChunk]] = [:]
    private var speakerIntervals: [SpeakerInterval] = []
    private var updateHandler: (@Sendable (LiveTranscriptionUpdate) async -> Void)?
    private var microphoneUpdatesTask: Task<Void, Never>?
    private var systemUpdatesTask: Task<Void, Never>?
    private var isPrepared = false
    private var isStarted = false

    public init(voiceProfile: VoiceProfile? = nil) {
        voiceProfileTracker = OnlineVoiceProfileTracker(
            profiles: voiceProfile.map { [$0] } ?? []
        )
    }

    public init(voiceProfiles: [VoiceProfile]) {
        voiceProfileTracker = OnlineVoiceProfileTracker(profiles: voiceProfiles)
    }

    public func prepare(
        statusHandler: @escaping @Sendable (TranscriptionEngineStatus) -> Void
    ) async throws {
        guard !isPrepared else { return }

        statusHandler(.loadingModels(nil))
        models = try await AsrModels.downloadAndLoad { progress in
            statusHandler(.loadingModels(FluidAudioProgressMapper.map(progress)))
        }

        statusHandler(.loadingDiarization(nil))
        do {
            try FluidAudioModelCacheRepair.removeInterruptedLSEENDDihard3Bundles()
            let newDiarizer = LSEENDDiarizer()
            try await newDiarizer.initialize(
                variant: .dihard3,
                stepSize: .step200ms,
                computeUnits: .cpuOnly,
                progressHandler: { progress in
                    statusHandler(.loadingDiarization(FluidAudioProgressMapper.map(progress)))
                }
            )
            diarizer = newDiarizer
        } catch {
            diarizer = nil
            statusHandler(
                .warning(
                    "La diarisation locale n'a pas pu etre chargee. "
                        + "Les participants distants seront regroupes. Raison : \(error.localizedDescription)"
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
                    "Les signatures vocales automatiques n'ont pas pu etre chargees. "
                        + "La transcription continuera avec des etiquettes temporaires. "
                        + "Raison : \(error.localizedDescription)"
                )
            )
        }

        isPrepared = true
        statusHandler(.ready(diarizationEnabled: diarizer != nil))
    }

    public func start(
        updateHandler: @escaping @Sendable (LiveTranscriptionUpdate) async -> Void
    ) async throws {
        guard isPrepared, let models else {
            throw FluidAudioEngineError.notPrepared
        }
        guard !isStarted else { return }

        self.updateHandler = updateHandler
        let configuration = FrenchStreamingConfiguration.make()

        let microphoneStream = SlidingWindowAsrManager(config: configuration)
        try await microphoneStream.loadModels(models)
        try await microphoneStream.startStreaming(source: .microphone)

        let systemStream = SlidingWindowAsrManager(config: configuration)
        try await systemStream.loadModels(models)
        try await systemStream.startStreaming(source: .system)
        self.microphoneStream = microphoneStream
        self.systemStream = systemStream

        let microphoneUpdates = await microphoneStream.transcriptionUpdates
        let systemUpdates = await systemStream.transcriptionUpdates

        microphoneUpdatesTask = Task { [weak self] in
            for await update in microphoneUpdates {
                await self?.handle(update, input: .microphone)
            }
        }
        systemUpdatesTask = Task { [weak self] in
            for await update in systemUpdates {
                await self?.handle(update, input: .system)
            }
        }
        isStarted = true
    }

    public func ingest(_ chunk: AudioChunk) async {
        guard isStarted, let buffer = Self.makeBuffer(from: chunk) else { return }

        switch chunk.input {
        case .microphone:
            appendAudio(chunk)
            if let microphoneStream {
                await microphoneStream.streamAudio(buffer)
            }
        case .system:
            appendAudio(chunk)
            if let systemStream {
                await systemStream.streamAudio(buffer)
            }
            processDiarization(chunk)
        }
    }

    public func finish() async {
        if let microphoneStream {
            do {
                _ = try await microphoneStream.finish()
            } catch {
                logger.error("Microphone transcription flush failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let systemStream {
            do {
                _ = try await systemStream.finish()
            } catch {
                logger.error("System transcription flush failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        _ = try? diarizer?.finalizeSession()

        await microphoneStream?.cancel()
        await systemStream?.cancel()
        await microphoneUpdatesTask?.value
        await systemUpdatesTask?.value

        microphoneUpdatesTask = nil
        systemUpdatesTask = nil
        await cleanup()
    }

    public func cancel() async {
        if let microphoneStream {
            await microphoneStream.cancel()
        }
        if let systemStream {
            await systemStream.cancel()
        }
        microphoneUpdatesTask?.cancel()
        systemUpdatesTask?.cancel()
        microphoneUpdatesTask = nil
        systemUpdatesTask = nil
        await cleanup()
    }

    private func cleanup() async {
        await microphoneStream?.cancel()
        await systemStream?.cancel()
        diarizer?.cleanup()
        models = nil
        microphoneStream = nil
        systemStream = nil
        diarizer = nil
        voiceIdentityEngine = nil
        updateHandler = nil
        speakerIntervals.removeAll(keepingCapacity: false)
        audioChunksByInput.removeAll(keepingCapacity: false)
        isPrepared = false
        isStarted = false
    }

    private func processDiarization(_ chunk: AudioChunk) {
        guard let diarizer else { return }

        do {
            guard let update = try diarizer.process(
                samples: chunk.samples,
                sourceSampleRate: Double(chunk.sampleRate)
            ) else {
                return
            }

            for segment in update.finalizedSegments {
                speakerIntervals.append(
                    SpeakerInterval(
                        speakerIndex: segment.speakerIndex,
                        startTime: TimeInterval(segment.startTime),
                        endTime: TimeInterval(segment.endTime)
                    )
                )
            }

            if speakerIntervals.count > 4_000 {
                speakerIntervals.removeFirst(speakerIntervals.count - 4_000)
            }
        } catch {
            // Transcription remains available when diarization skips a chunk.
        }
    }

    private func handle(
        _ update: SlidingWindowTranscriptionUpdate,
        input: AudioInputKind
    ) async {
        let normalizedText = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SlidingWindowPersistencePolicy.shouldPersist(text: normalizedText) else { return }

        let acceptance = FrenchTranscriptAcceptancePolicy.evaluate(
            text: normalizedText,
            transcriptionConfidence: update.confidence
        )
        let formattedConfidence = String(format: "%.3f", update.confidence)
        let detectedLanguage = acceptance.dominantLanguage ?? "unknown"
        guard acceptance.shouldAccept else {
            let formattedLanguageConfidence = String(
                format: "%.3f",
                acceptance.languageConfidence
            )
            transcriptionLogger.notice(
                "Rejected weak foreign-language transcript input=\(input.rawValue, privacy: .public) asr_confidence=\(formattedConfidence, privacy: .public) language=\(detectedLanguage, privacy: .public) language_confidence=\(formattedLanguageConfidence, privacy: .public)"
            )
            return
        }

        transcriptionLogger.info(
            "Accepted transcript input=\(input.rawValue, privacy: .public) asr_confidence=\(formattedConfidence, privacy: .public) language=\(detectedLanguage, privacy: .public)"
        )

        // FluidAudio 0.15.6 emits one disjoint incremental chunk per update.
        // `isConfirmed` only reflects the confidence threshold of that chunk;
        // a volatile update is not a replacement for the previous window.
        let isFinal = SlidingWindowPersistencePolicy.shouldFinalize(
            isConfirmedByModel: update.isConfirmed
        )

        let startTime = update.tokenTimings.first?.startTime ?? 0
        let endTime = update.tokenTimings.last?.endTime ?? startTime
        let speaker = await speakerIdentity(
            for: input,
            startTime: startTime,
            endTime: endTime,
            isFinal: isFinal
        )

        await updateHandler?(
            LiveTranscriptionUpdate(
                input: input,
                text: normalizedText,
                isFinal: isFinal,
                confidence: update.confidence,
                startTime: startTime,
                endTime: max(endTime, startTime),
                speakerID: speaker.id,
                speakerName: speaker.name,
                voiceProfileUpdate: speaker.profileUpdate,
                speakerSimilarity: speaker.similarity
            )
        )
    }

    private func speakerIdentity(
        for input: AudioInputKind,
        startTime: TimeInterval,
        endTime: TimeInterval,
        isFinal: Bool
    ) async -> ResolvedSpeaker {
        let systemSpeakerIndex = input == .system
            ? bestSystemSpeakerIndex(startTime: startTime, endTime: endTime)
            : nil
        let fallback = input == .microphone
            ? ResolvedSpeaker(
                id: "microphone",
                name: "Micro du Mac",
                profileUpdate: nil,
                similarity: nil
            )
            : ResolvedSpeaker(
                id: "remote-\(systemSpeakerIndex ?? 0)",
                name: "Intervenant \((systemSpeakerIndex ?? 0) + 1)",
                profileUpdate: nil,
                similarity: nil
            )

        guard isFinal else {
            return fallback
        }

        guard let voiceIdentityEngine else {
            logger.error("Voice identity skipped: engine unavailable input=\(input.rawValue, privacy: .public)")
            return fallback
        }

        guard let samples = audioSamples(
            input: input,
            startTime: startTime,
            endTime: endTime
        ) else {
            logger.notice(
                "Voice identity skipped: samples unavailable input=\(input.rawValue, privacy: .public) start=\(String(format: "%.2f", startTime), privacy: .public) end=\(String(format: "%.2f", endTime), privacy: .public)"
            )
            return fallback
        }

        let rootMeanSquare = VoiceIdentitySamplePolicy.rootMeanSquare(of: samples)
        guard rootMeanSquare >= VoiceIdentitySamplePolicy.minimumRootMeanSquare else {
            logger.notice(
                "Voice identity skipped: silence input=\(input.rawValue, privacy: .public) rms=\(String(format: "%.5f", rootMeanSquare), privacy: .public) samples=\(samples.count, privacy: .public)"
            )
            return fallback
        }

        do {
            let embedding = try await voiceIdentityEngine.embedding(samples: samples)
            let fixedClusterKey = systemSpeakerIndex.map { "system-\($0)" }
            let resolution = voiceProfileTracker.resolve(
                embedding: embedding,
                fixedClusterKey: fixedClusterKey
            )
            logger.info(
                "Voice identity resolved input=\(input.rawValue, privacy: .public) speaker=\(resolution.profile.displayName, privacy: .public) new=\(resolution.createdNewProfile, privacy: .public) nearest_similarity=\(String(format: "%.4f", resolution.similarity), privacy: .public) rms=\(String(format: "%.5f", rootMeanSquare), privacy: .public) samples=\(samples.count, privacy: .public)"
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

    private func bestSystemSpeakerIndex(
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> Int {
        let bestInterval = speakerIntervals.max { first, second in
            overlap(first, startTime: startTime, endTime: endTime)
                < overlap(second, startTime: startTime, endTime: endTime)
        }
        return bestInterval?.speakerIndex ?? 0
    }

    private func appendAudio(_ chunk: AudioChunk) {
        audioChunksByInput[chunk.input, default: []].append(chunk)
        let cutoff = max(0, chunk.startTime + chunk.duration - 45)
        audioChunksByInput[chunk.input]?.removeAll {
            $0.startTime + $0.duration < cutoff
        }
    }

    private func audioSamples(
        input: AudioInputKind,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> [Float]? {
        guard endTime > startTime else { return nil }
        var result: [Float] = []

        for chunk in audioChunksByInput[input, default: []] {
            let chunkEnd = chunk.startTime + chunk.duration
            let overlapStart = max(startTime, chunk.startTime)
            let overlapEnd = min(endTime, chunkEnd)
            guard overlapEnd > overlapStart else { continue }

            let startIndex = max(
                0,
                Int((overlapStart - chunk.startTime) * Double(chunk.sampleRate))
            )
            let endIndex = min(
                chunk.samples.count,
                Int((overlapEnd - chunk.startTime) * Double(chunk.sampleRate))
            )
            guard endIndex > startIndex else { continue }
            result.append(contentsOf: chunk.samples[startIndex..<endIndex])
        }

        let minimumCount = Int(
            CampPlusVoiceIdentityEngine.minimumVerificationSeconds * 16_000
        )
        return result.count >= minimumCount ? result : nil
    }

    private func overlap(
        _ interval: SpeakerInterval,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> TimeInterval {
        max(0, min(interval.endTime, endTime) - max(interval.startTime, startTime))
    }

    private static func makeBuffer(from chunk: AudioChunk) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(chunk.sampleRate),
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(chunk.samples.count)
            ),
            let channel = buffer.floatChannelData?.pointee
        else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        chunk.samples.withUnsafeBufferPointer { samples in
            guard let source = samples.baseAddress else { return }
            channel.update(from: source, count: samples.count)
        }
        return buffer
    }
}

public enum FluidAudioEngineError: LocalizedError, Sendable {
    case notPrepared

    public var errorDescription: String? {
        switch self {
        case .notPrepared:
            "Le moteur de transcription locale n'est pas prepare."
        }
    }
}
