import Foundation
import MeetingDomain

/// Intervenant explicitement expose a Codex en plus de son attribution sur
/// chaque segment. Cette vue evite au modele de devoir reconstruire seul la
/// liste des personnes depuis un long transcript.
public struct MeetingAITranscriptSpeaker: Codable, Sendable, Equatable {
    public let speakerID: String
    public let speakerName: String

    public init(speakerID: String, speakerName: String) {
        self.speakerID = speakerID
        self.speakerName = speakerName
    }
}

/// Export versionne et autonome fourni a chaque execution Codex.
public struct MeetingAITranscriptExport: Codable, Sendable {
    public let schemaVersion: Int
    public let meeting: MeetingRecord
    public let speakers: [MeetingAITranscriptSpeaker]
    public let segments: [TranscriptSegment]

    public init(meeting: MeetingRecord, segments: [TranscriptSegment]) {
        schemaVersion = 3
        self.meeting = meeting
        self.segments = segments
        speakers = Self.distinctSpeakers(from: segments)
    }

    private static func distinctSpeakers(
        from segments: [TranscriptSegment]
    ) -> [MeetingAITranscriptSpeaker] {
        let orderedSegments = segments.sorted {
            if $0.startTime == $1.startTime {
                return $0.createdAt < $1.createdAt
            }
            return $0.startTime < $1.startTime
        }
        var seenSpeakerIDs: Set<String> = []
        return orderedSegments.compactMap { segment in
            guard seenSpeakerIDs.insert(segment.speakerID).inserted else {
                return nil
            }
            let normalizedName = segment.speakerName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return MeetingAITranscriptSpeaker(
                speakerID: segment.speakerID,
                speakerName: normalizedName.isEmpty ? segment.speakerID : normalizedName
            )
        }
    }
}
