import CaptureCore
import FluidAudioAdapter
import Foundation
import MeetingDomain
import TranscriptionCore

@main
struct MeetingModelCheck {
    static func main() async throws {
        var realtimeSegmenter = RealtimeTranscriptSegmenter(
            meetingID: UUID(),
            input: .microphone,
            segmentDuration: 20
        )
        let firstRealtime = realtimeSegmenter.ingest(
            cumulativeText: "Bonjour, ceci est le direct.",
            processedAudioDuration: 2.24
        )
        let closedRealtime = realtimeSegmenter.ingest(
            cumulativeText: "Bonjour, ceci est le direct. La suite reste exploitable.",
            processedAudioDuration: 20.16
        )
        let nextRealtime = realtimeSegmenter.ingest(
            cumulativeText: "Bonjour, ceci est le direct. La suite reste exploitable. Nouveau segment.",
            processedAudioDuration: 22.4
        )
        guard firstRealtime?.source == .realtime,
              closedRealtime?.id == firstRealtime?.id,
              closedRealtime?.text.contains("suite reste exploitable") == true,
              nextRealtime?.id != closedRealtime?.id,
              nextRealtime?.startTime == closedRealtime?.endTime,
              nextRealtime?.text == "Nouveau segment."
        else {
            throw ModelCheckError.invalidRealtimeSegmentation
        }
        print("ready realtime-persistence-segmentation=true")

        let identityEngine = try await CampPlusVoiceIdentityEngine.load { progress in
            print(progressDescription("voice identity", progress: progress))
        }
        let enrollmentSamples = syntheticVoiceSamples()
        let voiceProfile = try await identityEngine.createProfile(
            samples: enrollmentSamples,
            sampleRate: 16_000
        )
        let selfSimilarity = try await identityEngine.similarity(
            samples: enrollmentSamples,
            profile: voiceProfile
        )
        print("voice-identity synthetic similarity=\(selfSimilarity)")
        guard voiceProfile.embedding.count == CampPlusVoiceIdentityEngine.embeddingDimension,
              selfSimilarity.isFinite,
              selfSimilarity >= CampPlusVoiceIdentityEngine.conservativeSimilarityThreshold
        else {
            throw ModelCheckError.invalidVoiceEmbedding
        }
        print("ready voice-identity=true similarity=\(selfSimilarity)")

        let quietVoiceSamples = enrollmentSamples.map { $0 * 0.01 }
        guard VoiceIdentitySamplePolicy.accepts(quietVoiceSamples),
              !VoiceIdentitySamplePolicy.accepts([Float](repeating: 0, count: 32_000))
        else {
            throw ModelCheckError.invalidVoiceSamplePolicy
        }
        let quietEmbedding = try await identityEngine.embedding(
            samples: Array(quietVoiceSamples.prefix(32_000))
        )
        guard quietEmbedding.count == CampPlusVoiceIdentityEngine.embeddingDimension,
              quietEmbedding.allSatisfy(\.isFinite)
        else {
            throw ModelCheckError.invalidVoiceEmbedding
        }
        print("ready quiet-voice-identity=true")

        let candidateEmbedding = try await identityEngine.embedding(
            samples: Array(enrollmentSamples.prefix(16_000 * 2))
        )
        var tracker = OnlineVoiceProfileTracker(profiles: [voiceProfile])
        let firstResolution = tracker.resolve(
            embedding: candidateEmbedding,
            fixedClusterKey: "system-0"
        )
        let secondResolution = tracker.resolve(
            embedding: candidateEmbedding,
            fixedClusterKey: "system-0"
        )
        guard firstResolution.profile.id == voiceProfile.id,
              secondResolution.profile.id == voiceProfile.id,
              secondResolution.profile.sampleCount > voiceProfile.sampleCount
        else {
            throw ModelCheckError.invalidVoiceClustering
        }
        print("ready voice-clustering=true profile=\(secondResolution.profile.id)")

        let reuseBaseline = VoiceProfile(
            id: "reuse-baseline",
            displayName: "Jeremy",
            embedding: [1, 0]
        )
        var reuseTracker = OnlineVoiceProfileTracker(profiles: [reuseBaseline])
        let borderlineCandidate: [Float] = [0.715, 0.699]
        let reuseResolution = reuseTracker.resolve(
            embedding: borderlineCandidate,
            fixedClusterKey: nil
        )
        guard reuseResolution.profile.id == reuseBaseline.id else {
            throw ModelCheckError.invalidVoiceClustering
        }
        print("ready voice-reuse-threshold=true similarity=\(reuseResolution.similarity)")

        let engine = FluidAudioBatchTranscriptionEngine(
            voiceProfiles: [secondResolution.profile]
        )

        try await engine.prepare { status in
            print(description(for: status))
        }

        await engine.finish()
        print("ready recorded-audio-batch=true bilingual-filter=false")
        print("OK: local batch transcription models are ready")
    }

    private static func description(for status: TranscriptionEngineStatus) -> String {
        switch status {
        case let .loadingModels(progress):
            return progressDescription("transcription", progress: progress)
        case let .loadingRealtime(progress):
            return progressDescription("realtime", progress: progress)
        case let .loadingDiarization(progress):
            return progressDescription("diarization", progress: progress)
        case let .loadingVoiceIdentity(progress):
            return progressDescription("voice identity", progress: progress)
        case let .ready(diarizationEnabled):
            return "ready diarization=\(diarizationEnabled)"
        case let .warning(message):
            return "warning: \(message)"
        }
    }

    private static func progressDescription(
        _ name: String,
        progress: ModelPreparationProgress?
    ) -> String {
        guard let progress else { return "\(name): starting" }
        let percentage = Int((progress.fractionCompleted * 100).rounded())

        switch progress.activity {
        case .listing:
            return "\(name): listing"
        case let .downloading(completedFiles, totalFiles):
            return "\(name): downloading \(percentage)% (\(completedFiles)/\(totalFiles))"
        case let .compiling(modelName):
            return "\(name): compiling \(percentage)% \(modelName)"
        }
    }

    private static func syntheticVoiceSamples() -> [Float] {
        let sampleRate = 16_000.0
        return (0..<Int(sampleRate * 6)).map { index in
            let time = Double(index) / sampleRate
            let envelope = 0.45 + 0.35 * sin(2 * .pi * 3 * time)
            return Float(
                envelope
                    * (0.55 * sin(2 * .pi * 180 * time)
                        + 0.25 * sin(2 * .pi * 310 * time))
            )
        }
    }
}

private enum ModelCheckError: Error {
    case invalidVoiceEmbedding
    case invalidVoiceClustering
    case invalidVoiceSamplePolicy
    case invalidRealtimeSegmentation
}
