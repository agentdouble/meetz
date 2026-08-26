import AppKit
import Foundation
import MeetingAI
import MeetingDomain

@MainActor
final class MeetingAIController: ObservableObject {
    @Published var isShowingSettings = false
    @Published var isShowingPanel = false
    @Published private(set) var results: [MeetingAIResult] = []
    @Published private(set) var resultsMeetingID: UUID?
    @Published private(set) var runningKinds: Set<MeetingAIJobKind> = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastCompletedKind: MeetingAIJobKind?
    @Published private(set) var shortcut: AIShortcut
    @Published private(set) var chatMessages: [MeetingAIChatMessage] = []
    @Published private(set) var chatMeetingID: UUID?
    @Published private(set) var isChatRunning = false
    @Published var codexExecutablePath: String {
        didSet { defaults.set(codexExecutablePath, forKey: Keys.codexPath) }
    }
    @Published var codexModel: String {
        didSet { defaults.set(codexModel, forKey: Keys.codexModel) }
    }
    @Published var codexReasoningEffort: CodexReasoningEffort {
        didSet { defaults.set(codexReasoningEffort.rawValue, forKey: Keys.codexReasoningEffort) }
    }
    @Published var automaticallyGenerateTitle: Bool {
        didSet { defaults.set(automaticallyGenerateTitle, forKey: Keys.automaticTitle) }
    }
    @Published var automaticallyGenerateSummary: Bool {
        didSet { defaults.set(automaticallyGenerateSummary, forKey: Keys.automaticSummary) }
    }

    private enum Keys {
        static let codexPath = "meeting.ai.codexPath"
        static let codexModel = "meeting.ai.codexModel"
        static let codexReasoningEffort = "meeting.ai.codexReasoningEffort"
        static let shortcut = "meeting.ai.shortcut"
        static let automaticTitle = "meeting.ai.automaticTitle"
        static let automaticSummary = "meeting.ai.automaticSummary"
    }

    private let defaults: UserDefaults
    private let service: MeetingAIService?
    private let hotKeyManager = GlobalHotKeyManager()
    private var isProcessingPendingJobs = false
    private var needsAnotherPendingJobsPass = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        codexExecutablePath = defaults.string(forKey: Keys.codexPath)
            ?? Self.detectCodexExecutable()
        codexModel = defaults.string(forKey: Keys.codexModel) ?? "gpt-5.6-terra"
        codexReasoningEffort = defaults.string(forKey: Keys.codexReasoningEffort)
            .flatMap(CodexReasoningEffort.init(rawValue:))
            ?? .medium
        automaticallyGenerateTitle = defaults.object(forKey: Keys.automaticTitle) as? Bool ?? true
        automaticallyGenerateSummary = defaults.object(forKey: Keys.automaticSummary) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.shortcut),
           let storedShortcut = try? JSONDecoder().decode(AIShortcut.self, from: data) {
            shortcut = storedShortcut
        } else {
            shortcut = .defaultShortcut
        }
        service = try? MeetingAIService()

        hotKeyManager.onPress = { [weak self] in
            Task { @MainActor in
                self?.openPanel()
            }
        }
        hotKeyManager.register(shortcut)
    }

    var isCodexAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: codexExecutablePath)
    }

    var isRunning: Bool { !runningKinds.isEmpty }

    var configuration: CodexRunConfiguration {
        CodexRunConfiguration(
            model: codexModel,
            reasoningEffort: codexReasoningEffort
        )
    }

    func openPanel() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
        isShowingPanel = true
    }

    func closePanel() {
        isShowingPanel = false
    }

    func updateShortcut(_ newShortcut: AIShortcut) {
        shortcut = newShortcut
        if let data = try? JSONEncoder().encode(newShortcut) {
            defaults.set(data, forKey: Keys.shortcut)
        }
        hotKeyManager.register(newShortcut)
    }

    func detectCodexAgain() {
        codexExecutablePath = Self.detectCodexExecutable()
    }

    func latestResult(for kind: MeetingAIJobKind) -> MeetingAIResult? {
        results.first { $0.kind == kind }
    }

    func displayText(for result: MeetingAIResult) -> String {
        (try? MeetingAIOutput.decode(kind: result.kind, payloadJSON: result.payloadJSON).displayText)
            ?? result.payloadJSON
    }

    func loadResults(meetingID: UUID?) async {
        guard let meetingID, let service else {
            results = []
            resultsMeetingID = nil
            chatMessages = []
            chatMeetingID = nil
            return
        }
        do {
            results = try await service.results(meetingID: meetingID)
            resultsMeetingID = meetingID
            chatMessages = try await service.chatMessages(meetingID: meetingID)
            chatMeetingID = meetingID
        } catch {
            lastError = error.localizedDescription
        }
    }

    func run(_ kind: MeetingAIJobKind, meetingID: UUID, revealPanel: Bool = true) {
        guard !runningKinds.contains(kind), let service else { return }
        if revealPanel { isShowingPanel = true }
        runningKinds.insert(kind)
        lastError = nil

        Task {
            do {
                let run = try await service.run(
                    kind: kind,
                    meetingID: meetingID,
                    executablePath: codexExecutablePath,
                    configuration: configuration
                )
                if resultsMeetingID == meetingID {
                    results.insert(run.storedResult, at: 0)
                }
                lastCompletedKind = kind
                if run.didChangeMeetingTitle {
                    NotificationCenter.default.post(name: .meetingAIDidUpdateMeeting, object: meetingID)
                }
            } catch {
                lastError = error.localizedDescription
            }
            runningKinds.remove(kind)
        }
    }

    func sendChat(_ question: String, meetingID: UUID) {
        let normalizedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuestion.isEmpty, !isChatRunning, let service else { return }
        isShowingPanel = true
        isChatRunning = true
        lastError = nil
        let userMessage = MeetingAIChatMessage(
            meetingID: meetingID,
            role: .user,
            content: normalizedQuestion
        )
        if chatMeetingID == meetingID {
            chatMessages.append(userMessage)
        }
        let executablePath = codexExecutablePath
        let runConfiguration = configuration

        Task {
            do {
                let run = try await service.chat(
                    userMessage: userMessage,
                    meetingID: meetingID,
                    executablePath: executablePath,
                    configuration: runConfiguration
                )
                if chatMeetingID == meetingID {
                    chatMessages.append(run.assistantMessage)
                }
            } catch {
                lastError = error.localizedDescription
                if chatMeetingID == meetingID,
                   let storedMessages = try? await service.chatMessages(meetingID: meetingID) {
                    chatMessages = storedMessages
                }
            }
            isChatRunning = false
        }
    }

    func runAutomaticJobs(meetingID: UUID) {
        guard let service else { return }
        Task {
            var kinds: [MeetingAIJobKind] = []
            if automaticallyGenerateTitle { kinds.append(.title) }
            if automaticallyGenerateSummary { kinds.append(.summary) }
            guard !kinds.isEmpty else { return }
            do {
                try await service.enqueueAutomaticJobs(meetingID: meetingID, kinds: kinds)
                await resumePendingJobs()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func reconcileAutomaticTitles() async {
        guard let service else { return }
        do {
            try await service.reconcileAutomaticTitleJobs()
            await resumePendingJobs()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func resumePendingJobs() async {
        guard let service else { return }
        guard !isProcessingPendingJobs else {
            needsAnotherPendingJobsPass = true
            return
        }
        isProcessingPendingJobs = true
        defer { isProcessingPendingJobs = false }
        var shouldStopAfterFailure = false
        repeat {
            needsAnotherPendingJobsPass = false
            do {
                for job in try await service.pendingJobs() {
                    runningKinds.insert(job.kind)
                    lastError = nil
                    do {
                        guard let run = try await service.runPending(
                            job,
                            executablePath: codexExecutablePath,
                            configuration: configuration
                        ) else {
                            runningKinds.remove(job.kind)
                            continue
                        }
                        if resultsMeetingID == job.meetingID {
                            results.insert(run.storedResult, at: 0)
                        }
                        lastCompletedKind = job.kind
                        if run.didChangeMeetingTitle {
                            NotificationCenter.default.post(
                                name: .meetingAIDidUpdateMeeting,
                                object: job.meetingID
                            )
                        }
                    } catch {
                        lastError = error.localizedDescription
                        runningKinds.remove(job.kind)
                        shouldStopAfterFailure = true
                        break
                    }
                    runningKinds.remove(job.kind)
                }
            } catch {
                lastError = error.localizedDescription
                shouldStopAfterFailure = true
            }
        } while needsAnotherPendingJobsPass && !shouldStopAfterFailure
    }

    private static func detectCodexExecutable() -> String {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/codex" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/opt/homebrew/bin/codex"
    }
}

extension Notification.Name {
    static let meetingDidFinish = Notification.Name("com.jeremy.meeting.didFinish")
    static let meetingAIDidUpdateMeeting = Notification.Name("com.jeremy.meeting.aiDidUpdateMeeting")
}
