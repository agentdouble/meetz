import MeetingDomain
import SwiftUI

struct LiveTranscriptView: View {
    let segments: [TranscriptSegment]

    private var transcriptText: String {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Circle()
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)

                Text("TRANSCRIPTION EN DIRECT")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
            }

            LiveTranscriptText(text: transcriptText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Transcription en direct")
        .accessibilityValue(transcriptText)
    }
}

private struct LiveTranscriptText: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            renderedText(cursorVisible: true)
        } else {
            TimelineView(.periodic(from: .now, by: 0.55)) { context in
                renderedText(
                    cursorVisible: Int(
                        context.date.timeIntervalSinceReferenceDate / 0.55
                    ).isMultiple(of: 2)
                )
            }
        }
    }

    private func renderedText(cursorVisible: Bool) -> some View {
        (Text(text) + Text(cursorVisible ? " ▍" : "  "))
            .font(.system(size: 22, weight: .regular))
            .lineSpacing(7)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
