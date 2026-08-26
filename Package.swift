// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Meeting",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "MeetingDomain", targets: ["MeetingDomain"]),
        .library(name: "CaptureCore", targets: ["CaptureCore"]),
        .library(name: "AudioJournal", targets: ["AudioJournal"]),
        .library(name: "ScreenCaptureAdapter", targets: ["ScreenCaptureAdapter"]),
        .library(name: "TranscriptionCore", targets: ["TranscriptionCore"]),
        .library(name: "FluidAudioAdapter", targets: ["FluidAudioAdapter"]),
        .library(name: "TranscriptStore", targets: ["TranscriptStore"]),
        .library(name: "MeetingAI", targets: ["MeetingAI"]),
        .executable(name: "MeetingApp", targets: ["MeetingApp"]),
        .executable(name: "MeetingCaptureSpike", targets: ["MeetingCaptureSpike"]),
        .executable(name: "MeetingModelCheck", targets: ["MeetingModelCheck"]),
        .executable(name: "MeetingBatchCheck", targets: ["MeetingBatchCheck"]),
        .executable(name: "MeetingRealtimeCheck", targets: ["MeetingRealtimeCheck"]),
        .executable(name: "MeetingAICheck", targets: ["MeetingAICheck"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.6"
        ),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "MeetingDomain"),
        .target(name: "CaptureCore"),
        .target(
            name: "AudioJournal",
            dependencies: ["CaptureCore"]
        ),
        .target(
            name: "ScreenCaptureAdapter",
            dependencies: ["CaptureCore"]
        ),
        .target(
            name: "TranscriptionCore",
            dependencies: ["CaptureCore", "MeetingDomain"]
        ),
        .target(
            name: "FluidAudioAdapter",
            dependencies: [
                "CaptureCore",
                "AudioJournal",
                "MeetingDomain",
                "TranscriptionCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .target(
            name: "TranscriptStore",
            dependencies: ["CSQLite", "MeetingDomain"]
        ),
        .target(
            name: "MeetingAI",
            dependencies: ["MeetingDomain"]
        ),
        .executableTarget(
            name: "MeetingApp",
            dependencies: [
                "CaptureCore",
                "FluidAudioAdapter",
                "MeetingDomain",
                "MeetingAI",
                "ScreenCaptureAdapter",
                "TranscriptStore",
                "TranscriptionCore",
            ]
        ),
        .executableTarget(
            name: "MeetingCaptureSpike",
            dependencies: ["CaptureCore", "ScreenCaptureAdapter"]
        ),
        .executableTarget(
            name: "CaptureCoreChecks",
            dependencies: [
                "AudioJournal",
                "CaptureCore",
                "MeetingDomain",
                "TranscriptStore",
                "TranscriptionCore",
            ]
        ),
        .executableTarget(
            name: "MeetingModelCheck",
            dependencies: ["CaptureCore", "FluidAudioAdapter", "MeetingDomain", "TranscriptionCore"]
        ),
        .executableTarget(
            name: "MeetingBatchCheck",
            dependencies: ["CaptureCore", "FluidAudioAdapter", "TranscriptionCore"]
        ),
        .executableTarget(
            name: "MeetingRealtimeCheck",
            dependencies: ["CaptureCore", "FluidAudioAdapter", "TranscriptionCore"]
        ),
        .executableTarget(
            name: "MeetingAICheck",
            dependencies: ["MeetingAI", "MeetingDomain"]
        ),
    ]
)
