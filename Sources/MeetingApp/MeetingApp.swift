import AppKit
import SwiftUI

@main
struct MeetingApplication: App {
    @StateObject private var controller = MeetingController()
    @StateObject private var aiController = MeetingAIController()

    var body: some Scene {
        WindowGroup("Meeting") {
            MeetingRootView()
                .environmentObject(controller)
                .environmentObject(aiController)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_080, height: 720)

        MenuBarExtra("Meeting", systemImage: controller.isRecording ? "waveform" : "waveform.slash") {
            Button(controller.isRecording ? "Arreter la transcription" : "Nouvelle reunion") {
                if controller.isRecording {
                    controller.stopMeeting()
                } else {
                    controller.startMeeting()
                }
            }
            .disabled(controller.isBusy)

            Divider()

            Button("Ouvrir Meeting") {
                controller.openMainWindow()
            }

            Button("Actions IA") {
                aiController.openPanel()
            }
            .disabled(controller.selectedMeetingID == nil)

            Text(controller.status)
        }
    }
}
