import Foundation
import MeetingAI
import MeetingDomain

let executablePath = ProcessInfo.processInfo.environment["MEETING_CODEX_PATH"]
    ?? "/opt/homebrew/bin/codex"
let meeting = MeetingRecord(
    title: "Reunion de controle",
    titleOrigin: .automatic,
    context: "Verifier le runner IA sans utiliser de donnees personnelles.",
    state: .completed
)
let segment = TranscriptSegment(
    meetingID: meeting.id,
    speakerID: "speaker-1",
    speakerName: "Alice",
    startTime: 0,
    endTime: 4,
    text: "Nous devons confirmer le budget avant vendredi, mais le montant exact manque.",
    confidence: 0.98
)

do {
    let runner = CodexHeadlessRunner()
    let configuration = CodexRunConfiguration(
        model: ProcessInfo.processInfo.environment["MEETING_CODEX_MODEL"] ?? "",
        reasoningEffort: ProcessInfo.processInfo.environment["MEETING_CODEX_EFFORT"]
            .flatMap(CodexReasoningEffort.init(rawValue:))
            ?? .inherit
    )
    let transcript = MeetingAITranscriptExport(meeting: meeting, segments: [segment])
    let output = try await runner.run(
        kind: .questions,
        transcript: transcript,
        executablePath: executablePath,
        configuration: configuration
    )
    guard case let .questions(questions) = output, !questions.isEmpty else {
        throw MeetingAIError.invalidOutput("Aucune question n'a ete retournee.")
    }
    let answer = try await runner.chat(
        question: "Quel point doit encore etre clarifie ?",
        history: [],
        transcript: transcript,
        executablePath: executablePath,
        configuration: configuration
    )
    guard !answer.isEmpty else {
        throw MeetingAIError.invalidOutput("Le chat n'a retourne aucune reponse.")
    }
    print("OK: Codex headless questions=\(questions.count), chat=ready")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
