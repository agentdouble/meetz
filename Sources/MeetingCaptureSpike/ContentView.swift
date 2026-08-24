import CaptureCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: CaptureViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header

            VStack(spacing: 14) {
                LevelRow(
                    title: AudioInputKind.microphone.displayName,
                    subtitle: "Votre voix",
                    level: model.microphoneLevel,
                    bufferCount: model.microphoneBufferCount
                )
                LevelRow(
                    title: AudioInputKind.system.displayName,
                    subtitle: "Teams, Webex, navigateur ou autre application",
                    level: model.systemLevel,
                    bufferCount: model.systemBufferCount
                )
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(0.25), lineWidth: 1)
                    }
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 12) {
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button(action: model.toggleCapture) {
                    HStack {
                        Image(systemName: model.isCapturing ? "stop.fill" : "waveform")
                        Text(model.isCapturing ? "Arreter le test" : "Tester la capture")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.isCapturing ? Color.primary : Color(nsColor: .windowBackgroundColor))
                .background(model.isCapturing ? Color.primary.opacity(0.08) : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary, lineWidth: model.isCapturing ? 1 : 0)
                }
                .disabled(model.isTransitioning)
                .keyboardShortcut(.space, modifiers: [.command])
            }
        }
        .padding(32)
        .frame(minWidth: 620, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MEETING")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(2)

                Spacer()

                HStack(spacing: 8) {
                    Circle()
                        .fill(model.isCapturing ? Color.primary : Color.secondary.opacity(0.35))
                        .frame(width: 8, height: 8)
                    Text(model.isCapturing ? "ACTIF" : "INACTIF")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
            }

            Text("Preuve de capture audio locale")
                .font(.system(size: 28, weight: .semibold))

            Text("Ce spike mesure les deux flux en memoire. Il ne transcrit pas encore et n'ecrit aucun audio sur le Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}
private struct LevelRow: View {
    let title: String
    let subtitle: String
    let level: Double
    let bufferCount: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(bufferCount) buffers")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.09))
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: max(2, proxy.size.width * level))
                }
            }
            .frame(height: 10)
            .animation(.linear(duration: 0.08), value: level)
        }
        .padding(18)
        .background(Color.primary.opacity(0.025))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
    }
}
