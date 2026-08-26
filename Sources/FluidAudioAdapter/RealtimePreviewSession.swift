import CaptureCore
import Foundation
import TranscriptionCore

/// Etat thread-safe d'une seule session directe.
///
/// FluidAudio appelle les partiels depuis son propre acteur. Les publier ici
/// synchroniquement evite qu'ils restent derriere la file des paquets audio,
/// tout en permettant d'invalider atomiquement une ancienne reunion.
final class RealtimePreviewSession: @unchecked Sendable {
    private struct InputState {
        var processedDuration: TimeInterval = 0
        var lastText = ""
        var detectedLanguage: String?
    }

    private let lock = NSLock()
    private let updateHandler: @Sendable (RealtimeTranscriptPreview) -> Void
    private var microphone = InputState()
    private var system = InputState()
    private var isActive = true

    init(
        updateHandler: @escaping @Sendable (RealtimeTranscriptPreview) -> Void
    ) {
        self.updateHandler = updateHandler
    }

    func advance(input: AudioInputKind, sampleCount: Int, sampleRate: Int) {
        guard sampleCount > 0, sampleRate > 0 else { return }
        let duration = Double(sampleCount) / Double(sampleRate)
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return }
        switch input {
        case .microphone:
            microphone.processedDuration += duration
        case .system:
            system.processedDuration += duration
        }
    }

    func emit(_ text: String, input: AudioInputKind) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        let preview: RealtimeTranscriptPreview?
        lock.lock()
        if !isActive {
            preview = nil
        } else {
            switch input {
            case .microphone where microphone.lastText != normalized:
                microphone.lastText = normalized
                preview = RealtimeTranscriptPreview(
                    input: input,
                    text: normalized,
                    processedAudioDuration: microphone.processedDuration,
                    detectedLanguage: microphone.detectedLanguage
                )
            case .system where system.lastText != normalized:
                system.lastText = normalized
                preview = RealtimeTranscriptPreview(
                    input: input,
                    text: normalized,
                    processedAudioDuration: system.processedDuration,
                    detectedLanguage: system.detectedLanguage
                )
            default:
                preview = nil
            }
        }
        lock.unlock()

        if let preview {
            updateHandler(preview)
        }
    }

    func setDetectedLanguage(_ language: String?, input: AudioInputKind) {
        guard let language, !language.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return }
        switch input {
        case .microphone:
            microphone.detectedLanguage = language
        case .system:
            system.detectedLanguage = language
        }
    }

    func reset(input: AudioInputKind) {
        lock.lock()
        defer { lock.unlock() }
        switch input {
        case .microphone:
            microphone = InputState()
        case .system:
            system = InputState()
        }
    }

    func deactivate() {
        lock.lock()
        isActive = false
        lock.unlock()
    }
}
