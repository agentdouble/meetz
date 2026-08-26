import AudioJournal
import CaptureCore
import Foundation
import TranscriptionCore

/// Workers audio sans dependance a SwiftUI ni au MainActor.
/// Le journal durable et le moteur direct continuent donc de progresser meme
/// lorsque l'interface effectue un rendu couteux, par exemple pendant un chat.
enum MeetingAudioPipelineWorker {
    typealias FailureHandler = @Sendable (any Error) async -> Void
    typealias ProgressHandler = @Sendable (AudioProcessingProgress) -> Void

    static func runJournal(
        stream: AsyncStream<AudioChunk>,
        meetingID: UUID,
        timeOffset: TimeInterval,
        journal: DurableAudioJournal,
        deferredQueue: DeferredAudioBlockQueue,
        onFailure: @escaping FailureHandler
    ) async {
        var batcher = RealtimeAudioChunkBatcher()
        for await chunk in stream {
            for batch in batcher.append(chunk) {
                await appendToJournal(
                    batch,
                    meetingID: meetingID,
                    timeOffset: timeOffset,
                    journal: journal,
                    deferredQueue: deferredQueue,
                    onFailure: onFailure
                )
            }
        }
        if let remainder = batcher.finish() {
            await appendToJournal(
                remainder,
                meetingID: meetingID,
                timeOffset: timeOffset,
                journal: journal,
                deferredQueue: deferredQueue,
                onFailure: onFailure
            )
        }
    }

    static func runPreview(
        stream: AsyncStream<AudioChunk>,
        engine: any RealtimePreviewTranscriptionEngine,
        onProgress: @escaping ProgressHandler,
        onFailure: @escaping FailureHandler
    ) async {
        var batcher = RealtimeAudioChunkBatcher()
        for await chunk in stream {
            for batch in batcher.append(chunk) {
                await ingest(
                    batch,
                    engine: engine,
                    onProgress: onProgress,
                    onFailure: onFailure
                )
            }
        }
        if let remainder = batcher.finish() {
            await ingest(
                remainder,
                engine: engine,
                onProgress: onProgress,
                onFailure: onFailure
            )
        }
    }

    private static func appendToJournal(
        _ chunk: AudioChunk,
        meetingID: UUID,
        timeOffset: TimeInterval,
        journal: DurableAudioJournal,
        deferredQueue: DeferredAudioBlockQueue,
        onFailure: FailureHandler
    ) async {
        do {
            let journalChunk = offset(chunk, by: timeOffset)
            let blocks = try await journal.append(journalChunk, meetingID: meetingID)
            await deferredQueue.enqueue(contentsOf: blocks)
        } catch {
            await onFailure(error)
        }
    }

    private static func ingest(
        _ chunk: AudioChunk,
        engine: any RealtimePreviewTranscriptionEngine,
        onProgress: ProgressHandler,
        onFailure: FailureHandler
    ) async {
        do {
            try await engine.ingest(chunk)
            onProgress(
                AudioProcessingProgress(
                    input: chunk.input,
                    processedDuration: chunk.startTime + chunk.duration
                )
            )
        } catch {
            await onFailure(error)
        }
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
}
