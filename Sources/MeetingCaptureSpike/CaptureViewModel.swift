import CaptureCore
import Foundation
import ScreenCaptureAdapter

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var isTransitioning = false
    @Published private(set) var systemLevel = 0.0
    @Published private(set) var microphoneLevel = 0.0
    @Published private(set) var systemBufferCount: UInt64 = 0
    @Published private(set) var microphoneBufferCount: UInt64 = 0
    @Published private(set) var status = "Pret a tester la capture locale"
    @Published private(set) var errorMessage: String?

    private let captureSource: any AudioCaptureSource

    init(captureSource: any AudioCaptureSource = ScreenCaptureAudioSource()) {
        self.captureSource = captureSource
    }

    func toggleCapture() {
        if isCapturing {
            stopCapture()
        } else {
            startCapture()
        }
    }

    func startCapture() {
        guard !isTransitioning, !isCapturing else { return }

        isTransitioning = true
        errorMessage = nil
        status = "Demande des autorisations macOS..."

        Task {
            do {
                try await captureSource.start { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handle(event)
                    }
                }
                isCapturing = true
                status = "Capture active — aucun audio n'est enregistre sur disque"
            } catch {
                errorMessage = error.localizedDescription
                status = "Capture inactive"
            }
            isTransitioning = false
        }
    }

    func stopCapture() {
        guard !isTransitioning, isCapturing else { return }

        isTransitioning = true
        status = "Arret de la capture..."

        Task {
            await captureSource.stop()
            isCapturing = false
            isTransitioning = false
            systemLevel = 0
            microphoneLevel = 0
            status = "Capture arretee — seuls les compteurs ont ete conserves"
        }
    }

    private func handle(_ event: AudioCaptureEvent) {
        switch event {
        case let .level(snapshot):
            switch snapshot.input {
            case .system:
                systemLevel = snapshot.linearLevel
                systemBufferCount = snapshot.bufferCount
            case .microphone:
                microphoneLevel = snapshot.linearLevel
                microphoneBufferCount = snapshot.bufferCount
            }
        case .samples:
            break
        case let .stopped(reason):
            isCapturing = false
            isTransitioning = false
            systemLevel = 0
            microphoneLevel = 0
            status = "Capture interrompue"
            errorMessage = reason
        }
    }
}
