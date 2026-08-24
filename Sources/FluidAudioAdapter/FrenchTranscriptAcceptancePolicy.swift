import Foundation
import NaturalLanguage

public enum FrenchTranscriptAcceptancePolicy {
    public struct Evaluation: Sendable, Equatable {
        public let shouldAccept: Bool
        public let dominantLanguage: String?
        public let languageConfidence: Double

        public init(
            shouldAccept: Bool,
            dominantLanguage: String?,
            languageConfidence: Double
        ) {
            self.shouldAccept = shouldAccept
            self.dominantLanguage = dominantLanguage
            self.languageConfidence = languageConfidence
        }
    }

    // Short Parakeet windows can hallucinate fluent English when the acoustic
    // evidence is weak. High-confidence English remains allowed for names,
    // quotations and genuinely English passages in otherwise French meetings.
    public static let maximumLowConfidenceEnglishScore: Float = 0.65
    public static let minimumEnglishLanguageConfidence = 0.70

    public static func evaluate(
        text: String,
        transcriptionConfidence: Float
    ) -> Evaluation {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard alphabeticWordCount(in: normalizedText) >= 3 else {
            return Evaluation(
                shouldAccept: true,
                dominantLanguage: nil,
                languageConfidence: 0
            )
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(normalizedText)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        let englishConfidence = hypotheses[.english] ?? 0
        let frenchConfidence = hypotheses[.french] ?? 0
        let isLikelyEnglish = englishConfidence >= minimumEnglishLanguageConfidence
            && englishConfidence > frenchConfidence
        let isWeakTranscription = transcriptionConfidence < maximumLowConfidenceEnglishScore

        return Evaluation(
            shouldAccept: !(isLikelyEnglish && isWeakTranscription),
            dominantLanguage: recognizer.dominantLanguage?.rawValue,
            languageConfidence: max(englishConfidence, frenchConfidence)
        )
    }

    private static func alphabeticWordCount(in text: String) -> Int {
        text.split(whereSeparator: \Character.isWhitespace).reduce(into: 0) { count, word in
            if word.unicodeScalars.contains(where: CharacterSet.letters.contains) {
                count += 1
            }
        }
    }
}
