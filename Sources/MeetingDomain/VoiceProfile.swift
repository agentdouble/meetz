import Foundation

public struct VoiceProfile: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let embedding: [Float]
    public let sampleCount: Int
    public let updatedAt: Date

    public init(
        id: String = "local-user",
        displayName: String = "Moi",
        embedding: [Float],
        sampleCount: Int = 1,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.embedding = embedding
        self.sampleCount = max(sampleCount, 1)
        self.updatedAt = updatedAt
    }
}
