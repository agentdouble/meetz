import Foundation

/// Compteur thread-safe pour observer la saturation d'une file audio sans
/// creer une tache MainActor pour chaque paquet abandonne.
public final class AudioChunkDropCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [AudioInputKind: Int] = [:]

    public init() {}

    @discardableResult
    public func record(input: AudioInputKind) -> Int {
        lock.lock()
        defer { lock.unlock() }
        counts[input, default: 0] += 1
        return counts[input, default: 0]
    }

    public func count(for input: AudioInputKind) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[input, default: 0]
    }
}
