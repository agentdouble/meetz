import FluidAudio
import Foundation
import MeetingDomain
import TranscriptionCore

public actor CampPlusVoiceIdentityEngine {
    public static let embeddingDimension = CampPlusEmbedder.embeddingDim
    public static let minimumEnrollmentSeconds: TimeInterval = 6
    public static let minimumVerificationSeconds: TimeInterval = 1.25
    public static let conservativeSimilarityThreshold: Float = 0.60

    private let embedder: CampPlusEmbedder

    private init(embedder: CampPlusEmbedder) {
        self.embedder = embedder
    }

    public static func load(
        progressHandler: (@Sendable (ModelPreparationProgress) -> Void)? = nil
    ) async throws -> CampPlusVoiceIdentityEngine {
        let embedder = try await CampPlusEmbedder.load { progress in
            progressHandler?(FluidAudioProgressMapper.map(progress))
        }
        return CampPlusVoiceIdentityEngine(embedder: embedder)
    }

    public func createProfile(
        samples: [Float],
        sampleRate: Int,
        displayName: String = "Moi"
    ) async throws -> VoiceProfile {
        let minimumSamples = Int(Self.minimumEnrollmentSeconds * Double(sampleRate))
        guard sampleRate == 16_000, samples.count >= minimumSamples else {
            throw VoiceIdentityError.insufficientEnrollmentAudio
        }

        let sliceCount = 3
        let sliceLength = samples.count / sliceCount
        var embeddings: [[Float]] = []
        embeddings.reserveCapacity(sliceCount)

        for index in 0..<sliceCount {
            let start = index * sliceLength
            let end = index == sliceCount - 1 ? samples.count : start + sliceLength
            let embedding = try await embedder.embed(audio: Array(samples[start..<end]))
            embeddings.append(embedding)
        }

        return VoiceProfile(
            displayName: displayName,
            embedding: Self.normalizedMean(of: embeddings)
        )
    }

    public func similarity(samples: [Float], profile: VoiceProfile) async throws -> Float {
        guard samples.count >= Int(Self.minimumVerificationSeconds * 16_000),
              profile.embedding.count == Self.embeddingDimension
        else {
            throw VoiceIdentityError.insufficientVerificationAudio
        }

        let candidate = try await embedding(samples: samples)
        return Self.cosine(candidate, profile.embedding)
    }

    public func embedding(samples: [Float]) async throws -> [Float] {
        guard samples.count >= Int(Self.minimumVerificationSeconds * 16_000) else {
            throw VoiceIdentityError.insufficientVerificationAudio
        }
        return try await embedder.embed(audio: samples)
    }

    public nonisolated static func cosine(_ first: [Float], _ second: [Float]) -> Float {
        CampPlusEmbedder.cosine(first, second)
    }

    private static func normalizedMean(of embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        var mean = [Float](repeating: 0, count: first.count)

        for embedding in embeddings where embedding.count == mean.count {
            for index in mean.indices {
                mean[index] += embedding[index]
            }
        }

        let divisor = Float(embeddings.count)
        for index in mean.indices {
            mean[index] /= divisor
        }
        let norm = max(sqrt(mean.reduce(0) { $0 + $1 * $1 }), 1e-9)
        return mean.map { $0 / norm }
    }
}

public enum VoiceIdentityError: LocalizedError, Sendable {
    case insufficientEnrollmentAudio
    case insufficientVerificationAudio

    public var errorDescription: String? {
        switch self {
        case .insufficientEnrollmentAudio:
            "Il faut au moins six secondes de voix pour creer l'empreinte."
        case .insufficientVerificationAudio:
            "Le segment est trop court pour identifier la voix de facon fiable."
        }
    }
}
