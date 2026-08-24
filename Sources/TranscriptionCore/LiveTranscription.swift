import CaptureCore
import Foundation
import MeetingDomain

public struct LiveTranscriptionUpdate: Sendable, Equatable {
    public let input: AudioInputKind
    public let text: String
    public let isFinal: Bool
    public let confidence: Float
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let speakerID: String
    public let speakerName: String
    public let voiceProfileUpdate: VoiceProfile?
    public let speakerSimilarity: Float?

    public init(
        input: AudioInputKind,
        text: String,
        isFinal: Bool,
        confidence: Float,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speakerID: String,
        speakerName: String,
        voiceProfileUpdate: VoiceProfile? = nil,
        speakerSimilarity: Float? = nil
    ) {
        self.input = input
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.startTime = startTime
        self.endTime = endTime
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.voiceProfileUpdate = voiceProfileUpdate
        self.speakerSimilarity = speakerSimilarity
    }
}

public struct ModelPreparationProgress: Sendable, Equatable {
    public enum Activity: Sendable, Equatable {
        case listing
        case downloading(completedFiles: Int, totalFiles: Int)
        case compiling(modelName: String)
    }

    public let fractionCompleted: Double
    public let activity: Activity

    public init(fractionCompleted: Double, activity: Activity) {
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
        self.activity = activity
    }
}

public enum TranscriptionEngineStatus: Sendable, Equatable {
    case loadingModels(ModelPreparationProgress?)
    case loadingRealtime(ModelPreparationProgress?)
    case loadingDiarization(ModelPreparationProgress?)
    case loadingVoiceIdentity(ModelPreparationProgress?)
    case ready(diarizationEnabled: Bool)
    case warning(String)
}

public struct RealtimeTranscriptPreview: Sendable, Equatable {
    public let input: AudioInputKind
    public let text: String
    public let processedAudioDuration: TimeInterval

    public init(
        input: AudioInputKind,
        text: String,
        processedAudioDuration: TimeInterval = 0
    ) {
        self.input = input
        self.text = text
        self.processedAudioDuration = processedAudioDuration
    }
}

public protocol RealtimePreviewTranscriptionEngine: Sendable {
    func prepare(
        statusHandler: @escaping @Sendable (TranscriptionEngineStatus) -> Void
    ) async throws
    func start(
        updateHandler: @escaping @Sendable (RealtimeTranscriptPreview) -> Void
    ) async throws
    func ingest(_ chunk: AudioChunk) async throws
    func reset(input: AudioInputKind) async
    func finish() async
}

public protocol LiveTranscriptionEngine: Sendable {
    func prepare(
        statusHandler: @escaping @Sendable (TranscriptionEngineStatus) -> Void
    ) async throws

    func start(
        updateHandler: @escaping @Sendable (LiveTranscriptionUpdate) async -> Void
    ) async throws

    func ingest(_ chunk: AudioChunk) async
    func finish() async
    func cancel() async
}

public protocol RecordedAudioTranscriptionEngine: Sendable {
    func prepare(
        statusHandler: @escaping @Sendable (TranscriptionEngineStatus) -> Void
    ) async throws

    func transcribe(_ block: RecordedAudioBlock) async throws -> [LiveTranscriptionUpdate]
    func finish() async
}
