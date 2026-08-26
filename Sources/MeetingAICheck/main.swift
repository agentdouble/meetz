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
let aliceSegment = TranscriptSegment(
    meetingID: meeting.id,
    speakerID: "speaker-1",
    speakerName: "Alice",
    startTime: 0,
    endTime: 4,
    text: "Nous devons confirmer le budget avant vendredi, mais le montant exact manque.",
    confidence: 0.98
)
let bobSegment = TranscriptSegment(
    meetingID: meeting.id,
    speakerID: "speaker-2",
    speakerName: "Bob",
    startTime: 5,
    endTime: 9,
    text: "Je preparerai le calendrier de lancement apres la confirmation d'Alice.",
    confidence: 0.97
)
let aliceFollowUpSegment = TranscriptSegment(
    meetingID: meeting.id,
    speakerID: "speaker-1",
    speakerName: "Alice",
    startTime: 10,
    endTime: 12,
    text: "Je confirmerai le budget avant vendredi.",
    confidence: 0.99
)

do {
    let runner = CodexHeadlessRunner()
    let configuration = CodexRunConfiguration(
        model: ProcessInfo.processInfo.environment["MEETING_CODEX_MODEL"] ?? "",
        reasoningEffort: ProcessInfo.processInfo.environment["MEETING_CODEX_EFFORT"]
            .flatMap(CodexReasoningEffort.init(rawValue:))
            ?? .inherit
    )
    let transcript = MeetingAITranscriptExport(
        meeting: meeting,
        // Ordre volontairement melange pour verifier que les intervenants
        // suivent leur premiere apparition et qu'Alice nest pas dupliquee.
        segments: [bobSegment, aliceFollowUpSegment, aliceSegment]
    )
    guard transcript.schemaVersion == 3,
          transcript.speakers.map(\.speakerName) == ["Alice", "Bob"] else {
        throw MeetingAIError.invalidOutput("La liste des intervenants nest pas exportee correctement.")
    }
    let encodedTranscript = try JSONEncoder().encode(transcript)
    let encodedText = String(decoding: encodedTranscript, as: UTF8.self)
    guard encodedText.contains("\"speakers\""),
          encodedText.contains("\"speakerName\":\"Alice\"") else {
        throw MeetingAIError.invalidOutput("Les intervenants ne sont pas visibles dans le JSON Codex.")
    }
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
        question: "Qui doit confirmer le budget avant vendredi ? Reponds avec son nom.",
        history: [],
        transcript: transcript,
        executablePath: executablePath,
        configuration: configuration
    )
    guard answer.localizedCaseInsensitiveContains("Alice") else {
        throw MeetingAIError.invalidOutput("Le chat na pas attribue le budget a Alice.")
    }
    print("OK: Codex headless questions=\(questions.count), speakers=2, attribution=Alice")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
