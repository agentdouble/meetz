import Dispatch
import Foundation

private final class LatestAudioInputCoalescer<Value: Sendable>: @unchecked Sendable {
    typealias Handler = @Sendable ([Value]) -> Void

    private let lock = NSLock()
    private let deliveryQueue: DispatchQueue
    private let deliveryInterval: TimeInterval
    private let input: @Sendable (Value) -> AudioInputKind
    private var latestValues: [AudioInputKind: Value] = [:]
    private var isDeliveryScheduled = false
    private var generation: UInt64 = 0

    init(
        updatesPerSecond: Double,
        queueLabel: String,
        input: @escaping @Sendable (Value) -> AudioInputKind
    ) {
        let boundedRate = min(max(updatesPerSecond, 1), 30)
        deliveryInterval = 1 / boundedRate
        deliveryQueue = DispatchQueue(label: queueLabel, qos: .userInteractive)
        self.input = input
    }

    func submit(_ value: Value, handler: @escaping Handler) {
        let schedule: (shouldSchedule: Bool, generation: UInt64) = lock.withLock {
            latestValues[input(value)] = value
            guard !isDeliveryScheduled else { return (false, generation) }
            isDeliveryScheduled = true
            return (true, generation)
        }
        guard schedule.shouldSchedule else { return }

        deliveryQueue.asyncAfter(deadline: .now() + deliveryInterval) { [weak self] in
            self?.deliver(generation: schedule.generation, handler: handler)
        }
    }

    func cancel() {
        lock.withLock {
            generation &+= 1
            latestValues.removeAll(keepingCapacity: true)
            isDeliveryScheduled = false
        }
    }

    private func deliver(generation expectedGeneration: UInt64, handler: Handler) {
        let values: [Value]? = lock.withLock {
            guard generation == expectedGeneration else { return nil }
            let values = AudioInputKind.allCases.compactMap { latestValues[$0] }
            latestValues.removeAll(keepingCapacity: true)
            isDeliveryScheduled = false
            return values
        }
        guard let values, !values.isEmpty else { return }
        handler(values)
    }
}

/// Regroupe les niveaux audio tres frequents avant de les transmettre a une UI.
/// Les echantillons audio eux-memes ne passent jamais par ce composant.
public final class AudioLevelCoalescer: @unchecked Sendable {
    public typealias Handler = @Sendable ([AudioLevelSnapshot]) -> Void

    private let coalescer: LatestAudioInputCoalescer<AudioLevelSnapshot>

    public init(updatesPerSecond: Double = 10) {
        coalescer = LatestAudioInputCoalescer(
            updatesPerSecond: updatesPerSecond,
            queueLabel: "meeting.audio-level-coalescer",
            input: { $0.input }
        )
    }

    public func submit(_ snapshot: AudioLevelSnapshot, handler: @escaping Handler) {
        coalescer.submit(snapshot, handler: handler)
    }

    /// Invalide aussi toute livraison deja planifiee par une ancienne capture.
    public func cancel() {
        coalescer.cancel()
    }
}

/// Progression legere du moteur direct, sans conserver les echantillons audio.
public struct AudioProcessingProgress: Sendable, Equatable {
    public let input: AudioInputKind
    public let processedDuration: TimeInterval

    public init(input: AudioInputKind, processedDuration: TimeInterval) {
        self.input = input
        self.processedDuration = max(0, processedDuration)
    }
}

/// Borne les rafraichissements de retard sans jamais faire attendre le moteur ASR.
public final class AudioProgressCoalescer: @unchecked Sendable {
    public typealias Handler = @Sendable ([AudioProcessingProgress]) -> Void

    private let coalescer: LatestAudioInputCoalescer<AudioProcessingProgress>

    public init(updatesPerSecond: Double = 2) {
        coalescer = LatestAudioInputCoalescer(
            updatesPerSecond: updatesPerSecond,
            queueLabel: "meeting.audio-progress-coalescer",
            input: { $0.input }
        )
    }

    public func submit(_ progress: AudioProcessingProgress, handler: @escaping Handler) {
        coalescer.submit(progress, handler: handler)
    }

    public func cancel() {
        coalescer.cancel()
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
