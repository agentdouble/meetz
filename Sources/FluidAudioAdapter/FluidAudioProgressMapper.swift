import FluidAudio
import TranscriptionCore

enum FluidAudioProgressMapper {
    static func map(_ progress: DownloadProgress) -> ModelPreparationProgress {
        let activity: ModelPreparationProgress.Activity
        switch progress.phase {
        case .listing:
            activity = .listing
        case let .downloading(completedFiles, totalFiles):
            activity = .downloading(
                completedFiles: completedFiles,
                totalFiles: totalFiles
            )
        case let .compiling(modelName):
            activity = .compiling(modelName: modelName)
        }

        return ModelPreparationProgress(
            fractionCompleted: progress.fractionCompleted,
            activity: activity
        )
    }
}
