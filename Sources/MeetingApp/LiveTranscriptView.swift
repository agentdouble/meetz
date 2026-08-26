import MeetingDomain
import SwiftUI
import TranscriptionCore

struct LiveTranscriptView: View {
    let segments: [TranscriptSegment]
    let microphoneDraft: String
    let systemDraft: String
    let audioActivityStartedAt: Date?
    let lastTextAt: Date?
    let processingLag: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(
                presentation: LiveTranscriptPresentation(
                    segments: segments,
                    microphoneDraft: microphoneDraft,
                    systemDraft: systemDraft,
                    audioActivityStartedAt: audioActivityStartedAt,
                    lastTextAt: lastTextAt,
                    processingLag: processingLag,
                    now: context.date
                )
            )
        }
    }

    private func content(presentation: LiveTranscriptPresentation) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Circle()
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)

                Text("TRANSCRIPTION EN DIRECT")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
            }

            if presentation.text.isEmpty {
                LiveTranscriptPendingState(activity: presentation.activity)
            } else {
                if presentation.activity == .delayed {
                    Label(
                        "Direct en retard d’environ \(Int(presentation.processingLag.rounded())) s · audio protégé",
                        systemImage: "clock.badge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                LiveTranscriptText(text: presentation.text)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Transcription en direct")
        .accessibilityValue(accessibilityValue(for: presentation))
    }

    private func accessibilityValue(
        for presentation: LiveTranscriptPresentation
    ) -> String {
        if !presentation.text.isEmpty { return presentation.text }
        switch presentation.activity {
        case .listening:
            return "En écoute"
        case .transcribing:
            return "Son détecté, transcription en cours"
        case .delayed:
            return "La transcription prend du retard, audio sauvegardé"
        case .live:
            return "Transcription en direct"
        }
    }
}

private struct LiveTranscriptPendingState: View {
    let activity: LiveTranscriptPresentation.Activity

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .opacity(activity == .listening ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 18, weight: .medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch activity {
        case .listening:
            "En écoute…"
        case .transcribing:
            "Son détecté · transcription en cours…"
        case .delayed:
            "La transcription prend du retard"
        case .live:
            "Transcription en direct"
        }
    }

    private var detail: String {
        switch activity {
        case .listening:
            "Le texte apparaîtra dès que de la parole sera reconnue."
        case .transcribing:
            "Le son est reçu et sauvegardé localement."
        case .delayed:
            "L’audio continue d’être sauvegardé et sera consolidé, même si le texte direct tarde."
        case .live:
            "Le transcript est à jour."
        }
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
