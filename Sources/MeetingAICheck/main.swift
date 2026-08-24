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
    let output = try await CodexHeadlessRunner().run(
        kind: .questions,
        transcript: MeetingAITranscriptExport(meeting: meeting, segments: [segment]),
        executablePath: executablePath
    )
    guard case let .questions(questions) = output, !questions.isEmpty else {
        throw MeetingAIError.invalidOutput("Aucune question n'a ete retournee.")
    }
    print("OK: Codex headless questions=\(questions.count)")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
