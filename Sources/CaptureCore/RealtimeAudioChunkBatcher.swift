import Foundation

/// Regroupe les tres petits buffers de capture en paquets reguliers pour l'ASR direct.
/// Le journal durable continue de recevoir les buffers originaux sans attendre ce regroupement.
public struct RealtimeAudioChunkBatcher: Sendable {
    public static let defaultDuration: TimeInterval = 0.1

    private let targetDuration: TimeInterval
    private var samples: [Float] = []
    private var input: AudioInputKind?
    private var sampleRate = 0
    private var nextStartTime: TimeInterval?

    public init(targetDuration: TimeInterval = Self.defaultDuration) {
        self.targetDuration = max(0.02, targetDuration)
    }

    public mutating func append(_ chunk: AudioChunk) -> [AudioChunk] {
        guard !chunk.samples.isEmpty, chunk.sampleRate > 0 else { return [] }

        var batches: [AudioChunk] = []
        if input != nil, (input != chunk.input || sampleRate != chunk.sampleRate) {
            if let remainder = finish() {
                batches.append(remainder)
            }
        }
        if let bufferedStartTime = nextStartTime, sampleRate == chunk.sampleRate {
            let expectedStartTime = bufferedStartTime
                + Double(samples.count) / Double(sampleRate)
            let tolerance = max(0.005, 2 / Double(sampleRate))
            if abs(chunk.startTime - expectedStartTime) > tolerance,
               let remainder = finish() {
                batches.append(remainder)
            }
        }
        if input == nil {
            input = chunk.input
            sampleRate = chunk.sampleRate
            nextStartTime = chunk.startTime
        }
        samples.append(contentsOf: chunk.samples)

        let targetSampleCount = max(1, Int((Double(sampleRate) * targetDuration).rounded()))
        while samples.count >= targetSampleCount,
              let input,
              let startTime = nextStartTime {
            let batchSamples = Array(samples.prefix(targetSampleCount))
            samples.removeFirst(targetSampleCount)
            batches.append(
                AudioChunk(
                    input: input,
                    samples: batchSamples,
                    sampleRate: sampleRate,
                    startTime: startTime
                )
            )
            nextStartTime = startTime + Double(targetSampleCount) / Double(sampleRate)
        }
        return batches
    }

    public mutating func finish() -> AudioChunk? {
        defer { reset() }
        guard !samples.isEmpty,
              let input,
              let startTime = nextStartTime,
              sampleRate > 0
        else { return nil }
        return AudioChunk(
            input: input,
            samples: samples,
            sampleRate: sampleRate,
            startTime: startTime
        )
    }

    private mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        input = nil
        sampleRate = 0
        nextStartTime = nil
    }
}
