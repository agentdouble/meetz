import CaptureCore
import Foundation
import MeetingDomain

/// Transforme le texte cumulatif append-only de Nemotron en segments stables
/// et directement persistables pendant la reunion.
public struct RealtimeTranscriptSegmenter: Sendable {
    public static let defaultSegmentDuration: TimeInterval = 20

    private let meetingID: UUID
    private let input: AudioInputKind
    private let segmentDuration: TimeInterval
    private let timeOffset: TimeInterval
    private var segmentID = UUID()
    private var segmentIndex = 0
    private var segmentStartTime: TimeInterval
    private var committedCumulativeText = ""
    private var lastCumulativeText = ""

    public init(
        meetingID: UUID,
        input: AudioInputKind,
        segmentDuration: TimeInterval = Self.defaultSegmentDuration,
        timeOffset: TimeInterval = 0
    ) {
        self.meetingID = meetingID
        self.input = input
        self.segmentDuration = max(2, segmentDuration)
        self.timeOffset = max(0, timeOffset)
        segmentStartTime = max(0, timeOffset)
    }

    public mutating func ingest(
        cumulativeText: String,
        processedAudioDuration: TimeInterval
    ) -> TranscriptSegment? {
        let normalized = cumulativeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        // Nemotron expose ses tokens accumules. Si une version future revise
        // la fin du texte, seule la fenetre courante est reconstruite.
        let currentText: String
        if normalized.hasPrefix(committedCumulativeText) {
            currentText = String(normalized.dropFirst(committedCumulativeText.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if normalized.hasPrefix(lastCumulativeText) {
            let appended = String(normalized.dropFirst(lastCumulativeText.count))
            let previousCurrent = String(lastCumulativeText.dropFirst(
                min(committedCumulativeText.count, lastCumulativeText.count)
            ))
            currentText = (previousCurrent + " " + appended)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            currentText = normalized
        }
        lastCumulativeText = normalized
        guard !currentText.isEmpty else { return nil }

        let endTime = max(segmentStartTime, timeOffset + processedAudioDuration)
        let segment = TranscriptSegment(
            id: segmentID,
            meetingID: meetingID,
            speakerID: input == .microphone ? "realtime-microphone" : "realtime-system",
            speakerName: input == .microphone ? "Micro du Mac" : "Participant",
            startTime: segmentStartTime,
            endTime: endTime,
            text: currentText,
            confidence: 0,
            inputKind: TranscriptInputKind(rawValue: input.rawValue),
            audioBlockID: "realtime:\(input.rawValue):\(segmentIndex)",
            source: .realtime
        )

        if endTime - segmentStartTime >= segmentDuration {
            committedCumulativeText = normalized
            segmentIndex += 1
            segmentID = UUID()
            segmentStartTime = endTime
        }
        return segment
    }
}
