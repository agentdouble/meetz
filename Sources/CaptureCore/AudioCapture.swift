import Foundation

public enum AudioInputKind: String, Sendable, Hashable, CaseIterable {
    case system
    case microphone

    public var displayName: String {
        switch self {
        case .system:
            "Son du Mac"
        case .microphone:
            "Microphone"
        }
    }
}

public struct AudioLevelSnapshot: Sendable, Equatable {
    public let input: AudioInputKind
    public let linearLevel: Double
    public let bufferCount: UInt64

    public init(input: AudioInputKind, linearLevel: Double, bufferCount: UInt64) {
        self.input = input
        self.linearLevel = min(max(linearLevel, 0), 1)
        self.bufferCount = bufferCount
    }
}

public struct AudioChunk: Sendable, Equatable {
    public let input: AudioInputKind
    public let samples: [Float]
    public let sampleRate: Int
    public let startTime: TimeInterval

    public init(
        input: AudioInputKind,
        samples: [Float],
        sampleRate: Int,
        startTime: TimeInterval
    ) {
        self.input = input
        self.samples = samples
        self.sampleRate = sampleRate
        self.startTime = startTime
    }

    public var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / Double(sampleRate)
    }
}

public enum AudioCaptureEvent: Sendable, Equatable {
    case level(AudioLevelSnapshot)
    case samples(AudioChunk)
    case stopped(reason: String)
}

public protocol AudioCaptureSource: Sendable {
    func start(
        eventHandler: @escaping @Sendable (AudioCaptureEvent) -> Void
    ) async throws

    func stop() async
}

public enum AudioMath {
    public static func rootMeanSquare<C: Collection>(of samples: C) -> Double
    where C.Element == Float {
        guard !samples.isEmpty else { return 0 }

        let squareSum = samples.reduce(0.0) { partialResult, sample in
            let value = Double(sample)
            return partialResult + value * value
        }

        return sqrt(squareSum / Double(samples.count))
    }

    public static func meterLevel(fromRootMeanSquare rms: Double) -> Double {
        guard rms > 0 else { return 0 }

        let decibels = 20 * log10(rms)
        let minimumDecibels = -60.0
        let normalized = (decibels - minimumDecibels) / -minimumDecibels
        return min(max(normalized, 0), 1)
    }
}
