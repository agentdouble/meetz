import FluidAudio
import Foundation

public enum FrenchStreamingConfiguration {
    public static let chunkSeconds: TimeInterval = 7
    public static let leftContextSeconds: TimeInterval = 2
    public static let rightContextSeconds: TimeInterval = 1
    public static let expectedFirstUpdateSeconds = chunkSeconds + rightContextSeconds

    public static func make() -> SlidingWindowAsrConfig {
        SlidingWindowAsrConfig(
            chunkSeconds: chunkSeconds,
            hypothesisChunkSeconds: 1,
            leftContextSeconds: leftContextSeconds,
            rightContextSeconds: rightContextSeconds,
            minContextForConfirmation: 4,
            confirmationThreshold: 0.80,
            language: .french
        )
    }
}
