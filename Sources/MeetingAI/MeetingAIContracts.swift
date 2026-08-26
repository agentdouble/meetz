import Foundation
import MeetingDomain

public enum CodexReasoningEffort: String, CaseIterable, Codable, Identifiable, Sendable {
    case inherit
    case low
    case medium
    case high
    case xhigh
    case max

    public var id: String { rawValue }
}

public struct CodexRunConfiguration: Sendable, Equatable {
    public let model: String
    public let reasoningEffort: CodexReasoningEffort

    public init(
        model: String = "",
        reasoningEffort: CodexReasoningEffort = .inherit
    ) {
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reasoningEffort = reasoningEffort
    }

    public static let inherit = CodexRunConfiguration()

    var commandLineArguments: [String] {
        var arguments: [String] = []
        if !model.isEmpty {
            arguments += ["--model", model]
        }
        if reasoningEffort != .inherit {
            arguments += ["--config", "model_reasoning_effort=\"\(reasoningEffort.rawValue)\""]
        }
        return arguments
    }
}

public struct MeetingAITranscriptExport: Codable, Sendable {
    public let schemaVersion: Int
    public let meeting: MeetingRecord
    public let segments: [TranscriptSegment]

    public init(meeting: MeetingRecord, segments: [TranscriptSegment]) {
        schemaVersion = 2
        self.meeting = meeting
        self.segments = segments
    }
}

public struct MeetingAIChatHistoryExport: Codable, Sendable {
    public let schemaVersion: Int
    public let messages: [MeetingAIChatMessage]

    public init(messages: [MeetingAIChatMessage]) {
        schemaVersion = 1
        self.messages = messages
    }
}

public struct ChatAnswerPayload: Codable, Sendable {
    public let answer: String
}

public enum MeetingAIOutput: Sendable, Equatable {
    case title(String)
    case summary(String)
    case questions([String])
    case nextSteps([NextStep])

    public struct NextStep: Codable, Sendable, Equatable {
        public let action: String
        public let owner: String?
        public let dueDate: String?
        public let rationale: String?

        public init(
            action: String,
            owner: String? = nil,
            dueDate: String? = nil,
            rationale: String? = nil
        ) {
            self.action = action
            self.owner = owner
            self.dueDate = dueDate
            self.rationale = rationale
        }
    }

    public var payloadJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        switch self {
        case let .title(title):
            data = (try? encoder.encode(TitlePayload(title: title))) ?? Data()
        case let .summary(summary):
            data = (try? encoder.encode(SummaryPayload(summary: summary))) ?? Data()
        case let .questions(questions):
            data = (try? encoder.encode(QuestionsPayload(questions: questions))) ?? Data()
        case let .nextSteps(nextSteps):
            data = (try? encoder.encode(NextStepsPayload(nextSteps: nextSteps))) ?? Data()
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public var displayText: String {
        switch self {
        case let .title(title):
            title
        case let .summary(summary):
            summary
        case let .questions(questions):
            questions.map { "• \($0)" }.joined(separator: "\n\n")
        case let .nextSteps(nextSteps):
            nextSteps.map { step in
                var details: [String] = []
                if let owner = step.owner, !owner.isEmpty { details.append(owner) }
                if let dueDate = step.dueDate, !dueDate.isEmpty { details.append(dueDate) }
                let suffix = details.isEmpty ? "" : " — \(details.joined(separator: " · "))"
                return "• \(step.action)\(suffix)"
            }.joined(separator: "\n\n")
        }
    }

    public static func decode(kind: MeetingAIJobKind, payloadJSON: String) throws -> MeetingAIOutput {
        guard let data = payloadJSON.data(using: .utf8) else {
            throw MeetingAIError.invalidOutput("Le JSON IA n'est pas en UTF-8.")
        }
        let decoder = JSONDecoder()
        switch kind {
        case .title:
            return .title(try decoder.decode(TitlePayload.self, from: data).title)
        case .summary:
            return .summary(try decoder.decode(SummaryPayload.self, from: data).summary)
        case .questions:
            return .questions(try decoder.decode(QuestionsPayload.self, from: data).questions)
        case .nextSteps:
            return .nextSteps(try decoder.decode(NextStepsPayload.self, from: data).nextSteps)
        }
    }
}

public struct TitlePayload: Codable, Sendable {
    public let title: String
}

public struct SummaryPayload: Codable, Sendable {
    public let summary: String
}

public struct QuestionsPayload: Codable, Sendable {
    public let questions: [String]
}

public struct NextStepsPayload: Codable, Sendable {
    public let nextSteps: [MeetingAIOutput.NextStep]

    enum CodingKeys: String, CodingKey {
        case nextSteps = "next_steps"
    }
}

public enum MeetingAIError: LocalizedError, Sendable {
    case executableUnavailable(String)
    case emptyTranscript
    case launchFailed(String)
    case processFailed(Int32, String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case let .executableUnavailable(path):
            "Codex est introuvable ou non executable : \(path)"
        case .emptyTranscript:
            "Le transcript ne contient encore aucun segment exploitable."
        case let .launchFailed(message):
            "Impossible de lancer Codex : \(message)"
        case let .processFailed(status, message):
            "Codex s'est termine avec le code \(status). \(message)"
        case let .invalidOutput(message):
            "La reponse de Codex est invalide : \(message)"
        }
    }
}
