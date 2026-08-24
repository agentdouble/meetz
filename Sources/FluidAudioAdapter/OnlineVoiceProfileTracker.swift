import Foundation
import MeetingDomain

public struct VoiceProfileResolution: Sendable {
    public let profile: VoiceProfile
    public let similarity: Float
    public let createdNewProfile: Bool

    public init(
        profile: VoiceProfile,
        similarity: Float,
        createdNewProfile: Bool = false
    ) {
        self.profile = profile
        self.similarity = similarity
        self.createdNewProfile = createdNewProfile
    }
}

public struct OnlineVoiceProfileTracker: Sendable {
    public private(set) var profilesByID: [String: VoiceProfile]
    private var fixedClusterAssignments: [String: String] = [:]

    public init(profiles: [VoiceProfile]) {
        profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    }

    public mutating func resolve(
        embedding: [Float],
        fixedClusterKey: String?
    ) -> VoiceProfileResolution {
        if let fixedClusterKey,
           let profileID = fixedClusterAssignments[fixedClusterKey],
           let profile = profilesByID[profileID] {
            return update(profile: profile, with: embedding)
        }

        let nearestMatch = bestMatch(for: embedding)
        if let match = nearestMatch,
           match.similarity >= CampPlusVoiceIdentityEngine.conservativeSimilarityThreshold {
            if let fixedClusterKey {
                fixedClusterAssignments[fixedClusterKey] = match.profile.id
            }
            return update(profile: match.profile, with: embedding)
        }

        let profile = VoiceProfile(
            id: UUID().uuidString,
            displayName: nextGeneratedName(),
            embedding: embedding,
            sampleCount: 1
        )
        profilesByID[profile.id] = profile
        if let fixedClusterKey {
            fixedClusterAssignments[fixedClusterKey] = profile.id
        }
        return VoiceProfileResolution(
            profile: profile,
            similarity: nearestMatch?.similarity ?? 0,
            createdNewProfile: true
        )
    }

    private func bestMatch(for embedding: [Float]) -> VoiceProfileResolution? {
        profilesByID.values.compactMap { profile in
            guard profile.embedding.count == embedding.count else { return nil }
            return VoiceProfileResolution(
                profile: profile,
                similarity: CampPlusVoiceIdentityEngine.cosine(embedding, profile.embedding)
            )
        }.max { $0.similarity < $1.similarity }
    }

    private mutating func update(
        profile: VoiceProfile,
        with embedding: [Float]
    ) -> VoiceProfileResolution {
        let similarity = CampPlusVoiceIdentityEngine.cosine(embedding, profile.embedding)
        guard similarity >= 0.60 else {
            return VoiceProfileResolution(profile: profile, similarity: similarity)
        }

        let historicalWeight = Float(min(profile.sampleCount, 20))
        var centroid = [Float](repeating: 0, count: embedding.count)
        for index in centroid.indices {
            centroid[index] = profile.embedding[index] * historicalWeight + embedding[index]
        }
        let norm = max(sqrt(centroid.reduce(0) { $0 + $1 * $1 }), 1e-9)
        centroid = centroid.map { $0 / norm }

        let updated = VoiceProfile(
            id: profile.id,
            displayName: profile.displayName,
            embedding: centroid,
            sampleCount: profile.sampleCount + 1,
            updatedAt: Date()
        )
        profilesByID[updated.id] = updated
        return VoiceProfileResolution(profile: updated, similarity: similarity)
    }

    private func nextGeneratedName() -> String {
        let usedNumbers = profilesByID.values.compactMap { profile -> Int? in
            guard profile.displayName.hasPrefix("Voix ") else { return nil }
            return Int(profile.displayName.dropFirst("Voix ".count))
        }
        return "Voix \((usedNumbers.max() ?? 0) + 1)"
    }
}
