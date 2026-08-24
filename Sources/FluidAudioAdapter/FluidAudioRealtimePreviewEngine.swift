import CaptureCore
import FluidAudio
import Foundation
import OSLog
import TranscriptionCore

public actor FluidAudioRealtimePreviewEngine: RealtimePreviewTranscriptionEngine {
    public static let chunkMilliseconds = 2_240

    private let logger = Logger(
        subsystem: "com.jeremy.meeting",
        category: "RealtimePreview"
    )
    private var sharedModels: SharedNemotronMultilingualModels?
    private var microphoneManager: StreamingNemotronMultilingualAsrManager?
    private var systemManager: StreamingNemotronMultilingualAsrManager?
    private let microphoneClock = RealtimeAudioClock()
    private let systemClock = RealtimeAudioClock()
    private var isPrepared = false
    private var isStarted = false

    public init() {}

    public func prepare(
        statusHandler: @escaping @Sendable (TranscriptionEngineStatus) -> Void
    ) async throws {
        guard !isPrepared else { return }

        statusHandler(.loadingRealtime(nil))
        let sharedModels = try await StreamingNemotronMultilingualAsrManager
            .downloadAndPreloadShared(
                languageCode: "fr",
                chunkMs: Self.chunkMilliseconds,
                progressHandler: { progress in
                    statusHandler(.loadingRealtime(FluidAudioProgressMapper.map(progress)))
                }
            )
        self.sharedModels = sharedModels

        let microphoneManager = StreamingNemotronMultilingualAsrManager()
        try await microphoneManager.loadFromShared(sharedModels)
        await microphoneManager.setLanguage("auto")

        let systemManager = StreamingNemotronMultilingualAsrManager()
        try await systemManager.loadFromShared(sharedModels)
        await systemManager.setLanguage("auto")

        self.microphoneManager = microphoneManager
        self.systemManager = systemManager
        isPrepared = true
        statusHandler(.ready(diarizationEnabled: true))
    }

    public func start(
        updateHandler: @escaping @Sendable (RealtimeTranscriptPreview) -> Void
    ) async throws {
        guard isPrepared,
              let microphoneManager,
              let systemManager
        else {
            throw FluidAudioRealtimePreviewError.notPrepared
        }
        guard !isStarted else { return }

        await microphoneManager.setPartialCallback { text in
            updateHandler(
                RealtimeTranscriptPreview(
                    input: .microphone,
                    text: text,
                    processedAudioDuration: self.microphoneClock.duration
                )
            )
        }
        await systemManager.setPartialCallback { text in
            updateHandler(
                RealtimeTranscriptPreview(
                    input: .system,
                    text: text,
                    processedAudioDuration: self.systemClock.duration
                )
            )
        }
        isStarted = true
    }

    public func ingest(_ chunk: AudioChunk) async throws {
        guard isStarted else { return }
        switch chunk.input {
        case .microphone:
            guard let microphoneManager else { return }
            microphoneClock.advance(sampleCount: chunk.samples.count, sampleRate: chunk.sampleRate)
            _ = try await microphoneManager.process(samples: chunk.samples)
        case .system:
            guard let systemManager else { return }
            systemClock.advance(sampleCount: chunk.samples.count, sampleRate: chunk.sampleRate)
            _ = try await systemManager.process(samples: chunk.samples)
        }
    }

    public func reset(input: AudioInputKind) async {
        switch input {
        case .microphone:
            await microphoneManager?.reset()
            microphoneClock.reset()
        case .system:
            await systemManager?.reset()
            systemClock.reset()
        }
    }

    public func finish() async {
        if let microphoneManager {
            do {
                _ = try await microphoneManager.finish()
            } catch {
                logger.error(
                    "Microphone preview flush failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            await microphoneManager.cleanup()
        }
        if let systemManager {
            do {
                _ = try await systemManager.finish()
            } catch {
                logger.error(
                    "System preview flush failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            await systemManager.cleanup()
        }
        microphoneManager = nil
        systemManager = nil
        sharedModels = nil
        isPrepared = false
        isStarted = false
        microphoneClock.reset()
        systemClock.reset()
    }
}

private final class RealtimeAudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var sampleDuration: TimeInterval = 0

    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return sampleDuration
    }

    func advance(sampleCount: Int, sampleRate: Int) {
        guard sampleCount > 0, sampleRate > 0 else { return }
        lock.lock()
        sampleDuration += Double(sampleCount) / Double(sampleRate)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        sampleDuration = 0
        lock.unlock()
    }
}

public enum FluidAudioRealtimePreviewError: LocalizedError, Sendable {
    case notPrepared

    public var errorDescription: String? {
        "Le moteur de transcription temps reel n'est pas prepare."
    }
}
