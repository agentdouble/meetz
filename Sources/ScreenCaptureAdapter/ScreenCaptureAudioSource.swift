import AVFoundation
import CaptureCore
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

public enum ScreenCaptureAudioError: LocalizedError, Sendable {
    case microphoneDenied
    case screenRecordingDenied
    case noDisplayAvailable
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "L'acces au microphone a ete refuse. Autorisez Meeting dans Reglages Systeme > Confidentialite et securite > Microphone, puis relancez l'application."
        case .screenRecordingDenied:
            "L'acces a l'enregistrement de l'ecran et de l'audio systeme a ete refuse. Autorisez Meeting dans Reglages Systeme > Confidentialite et securite > Enregistrement de l'ecran et de l'audio systeme, puis relancez l'application."
        case .noDisplayAvailable:
            "Aucun ecran macOS n'est disponible pour creer la capture audio systeme."
        case .alreadyRunning:
            "La capture est deja active."
        }
    }
}

public final class ScreenCaptureAudioSource: NSObject, AudioCaptureSource, @unchecked Sendable {
    private let stateLock = NSLock()
    private let systemAudioQueue = DispatchQueue(
        label: "meeting.capture.system-audio",
        qos: .userInitiated
    )
    private let microphoneQueue = DispatchQueue(
        label: "meeting.capture.microphone",
        qos: .userInitiated
    )

    private var stream: SCStream?
    private var eventHandler: (@Sendable (AudioCaptureEvent) -> Void)?
    private var systemBufferCount: UInt64 = 0
    private var microphoneBufferCount: UInt64 = 0
    private var systemSampleCount: UInt64 = 0
    private var microphoneSampleCount: UInt64 = 0
    private let systemSampleConverter = AudioSampleConverter()
    private let microphoneSampleConverter = AudioSampleConverter()

    public override init() {
        super.init()
    }

    public func start(
        eventHandler: @escaping @Sendable (AudioCaptureEvent) -> Void
    ) async throws {
        try claimStart(handler: eventHandler)

        do {
            guard await requestMicrophoneAccess() else {
                throw ScreenCaptureAudioError.microphoneDenied
            }

            guard requestScreenRecordingAccess() else {
                throw ScreenCaptureAudioError.screenRecordingDenied
            }

            let shareableContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )

            guard let display = shareableContent.displays.first else {
                throw ScreenCaptureAudioError.noDisplayAvailable
            }

            let ownApplication = shareableContent.applications.first {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            let excludedApplications = ownApplication.map { [$0] } ?? []
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )

            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 3
            configuration.showsCursor = false
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.captureMicrophone = true

            let newStream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: self
            )

            try newStream.addStreamOutput(
                self,
                type: .audio,
                sampleHandlerQueue: systemAudioQueue
            )
            try newStream.addStreamOutput(
                self,
                type: .microphone,
                sampleHandlerQueue: microphoneQueue
            )

            stateLock.withLock {
                stream = newStream
            }
            try await newStream.startCapture()
        } catch {
            clearState()
            throw error
        }
    }

    public func stop() async {
        let activeStream = stateLock.withLock { stream }

        if let activeStream {
            try? await activeStream.stopCapture()
        }
        clearState()
    }

    private func claimStart(
        handler: @escaping @Sendable (AudioCaptureEvent) -> Void
    ) throws {
        try stateLock.withLock {
            guard stream == nil, eventHandler == nil else {
                throw ScreenCaptureAudioError.alreadyRunning
            }
            eventHandler = handler
            systemBufferCount = 0
            microphoneBufferCount = 0
            systemSampleCount = 0
            microphoneSampleCount = 0
        }
    }

    private func clearState() {
        stateLock.withLock {
            stream = nil
            eventHandler = nil
            systemBufferCount = 0
            microphoneBufferCount = 0
            systemSampleCount = 0
            microphoneSampleCount = 0
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private func requestScreenRecordingAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess()
    }

    private func publishLevel(
        _ level: Double,
        input: AudioInputKind
    ) {
        let payload: (handler: (@Sendable (AudioCaptureEvent) -> Void)?, count: UInt64) = stateLock.withLock {
            let count: UInt64
            switch input {
            case .system:
                systemBufferCount += 1
                count = systemBufferCount
            case .microphone:
                microphoneBufferCount += 1
                count = microphoneBufferCount
            }
            return (eventHandler, count)
        }

        payload.handler?(
            .level(
                AudioLevelSnapshot(
                    input: input,
                    linearLevel: level,
                    bufferCount: payload.count
                )
            )
        )
    }

    private func publishSamples(
        _ samples: [Float],
        input: AudioInputKind
    ) {
        guard !samples.isEmpty else { return }

        let payload: (handler: (@Sendable (AudioCaptureEvent) -> Void)?, startTime: TimeInterval) = stateLock.withLock {
            let previousSampleCount: UInt64
            switch input {
            case .system:
                previousSampleCount = systemSampleCount
                systemSampleCount += UInt64(samples.count)
            case .microphone:
                previousSampleCount = microphoneSampleCount
                microphoneSampleCount += UInt64(samples.count)
            }
            return (eventHandler, Double(previousSampleCount) / 16_000)
        }

        payload.handler?(
            .samples(
                AudioChunk(
                    input: input,
                    samples: samples,
                    sampleRate: 16_000,
                    startTime: payload.startTime
                )
            )
        )
    }
}

extension ScreenCaptureAudioSource: SCStreamOutput, SCStreamDelegate {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else {
            return
        }

        let input: AudioInputKind
        let converter: AudioSampleConverter
        switch outputType {
        case .audio:
            input = .system
            converter = systemSampleConverter
        case .microphone:
            input = .microphone
            converter = microphoneSampleConverter
        default:
            return
        }

        do {
            let samples = try converter.samples(from: sampleBuffer)
            guard !samples.isEmpty else { return }
            let rootMeanSquare = AudioMath.rootMeanSquare(of: samples)
            publishLevel(
                AudioMath.meterLevel(fromRootMeanSquare: rootMeanSquare),
                input: input
            )
            publishSamples(samples, input: input)
        } catch {
            // A malformed buffer is skipped. ScreenCaptureKit will deliver the next one.
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let handler = stateLock.withLock { eventHandler }
        handler?(.stopped(reason: error.localizedDescription))
        clearState()
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
