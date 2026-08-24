import Foundation
import MeetingAI
import MeetingDomain
import TranscriptStore

actor MeetingAIService {
    struct RunResult: Sendable {
        let storedResult: MeetingAIResult
        let output: MeetingAIOutput
        let didChangeMeetingTitle: Bool
    }

    private let runner = CodexHeadlessRunner()
    private let store: SQLiteTranscriptStore

    init() throws {
        store = try SQLiteTranscriptStore()
    }

    func run(
        kind: MeetingAIJobKind,
        meetingID: UUID,
        executablePath: String
    ) async throws -> RunResult {
        guard let meeting = try await store.meetings().first(where: { $0.id == meetingID }) else {
            throw MeetingAIError.invalidOutput("La reunion selectionnee est introuvable.")
        }
        let storedSegments = try await store.segments(meetingID: meetingID)
        let segments = ExploitableTranscriptSelection.preferredSegments(
            from: storedSegments
        )
        let output = try await runner.run(
            kind: kind,
            transcript: MeetingAITranscriptExport(meeting: meeting, segments: segments),
            executablePath: executablePath
        )
        let result = MeetingAIResult(
            meetingID: meetingID,
            kind: kind,
            payloadJSON: output.payloadJSON,
            sourceSegmentCount: segments.count
        )
        try await store.saveAIResult(result)

        var didChangeMeetingTitle = false
        if kind == .title, case let .title(title) = output {
            didChangeMeetingTitle = try await store.applyAITitleIfAutomatic(
                id: meetingID,
                title: title
            )
        }
        return RunResult(
            storedResult: result,
            output: output,
            didChangeMeetingTitle: didChangeMeetingTitle
        )
    }

    func results(meetingID: UUID) async throws -> [MeetingAIResult] {
        try await store.aiResults(meetingID: meetingID)
    }

    func enqueue(meetingID: UUID, kinds: [MeetingAIJobKind]) async throws {
        try await store.enqueueAIJobs(meetingID: meetingID, kinds: kinds)
    }

    func pendingJobs() async throws -> [PendingMeetingAIJob] {
        try await store.pendingAIJobs()
    }

    func runPending(
        _ job: PendingMeetingAIJob,
        executablePath: String
    ) async throws -> RunResult {
        let result = try await run(
            kind: job.kind,
            meetingID: job.meetingID,
            executablePath: executablePath
        )
        try await store.completeAIJob(meetingID: job.meetingID, kind: job.kind)
        return result
    }
}
