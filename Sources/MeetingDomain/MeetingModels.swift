import Foundation

public enum MeetingState: String, Codable, Sendable {
    case recording
    case completed
    case interrupted
}

public enum MeetingTitleOrigin: String, Codable, Sendable {
    case automatic
    case user
    case artificialIntelligence = "ai"
}

public struct MeetingRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public var titleOrigin: MeetingTitleOrigin
    public var context: String
    public let startedAt: Date
    public var endedAt: Date?
    public var state: MeetingState

    public init(
        id: UUID = UUID(),
        title: String,
        titleOrigin: MeetingTitleOrigin = .automatic,
        context: String = "",
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        state: MeetingState = .recording
    ) {
        self.id = id
        self.title = title
        self.titleOrigin = titleOrigin
        self.context = context
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.state = state
    }

    public var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

public enum MeetingAIJobKind: String, Codable, CaseIterable, Sendable {
    case title
    case summary
    case questions
    case nextSteps = "next_steps"
}

public struct MeetingAIResult: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let meetingID: UUID
    public let kind: MeetingAIJobKind
    public let schemaVersion: Int
    public let payloadJSON: String
    public let sourceSegmentCount: Int
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        kind: MeetingAIJobKind,
        schemaVersion: Int = 1,
        payloadJSON: String,
        sourceSegmentCount: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.payloadJSON = payloadJSON
        self.sourceSegmentCount = sourceSegmentCount
        self.createdAt = createdAt
    }
}

public struct PendingMeetingAIJob: Codable, Sendable, Equatable {
    public let meetingID: UUID
    public let kind: MeetingAIJobKind
    public let createdAt: Date

    public init(meetingID: UUID, kind: MeetingAIJobKind, createdAt: Date = Date()) {
        self.meetingID = meetingID
        self.kind = kind
        self.createdAt = createdAt
    }
}

public enum MeetingAIChatRole: String, Codable, Sendable {
    case user
    case assistant
}

public struct MeetingAIChatMessage: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let meetingID: UUID
    public let role: MeetingAIChatRole
    public let content: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        role: MeetingAIChatRole,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = meetingID
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

public enum TranscriptInputKind: String, Codable, Sendable {
    case system
    case microphone
}

public enum TranscriptSegmentSource: String, Codable, Sendable {
    case realtime
    case canonical
}

public enum ExploitableTranscriptSelection {
    /// Tant qu'un transcript direct existe, il est la vue coherente de toute
    /// la reunion. Les segments canoniques peuvent arriver bloc par bloc
    /// pendant la consolidation et ne doivent pas etre melanges avec lui.
    public static func preferredSegments(
        from segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        let realtime = segments.filter { $0.source == .realtime }
        return realtime.isEmpty
            ? segments.filter { $0.source == .canonical }
            : realtime
    }
}

public struct TranscriptSegment: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let meetingID: UUID
    public let speakerID: String
    public let speakerName: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String
    public let confidence: Float
    public let inputKind: TranscriptInputKind?
    public let audioBlockID: String?
    public let source: TranscriptSegmentSource
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        speakerID: String,
        speakerName: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        confidence: Float,
        inputKind: TranscriptInputKind? = nil,
        audioBlockID: String? = nil,
        source: TranscriptSegmentSource = .canonical,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = meetingID
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.confidence = confidence
        self.inputKind = inputKind
        self.audioBlockID = audioBlockID
        self.source = source
        self.createdAt = createdAt
    }
}
