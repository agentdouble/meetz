import Foundation
import MeetingDomain

/// Etat d'affichage stable du transcript direct, independant de SwiftUI et du moteur ASR.
public struct LiveTranscriptPresentation: Sendable, Equatable {
    public enum Activity: Sendable, Equatable {
        case listening
        case transcribing
        case delayed
        case live
    }

    public static let delayWarningInterval: TimeInterval = 12

    public let activity: Activity
    public let text: String
    public let processingLag: TimeInterval

    public init(
        segments: [TranscriptSegment],
        microphoneDraft: String,
        systemDraft: String,
        audioActivityStartedAt: Date?,
        lastTextAt: Date?,
        processingLag: TimeInterval = 0,
        now: Date = Date()
    ) {
        self.processingLag = max(0, processingLag)
        let persistedText = Self.joinedSegmentText(segments)
        text = persistedText.isEmpty
            ? Self.joinedDraftText(microphoneDraft, systemDraft)
            : persistedText

        if !text.isEmpty {
            activity = self.processingLag >= Self.delayWarningInterval
                ? .delayed
                : .live
        } else if let audioActivityStartedAt {
            let referenceDate = lastTextAt ?? audioActivityStartedAt
            activity = self.processingLag >= Self.delayWarningInterval
                || now.timeIntervalSince(referenceDate) >= Self.delayWarningInterval
                ? .delayed
                : .transcribing
        } else {
            activity = .listening
        }
    }

    private static func joinedSegmentText(_ segments: [TranscriptSegment]) -> String {
        segments
            .sorted {
                if $0.startTime == $1.startTime {
                    return $0.createdAt < $1.createdAt
                }
                return $0.startTime < $1.startTime
            }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func joinedDraftText(_ microphoneDraft: String, _ systemDraft: String) -> String {
        [microphoneDraft, systemDraft]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
