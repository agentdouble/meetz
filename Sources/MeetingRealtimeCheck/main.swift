import AVFoundation
import CaptureCore
import FluidAudioAdapter
import Foundation
import TranscriptionCore

@main
struct MeetingRealtimeCheck {
    static func main() async throws {
        let paths = Array(CommandLine.arguments.dropFirst())
        guard paths.count == 2 else {
            throw RealtimeCheckError.expectedFrenchAndEnglishFiles
        }

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

        let lastFrenchUpdateAt = try await feed(
            URL(fileURLWithPath: paths[0]),
            input: .microphone,
            engine: engine,
            collector: collector,
            minimumDuration: 65
        )
        _ = try await feed(
            URL(fileURLWithPath: paths[1]),
            input: .system,
            engine: engine,
            collector: collector
        )

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

        print("realtime input=microphone last_update_s=\(lastFrenchUpdateAt) text=\(microphoneText.prefix(100))")
        print("realtime input=system text=\(systemText.prefix(100))")
        await engine.finish()
        print("OK: multilingual realtime partials passed at 2240ms")
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
        let frameSize = 1_600
        var offset = 0
        var lastUpdateAt: TimeInterval = 0
        while offset < targetSampleCount {
            let end = min(targetSampleCount, offset + frameSize)
            let samples = (offset..<end).map { sourceSamples[$0 % sourceSamples.count] }
            let updateCountBefore = collector.updateCount(for: input)
            try await engine.ingest(
                AudioChunk(
                    input: input,
                    samples: samples,
                    sampleRate: 16_000,
                    startTime: Double(offset) / 16_000
                )
            )
            if collector.updateCount(for: input) > updateCountBefore {
                lastUpdateAt = Double(end) / 16_000
            }
            offset = end
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

}

private final class PreviewCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [AudioInputKind: String] = [:]
    private var updateCounts: [AudioInputKind: Int] = [:]

    func record(_ preview: RealtimeTranscriptPreview) {
        lock.lock()
        defer { lock.unlock() }
        texts[preview.input] = preview.text
        updateCounts[preview.input, default: 0] += 1
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
}

private enum RealtimeCheckError: LocalizedError {
    case expectedFrenchAndEnglishFiles
    case cannotRead(String)
    case noPartial(AudioInputKind)
    case previewStopped(TimeInterval)

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
        }
    }
}
