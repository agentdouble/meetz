import Foundation

public enum SlidingWindowPersistencePolicy {
    public static func shouldPersist(text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func shouldFinalize(isConfirmedByModel: Bool) -> Bool {
        // FluidAudio 0.15.6 uses this flag as a confidence classification.
        // Every emitted window is incremental and must be persisted exactly once.
        _ = isConfirmedByModel
        return true
    }
}
