import CaptureCore
import FluidAudio
import Foundation
import OSLog
import TranscriptionCore

public actor FluidAudioRealtimePreviewEngine: RealtimePreviewTranscriptionEngine {
    /// Le tier 2,24 s est le compromis recommande par FluidAudio. Le tier
    /// 560 ms produit plus vite son premier token, mais il ne tient pas le
    /// temps reel sur deux flux complexes et finit par accumuler du retard.
    public static let chunkMilliseconds = 2_240

    private let logger = Logger(
        subsystem: "com.jeremy.meeting",
        category: "RealtimePreview"
    )
    private var sharedModels: SharedNemotronMultilingualModels?
    private var microphoneManager: StreamingNemotronMultilingualAsrManager?
    private var systemManager: StreamingNemotronMultilingualAsrManager?
    private var activeSession: RealtimePreviewSession?
    private var isPrepared = false
    private var isStarted = false

    public init() {}

    public var isReady: Bool { isPrepared }

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

        let session = RealtimePreviewSession(updateHandler: updateHandler)
        activeSession = session
        await microphoneManager.setPartialCallback { text in
            session.emit(text, input: .microphone)
        }
        await systemManager.setPartialCallback { text in
            session.emit(text, input: .system)
        }
        isStarted = true
    }

    public func ingest(_ chunk: AudioChunk) async throws {
        guard isStarted else { return }
        switch chunk.input {
        case .microphone:
            guard let microphoneManager else { return }
            activeSession?.advance(
                input: chunk.input,
                sampleCount: chunk.samples.count,
                sampleRate: chunk.sampleRate
            )
            _ = try await microphoneManager.process(samples: chunk.samples)
            activeSession?.setDetectedLanguage(
                await microphoneManager.detectedLanguage(),
                input: chunk.input
            )
        case .system:
            guard let systemManager else { return }
            activeSession?.advance(
                input: chunk.input,
                sampleCount: chunk.samples.count,
                sampleRate: chunk.sampleRate
            )
            _ = try await systemManager.process(samples: chunk.samples)
            activeSession?.setDetectedLanguage(
                await systemManager.detectedLanguage(),
                input: chunk.input
            )
        }
    }

    public func reset(input: AudioInputKind) async {
        switch input {
        case .microphone:
            await microphoneManager?.reset()
        case .system:
            await systemManager?.reset()
        }
        activeSession?.reset(input: input)
    }

    public func stopSession() async {
        guard isStarted else { return }

        let session = activeSession
        if let microphoneManager {
            do {
                let finalText = try await microphoneManager.finish()
                session?.emit(finalText, input: .microphone)
            } catch {
                logger.error(
                    "Microphone preview flush failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            await microphoneManager.reset()
        }
        if let systemManager {
            do {
                let finalText = try await systemManager.finish()
                session?.emit(finalText, input: .system)
            } catch {
                logger.error(
                    "System preview flush failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            await systemManager.reset()
        }
        session?.deactivate()
        isStarted = false
        activeSession = nil
    }

    public func finish() async {
        await stopSession()
        await microphoneManager?.cleanup()
        await systemManager?.cleanup()
        microphoneManager = nil
        systemManager = nil
        sharedModels = nil
        isPrepared = false
        activeSession?.deactivate()
        activeSession = nil
    }
}

public enum FluidAudioRealtimePreviewError: LocalizedError, Sendable {
    case notPrepared

    public var errorDescription: String? {
        "Le moteur de transcription temps reel n'est pas prepare."
    }
}
