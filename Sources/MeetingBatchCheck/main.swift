import AVFoundation
import CaptureCore
import FluidAudioAdapter
import Foundation

@main
struct MeetingBatchCheck {
    static func main() async throws {
        let paths = Array(CommandLine.arguments.dropFirst())
        guard !paths.isEmpty else {
            throw BatchCheckError.missingAudioFiles
        }

        let engine = FluidAudioBatchTranscriptionEngine(voiceProfiles: [])
        try await engine.prepare { status in
            if case let .warning(message) = status {
                print("warning: \(message)")
            }
        }

        for (index, path) in paths.enumerated() {
            let url = URL(fileURLWithPath: path)
            let audioFile = try AVAudioFile(forReading: url)
            let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            let input: AudioInputKind = index.isMultiple(of: 2) ? .microphone : .system
            let block = RecordedAudioBlock(
                id: "batch-check-\(index)",
                meetingID: UUID(),
                input: input,
                sequence: index,
                startTime: 0,
                duration: duration,
                sampleRate: 16_000,
                fileURL: url
            )
            let updates = try await engine.transcribe(block)
            let text = updates.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw BatchCheckError.emptyTranscript(url.lastPathComponent)
            }
            print("batch input=\(input.rawValue) file=\(url.lastPathComponent) text=\(text)")
        }

        await engine.finish()
        print("OK: recorded audio batch transcription passed")
    }
}

private enum BatchCheckError: LocalizedError {
    case missingAudioFiles
    case emptyTranscript(String)

    var errorDescription: String? {
        switch self {
        case .missingAudioFiles:
            "Fournissez au moins un fichier audio au controle batch."
        case let .emptyTranscript(file):
            "Le moteur batch n'a produit aucun texte pour \(file)."
        }
    }
}
