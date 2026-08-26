/// Duplique chaque paquet de capture vers plusieurs consommateurs independants.
/// Un consommateur lent ne doit pas determiner si les autres recoivent le son.
public struct AudioChunkFanout: Sendable {
    public typealias Sink = @Sendable (AudioChunk) -> Void

    private let sinks: [Sink]

    public init(sinks: [Sink]) {
        self.sinks = sinks
    }

    public func yield(_ chunk: AudioChunk) {
        for sink in sinks {
            sink(chunk)
        }
    }
}
