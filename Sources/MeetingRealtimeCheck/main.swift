import AVFoundation
import CaptureCore
import FluidAudioAdapter
import Foundation
import TranscriptionCore

@main
struct MeetingRealtimeCheck {
    static func main() async throws {
        var paths = Array(CommandLine.arguments.dropFirst())
        let isPerformanceOnly = paths.first == "--performance-only"
        if isPerformanceOnly { paths.removeFirst() }
        guard paths.count == 2 else {
            throw RealtimeCheckError.expectedFrenchAndEnglishFiles
        }
        let frenchURL = URL(fileURLWithPath: paths[0])
        let englishURL = URL(fileURLWithPath: paths[1])

        let collector = PreviewCollector()
        let engine = FluidAudioRealtimePreviewEngine()
        try await engine.prepare { progress in
            if case let .loadingRealtime(value) = progress,
               let value {
                print("realtime-model-progress=\(Int(value.fractionCompleted * 100))%")
            }
        }
        try await engine.start { preview in
            collector.record(preview)
        }

        let concurrentFeedStartedAt = ContinuousClock.now
        async let frenchResult = feed(
            frenchURL,
            input: .microphone,
            engine: engine,
            collector: collector,
            minimumDuration: 65
        )
        async let englishResult = feed(
            englishURL,
            input: .system,
            engine: engine,
            collector: collector,
            minimumDuration: 65
        )
        let (lastFrenchUpdateAt, lastEnglishUpdateAt) = try await (
            frenchResult,
            englishResult
        )
        let concurrentFeedElapsed = concurrentFeedStartedAt.duration(to: .now)
        guard concurrentFeedElapsed < .seconds(65) else {
            throw RealtimeCheckError.processingSlowerThanRealtime(
                durationSeconds(concurrentFeedElapsed)
            )
        }

        let microphoneText = collector.text(for: .microphone)
        let systemText = collector.text(for: .system)
        guard !microphoneText.isEmpty else {
            throw RealtimeCheckError.noPartial(.microphone)
        }
        guard !systemText.isEmpty else {
            throw RealtimeCheckError.noPartial(.system)
        }
        guard lastFrenchUpdateAt >= 54 else {
            throw RealtimeCheckError.previewStopped(lastFrenchUpdateAt)
        }
        guard lastEnglishUpdateAt >= 54 else {
            throw RealtimeCheckError.previewStopped(lastEnglishUpdateAt)
        }
        let firstFrenchPartialAt = collector.firstProcessedDuration(for: .microphone)
        let firstEnglishPartialAt = collector.firstProcessedDuration(for: .system)
        let detectedFrench = collector.detectedLanguage(for: .microphone)
        let detectedEnglish = collector.detectedLanguage(for: .system)
        if !isPerformanceOnly {
            guard firstFrenchPartialAt <= 3 else {
                throw RealtimeCheckError.firstPartialTooLate(.microphone, firstFrenchPartialAt)
            }
            guard firstEnglishPartialAt <= 3 else {
                throw RealtimeCheckError.firstPartialTooLate(.system, firstEnglishPartialAt)
            }
            guard microphoneText.localizedCaseInsensitiveContains("Bonjour") else {
                throw RealtimeCheckError.sourceLanguageChanged(.microphone)
            }
            guard systemText.localizedCaseInsensitiveContains("English transcript") else {
                throw RealtimeCheckError.sourceLanguageChanged(.system)
            }
        }

        print("realtime input=microphone language=\(detectedFrench) first_partial_s=\(firstFrenchPartialAt) last_update_s=\(lastFrenchUpdateAt) text=\(microphoneText.prefix(100))")
        print("realtime input=system language=\(detectedEnglish) first_partial_s=\(firstEnglishPartialAt) last_update_s=\(lastEnglishUpdateAt) text=\(systemText.prefix(100))")
        print("realtime concurrent_audio_s=65 elapsed=\(concurrentFeedElapsed)")

        await engine.stopSession()
        guard await engine.isReady else {
            throw RealtimeCheckError.modelWasReleasedBetweenMeetings
        }
        let updatesBeforeSecondSession = collector.updateCount(for: .microphone)
        try await engine.start { preview in
            collector.record(preview)
        }
        _ = try await feed(
            frenchURL,
            input: .microphone,
            engine: engine,
            collector: collector
        )
        guard collector.updateCount(for: .microphone) > updatesBeforeSecondSession else {
            throw RealtimeCheckError.noPartialAfterRestart
        }
        await engine.stopSession()
        guard await engine.isReady else {
            throw RealtimeCheckError.modelWasReleasedBetweenMeetings
        }
        await engine.finish()
        guard await !engine.isReady else {
            throw RealtimeCheckError.modelWasNotReleased
        }
        print("OK: multilingual realtime partials passed at \(FluidAudioRealtimePreviewEngine.chunkMilliseconds)ms and model reuse passed")
    }

    private static func feed(
        _ url: URL,
        input: AudioInputKind,
        engine: FluidAudioRealtimePreviewEngine,
        collector: PreviewCollector,
        minimumDuration: TimeInterval? = nil
    ) async throws -> TimeInterval {
        let sourceSamples = try loadSamples(url)
        let targetSampleCount = max(
            sourceSamples.count,
            Int((minimumDuration ?? 0) * 16_000)
        )
        // Reproduit les petits buffers ScreenCaptureKit de l'application,
        // puis valide leur regroupement avant l'inference Nemotron.
        let frameSize = 160
        var batcher = RealtimeAudioChunkBatcher()
        var offset = 0
        var lastUpdateAt: TimeInterval = 0
        while offset < targetSampleCount {
            let end = min(targetSampleCount, offset + frameSize)
            let samples = (offset..<end).map { sourceSamples[$0 % sourceSamples.count] }
            let updateCountBefore = collector.updateCount(for: input)
            let captureChunk = AudioChunk(
                input: input,
                samples: samples,
                sampleRate: 16_000,
                startTime: Double(offset) / 16_000
            )
            for batch in batcher.append(captureChunk) {
                try await engine.ingest(batch)
            }
            if collector.updateCount(for: input) > updateCountBefore {
                lastUpdateAt = Double(end) / 16_000
            }
            offset = end
        }
        if let remainder = batcher.finish() {
            let updateCountBefore = collector.updateCount(for: input)
            try await engine.ingest(remainder)
            if collector.updateCount(for: input) > updateCountBefore {
                lastUpdateAt = Double(targetSampleCount) / 16_000
            }
        }
        return lastUpdateAt
    }

    private static func loadSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw RealtimeCheckError.cannotRead(url.lastPathComponent)
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?.pointee else {
            throw RealtimeCheckError.cannotRead(url.lastPathComponent)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private static func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

}

private final class PreviewCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [AudioInputKind: String] = [:]
    private var updateCounts: [AudioInputKind: Int] = [:]
    private var firstProcessedDurations: [AudioInputKind: TimeInterval] = [:]
    private var detectedLanguages: [AudioInputKind: String] = [:]

    func record(_ preview: RealtimeTranscriptPreview) {
        lock.lock()
        defer { lock.unlock() }
        texts[preview.input] = preview.text
        updateCounts[preview.input, default: 0] += 1
        if firstProcessedDurations[preview.input] == nil {
            firstProcessedDurations[preview.input] = preview.processedAudioDuration
        }
        if let detectedLanguage = preview.detectedLanguage {
            detectedLanguages[preview.input] = detectedLanguage
        }
    }

    func text(for input: AudioInputKind) -> String {
        lock.lock()
        defer { lock.unlock() }
        return texts[input, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func updateCount(for input: AudioInputKind) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return updateCounts[input, default: 0]
    }

    func firstProcessedDuration(for input: AudioInputKind) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return firstProcessedDurations[input, default: .infinity]
    }

    func detectedLanguage(for input: AudioInputKind) -> String {
        lock.lock()
        defer { lock.unlock() }
        return detectedLanguages[input, default: "unknown"]
    }
}

private enum RealtimeCheckError: LocalizedError {
    case expectedFrenchAndEnglishFiles
    case cannotRead(String)
    case noPartial(AudioInputKind)
    case previewStopped(TimeInterval)
    case modelWasReleasedBetweenMeetings
    case modelWasNotReleased
    case noPartialAfterRestart
    case firstPartialTooLate(AudioInputKind, TimeInterval)
    case sourceLanguageChanged(AudioInputKind)
    case processingSlowerThanRealtime(Double)

    var errorDescription: String? {
        switch self {
        case .expectedFrenchAndEnglishFiles:
            "Le controle attend un fichier francais puis un fichier anglais."
        case let .cannotRead(file):
            "Impossible de lire \(file) en PCM Float32."
        case let .noPartial(input):
            "Aucun texte partiel temps reel pour \(input.rawValue)."
        case let .previewStopped(lastUpdateAt):
            "La previsualisation longue s'est arretee a \(lastUpdateAt) secondes."
        case .modelWasReleasedBetweenMeetings:
            "Le modele temps reel a ete libere entre deux reunions."
        case .modelWasNotReleased:
            "Le modele temps reel n'a pas ete libere a la fermeture du moteur."
        case .noPartialAfterRestart:
            "Le modele temps reel reutilise n'a produit aucun texte pendant la reunion suivante."
        case let .firstPartialTooLate(input, duration):
            "Le premier texte \(input.rawValue) n'arrive qu'apres \(duration) secondes audio."
        case let .sourceLanguageChanged(input):
            "Le transcript \(input.rawValue) n'a pas conserve la langue source."
        case let .processingSlowerThanRealtime(seconds):
            "Le traitement de 65 secondes audio a pris \(seconds) secondes et ne tient pas le temps reel."
        }
    }
}
