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

    struct ChatRunResult: Sendable {
        let userMessage: MeetingAIChatMessage
        let assistantMessage: MeetingAIChatMessage
    }

    private let runner = CodexHeadlessRunner()
    private let store: SQLiteTranscriptStore

    init() throws {
        store = try SQLiteTranscriptStore()
    }

    func run(
        kind: MeetingAIJobKind,
        meetingID: UUID,
        executablePath: String,
        configuration: CodexRunConfiguration
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
            executablePath: executablePath,
            configuration: configuration
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

    func chatMessages(meetingID: UUID) async throws -> [MeetingAIChatMessage] {
        try await store.aiChatMessages(meetingID: meetingID)
    }

    func chat(
        userMessage: MeetingAIChatMessage,
        meetingID: UUID,
        executablePath: String,
        configuration: CodexRunConfiguration
    ) async throws -> ChatRunResult {
        guard let meeting = try await store.meetings().first(where: { $0.id == meetingID }) else {
            throw MeetingAIError.invalidOutput("La reunion selectionnee est introuvable.")
        }
        let storedSegments = try await store.segments(meetingID: meetingID)
        let segments = ExploitableTranscriptSelection.preferredSegments(from: storedSegments)
        let history = try await store.aiChatMessages(meetingID: meetingID)
        let normalizedQuestion = userMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuestion.isEmpty else {
            throw MeetingAIError.invalidOutput("La question est vide.")
        }
        guard userMessage.meetingID == meetingID, userMessage.role == .user else {
            throw MeetingAIError.invalidOutput("Le message du chat est invalide.")
        }
        try await store.saveAIChatMessage(userMessage)

        let answer = try await runner.chat(
            question: normalizedQuestion,
            history: history,
            transcript: MeetingAITranscriptExport(meeting: meeting, segments: segments),
            executablePath: executablePath,
            configuration: configuration
        )
        let assistantMessage = MeetingAIChatMessage(
            meetingID: meetingID,
            role: .assistant,
            content: answer
        )
        try await store.saveAIChatMessage(assistantMessage)
        return ChatRunResult(userMessage: userMessage, assistantMessage: assistantMessage)
    }

    func enqueueAutomaticJobs(meetingID: UUID, kinds: [MeetingAIJobKind]) async throws {
        guard let meeting = try await meeting(id: meetingID) else { return }
        let segments = try await exploitableSegments(meetingID: meetingID)
        guard !segments.isEmpty else {
            try await completePendingJobs(meetingID: meetingID, kinds: kinds)
            return
        }

        let applicableKinds = kinds.filter { kind in
            kind != .title || meeting.titleOrigin == .automatic
        }
        guard !applicableKinds.isEmpty else { return }
        try await store.enqueueAIJobs(meetingID: meetingID, kinds: applicableKinds)
    }

    func reconcileAutomaticTitleJobs() async throws {
        for job in try await store.pendingAIJobs() {
            if try await exploitableSegments(meetingID: job.meetingID).isEmpty {
                try await store.completeAIJob(meetingID: job.meetingID, kind: job.kind)
            }
        }

        for meeting in try await store.meetings() where meeting.titleOrigin == .automatic {
            guard try await !exploitableSegments(meetingID: meeting.id).isEmpty else { continue }
            try await store.enqueueAIJobs(meetingID: meeting.id, kinds: [.title])
        }
    }

    func pendingJobs() async throws -> [PendingMeetingAIJob] {
        try await store.pendingAIJobs()
    }

    func runPending(
        _ job: PendingMeetingAIJob,
        executablePath: String,
        configuration: CodexRunConfiguration
    ) async throws -> RunResult? {
        do {
            let result = try await run(
                kind: job.kind,
                meetingID: job.meetingID,
                executablePath: executablePath,
                configuration: configuration
            )
            try await store.completeAIJob(meetingID: job.meetingID, kind: job.kind)
            return result
        } catch MeetingAIError.emptyTranscript {
            try await store.completeAIJob(meetingID: job.meetingID, kind: job.kind)
            return nil
        }
    }

    private func meeting(id: UUID) async throws -> MeetingRecord? {
        try await store.meetings().first { $0.id == id }
    }

    private func exploitableSegments(meetingID: UUID) async throws -> [TranscriptSegment] {
        ExploitableTranscriptSelection.preferredSegments(
            from: try await store.segments(meetingID: meetingID)
        )
    }

    private func completePendingJobs(
        meetingID: UUID,
        kinds: [MeetingAIJobKind]
    ) async throws {
        for kind in kinds {
            try await store.completeAIJob(meetingID: meetingID, kind: kind)
        }
    }
}
