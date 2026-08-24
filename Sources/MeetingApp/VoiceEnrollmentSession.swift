import CaptureCore
import Foundation

actor VoiceEnrollmentSession {
    static let targetSampleRate = 16_000
    static let targetSeconds: TimeInterval = 8

    private let targetSampleCount = Int(targetSeconds * Double(targetSampleRate))
    private var collectedSamples: [Float] = []

    func append(_ chunk: AudioChunk) -> Double {
        guard chunk.input == .microphone,
              chunk.sampleRate == Self.targetSampleRate,
              AudioMath.rootMeanSquare(of: chunk.samples) >= 0.008
        else {
            return progress
        }

        let remaining = max(0, targetSampleCount - collectedSamples.count)
        collectedSamples.append(contentsOf: chunk.samples.prefix(remaining))
        return progress
    }

    var progress: Double {
        min(Double(collectedSamples.count) / Double(targetSampleCount), 1)
    }

    func samples() -> [Float] {
        collectedSamples
    }
}
