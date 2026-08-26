import SwiftUI

struct CompactRecordingStatusView: View {
    let microphoneLevel: Double
    let systemLevel: Double
    let status: String
    let onOpenAssistant: () -> Void
    let onShowTranscript: () -> Void

    var body: some View {
        VStack {
            Spacer()

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Circle()
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text("ENREGISTREMENT EN COURS")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1)
                }

                HStack(spacing: 24) {
                    RecordingLevelIndicator(title: "MIC", level: microphoneLevel)
                    RecordingLevelIndicator(title: "MAC", level: systemLevel)
                }

                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 18) {
                    Button(action: onOpenAssistant) {
                        Label("Assistant", systemImage: "bubble.left")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Ouvrir Assistant")

                    Button(action: onShowTranscript) {
                        Label("Rouvrir le transcript", systemImage: "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Rouvrir le panneau de transcription")
                }
            }
            .padding(24)
            .frame(width: 310, alignment: .leading)
            .background(Color.primary.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.16), lineWidth: 1)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Enregistrement en cours, panneau de transcription fermé")
    }
}

private struct RecordingLevelIndicator: View {
    let title: String
    let level: Double

    private var boundedLevel: Double {
        min(1, max(0, level))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(Color.primary)
                        .frame(width: max(1, proxy.size.width * boundedLevel))
                }
            }
            .frame(height: 5)
        }
        .frame(width: 110)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Niveau \(title)")
        .accessibilityValue("\(Int((boundedLevel * 100).rounded())) pour cent")
    }
}
