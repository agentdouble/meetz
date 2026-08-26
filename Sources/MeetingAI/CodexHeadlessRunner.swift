import Foundation
import MeetingDomain

public actor CodexHeadlessRunner {
    public init() {}

    public func run(
        kind: MeetingAIJobKind,
        transcript: MeetingAITranscriptExport,
        executablePath: String,
        configuration: CodexRunConfiguration = .inherit
    ) async throws -> MeetingAIOutput {
        guard !transcript.segments.isEmpty else { throw MeetingAIError.emptyTranscript }
        let outputData = try await execute(
            transcript: transcript,
            executablePath: executablePath,
            configuration: configuration,
            prompt: Self.prompt(for: kind),
            schema: Self.schema(for: kind)
        )
        do {
            return try Self.decode(kind: kind, data: outputData)
        } catch {
            throw MeetingAIError.invalidOutput(error.localizedDescription)
        }
    }

    public func chat(
        question: String,
        history: [MeetingAIChatMessage],
        transcript: MeetingAITranscriptExport,
        executablePath: String,
        configuration: CodexRunConfiguration = .inherit
    ) async throws -> String {
        guard !transcript.segments.isEmpty else { throw MeetingAIError.emptyTranscript }
        let normalizedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuestion.isEmpty else {
            throw MeetingAIError.invalidOutput("La question est vide.")
        }

        let boundedHistory = Array(history.suffix(24))
        let historyData = try Self.makeEncoder().encode(
            MeetingAIChatHistoryExport(messages: boundedHistory)
        )
        let outputData = try await execute(
            transcript: transcript,
            executablePath: executablePath,
            configuration: configuration,
            prompt: Self.chatPrompt,
            schema: Self.chatSchema,
            additionalFiles: [
                "conversation.json": historyData,
                "question.txt": Data(normalizedQuestion.utf8),
            ]
        )

        do {
            let answer = try JSONDecoder().decode(ChatAnswerPayload.self, from: outputData)
                .answer
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else {
                throw MeetingAIError.invalidOutput("La reponse du chat est vide.")
            }
            return answer
        } catch let error as MeetingAIError {
            throw error
        } catch {
            throw MeetingAIError.invalidOutput(error.localizedDescription)
        }
    }

    private func execute(
        transcript: MeetingAITranscriptExport,
        executablePath: String,
        configuration: CodexRunConfiguration,
        prompt: String,
        schema: String,
        additionalFiles: [String: Data] = [:]
    ) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw MeetingAIError.executableUnavailable(executablePath)
        }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-ai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let inputURL = workspace.appendingPathComponent("transcript.json")
        let schemaURL = workspace.appendingPathComponent("output.schema.json")
        let outputURL = workspace.appendingPathComponent("output.json")
        let logURL = workspace.appendingPathComponent("codex.log")

        try Self.makeEncoder().encode(transcript).write(to: inputURL, options: .atomic)
        try schema.write(to: schemaURL, atomically: true, encoding: .utf8)
        for (name, data) in additionalFiles {
            try data.write(to: workspace.appendingPathComponent(name), options: .atomic)
        }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.currentDirectoryURL = workspace
        process.arguments = ["exec"]
            + configuration.commandLineArguments
            + [
                "--cd", workspace.path,
                "--sandbox", "read-only",
                "--skip-git-repo-check",
                "--ephemeral",
                "--color", "never",
                "--output-schema", schemaURL.path,
                "--output-last-message", outputURL.path,
                "-",
            ]

        let inputPipe = Pipe()
        let logHandle = try FileHandle(forWritingTo: logURL)
        process.standardInput = inputPipe
        process.standardOutput = logHandle
        process.standardError = logHandle

        let terminationStatus = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { completedProcess in
                continuation.resume(returning: completedProcess.terminationStatus)
            }
            do {
                try process.run()
                inputPipe.fileHandleForWriting.write(Data(prompt.utf8))
                inputPipe.fileHandleForWriting.closeFile()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: MeetingAIError.launchFailed(error.localizedDescription))
            }
        }
        try? logHandle.close()

        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        guard terminationStatus == 0 else {
            throw MeetingAIError.processFailed(terminationStatus, Self.tail(log))
        }
        guard let outputData = try? Data(contentsOf: outputURL), !outputData.isEmpty else {
            throw MeetingAIError.invalidOutput(Self.tail(log))
        }
        return outputData
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func decode(kind: MeetingAIJobKind, data: Data) throws -> MeetingAIOutput {
        let decoder = JSONDecoder()
        switch kind {
        case .title:
            let value = try decoder.decode(TitlePayload.self, from: data)
            guard !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingAIError.invalidOutput("Le titre est vide.")
            }
            return .title(value.title.trimmingCharacters(in: .whitespacesAndNewlines))
        case .summary:
            let value = try decoder.decode(SummaryPayload.self, from: data)
            return .summary(value.summary.trimmingCharacters(in: .whitespacesAndNewlines))
        case .questions:
            let value = try decoder.decode(QuestionsPayload.self, from: data)
            return .questions(value.questions.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        case .nextSteps:
            return .nextSteps(try decoder.decode(NextStepsPayload.self, from: data).nextSteps)
        }
    }

    private static func prompt(for kind: MeetingAIJobKind) -> String {
        """
        Tu analyses une transcription de reunion principalement en francais.
        Lis uniquement le fichier transcript.json du dossier courant. Le contexte de la reunion,
        les intervenants et les segments horodates y sont fournis. N'invente aucune information.
        Retourne uniquement l'objet JSON impose par le schema de sortie.

        Mission : \(instruction(for: kind))
        """
    }

    private static let chatPrompt = """
        Tu es l'assistant d'une transcription de reunion. Lis transcript.json, conversation.json
        et question.txt dans le dossier courant. Reponds a la question en t'appuyant uniquement
        sur le transcript, son contexte et l'historique de conversation. N'invente aucun fait,
        responsable, engagement ou echeance. Si l'information manque, dis-le clairement.
        Reponds en francais sauf demande explicite contraire. Utilise un Markdown simple et concis.
        Retourne uniquement l'objet JSON impose par le schema de sortie.
        """

    private static func instruction(for kind: MeetingAIJobKind) -> String {
        switch kind {
        case .title:
            "Propose un titre court, specifique et naturel en francais, sans guillemets et sans date generique."
        case .summary:
            "Redige un resume concis en francais avec objectif, points importants et conclusion. Utilise du Markdown simple."
        case .questions:
            "Propose entre 3 et 7 questions utiles a poser maintenant pour clarifier les zones floues, risques ou decisions."
        case .nextSteps:
            "Propose les prochaines etapes concretes. N'indique responsable ou echeance que si le transcript permet de les deduire."
        }
    }

    private static func schema(for kind: MeetingAIJobKind) -> String {
        switch kind {
        case .title:
            return objectSchema(properties: "\"title\": {\"type\": \"string\", \"minLength\": 3, \"maxLength\": 100}", required: "\"title\"")
        case .summary:
            return objectSchema(properties: "\"summary\": {\"type\": \"string\", \"minLength\": 1}", required: "\"summary\"")
        case .questions:
            return objectSchema(properties: "\"questions\": {\"type\": \"array\", \"minItems\": 1, \"maxItems\": 7, \"items\": {\"type\": \"string\"}}", required: "\"questions\"")
        case .nextSteps:
            return objectSchema(
                properties: """
                "next_steps": {
                  "type": "array",
                  "items": {
                    "type": "object",
                    "additionalProperties": false,
                    "properties": {
                      "action": {"type": "string"},
                      "owner": {"type": ["string", "null"]},
                      "dueDate": {"type": ["string", "null"]},
                      "rationale": {"type": ["string", "null"]}
                    },
                    "required": ["action", "owner", "dueDate", "rationale"]
                  }
                }
                """,
                required: "\"next_steps\""
            )
        }
    }

    private static let chatSchema = objectSchema(
        properties: "\"answer\": {\"type\": \"string\", \"minLength\": 1}",
        required: "\"answer\""
    )

    private static func objectSchema(properties: String, required: String) -> String {
        """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "type": "object",
          "additionalProperties": false,
          "properties": { \(properties) },
          "required": [\(required)]
        }
        """
    }

    private static func tail(_ value: String, maximumLength: Int = 1_200) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maximumLength else { return normalized }
        return String(normalized.suffix(maximumLength))
    }
}
