import Foundation

/// Conserve uniquement les metadonnees des blocs WAV deja durables jusqu'a ce
/// que le moteur temps reel ait libere les ressources Core ML.
public actor DeferredAudioBlockQueue {
    private var blocksByID: [String: RecordedAudioBlock] = [:]

    public init() {}

    public func enqueue(_ block: RecordedAudioBlock) {
        blocksByID[block.id] = block
    }

    public func enqueue(contentsOf blocks: [RecordedAudioBlock]) {
        for block in blocks {
            blocksByID[block.id] = block
        }
    }

    public func drain() -> [RecordedAudioBlock] {
        let blocks = blocksByID.values.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            if $0.input != $1.input { return $0.input.rawValue < $1.input.rawValue }
            return $0.sequence < $1.sequence
        }
        blocksByID.removeAll(keepingCapacity: false)
        return blocks
    }
}
