import Foundation

public struct RecordedAudioBlock: Sendable, Equatable, Identifiable {
    public let id: String
    public let meetingID: UUID
    public let input: AudioInputKind
    public let sequence: Int
    public let startTime: TimeInterval
    public let duration: TimeInterval
    public let sampleRate: Int
    public let fileURL: URL

    public init(
        id: String,
        meetingID: UUID,
        input: AudioInputKind,
        sequence: Int,
        startTime: TimeInterval,
        duration: TimeInterval,
        sampleRate: Int,
        fileURL: URL
    ) {
        self.id = id
        self.meetingID = meetingID
        self.input = input
        self.sequence = sequence
        self.startTime = startTime
        self.duration = duration
        self.sampleRate = sampleRate
        self.fileURL = fileURL
    }
}
