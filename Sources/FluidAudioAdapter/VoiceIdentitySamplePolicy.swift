import CaptureCore
import Foundation

public enum VoiceIdentitySamplePolicy {
    // CAM++ normalise lui-meme le signal. Ce seuil sert uniquement a exclure le
    // silence reel, sans rejeter une voix distante entendue faiblement au micro.
    public static let minimumRootMeanSquare = 0.0015

    public static func rootMeanSquare(of samples: [Float]) -> Double {
        AudioMath.rootMeanSquare(of: samples)
    }

    public static func accepts(_ samples: [Float]) -> Bool {
        rootMeanSquare(of: samples) >= minimumRootMeanSquare
    }
}
