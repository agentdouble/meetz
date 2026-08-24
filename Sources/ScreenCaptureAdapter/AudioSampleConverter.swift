@preconcurrency import AVFoundation
import CoreMedia
import Foundation

final class AudioSampleConverter {
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private var converter: AVAudioConverter?
    private var currentInputFormat: AVAudioFormat?

    func samples(from sampleBuffer: CMSampleBuffer) throws -> [Float] {
        guard let formatDescription = sampleBuffer.formatDescription else {
            return []
        }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        if currentInputFormat != inputFormat || converter == nil {
            currentInputFormat = inputFormat
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }

        guard let converter else { return [] }

        return try sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                bufferListNoCopy: audioBufferList.unsafePointer
            ) else {
                return []
            }
            inputBuffer.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)

            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(
                ceil(Double(inputBuffer.frameLength) * ratio) + 64
            )
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputCapacity
            ) else {
                return []
            }

            var conversionError: NSError?
            let inputBox = ConverterInputBox(buffer: inputBuffer)
            let status = converter.convert(to: outputBuffer, error: &conversionError) {
                _, inputStatus in
                if inputBox.didProvide {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputBox.didProvide = true
                inputStatus.pointee = .haveData
                return inputBox.buffer
            }

            if let conversionError {
                throw conversionError
            }
            guard status == .haveData || status == .inputRanDry else { return [] }
            guard let channel = outputBuffer.floatChannelData?.pointee else { return [] }

            return Array(
                UnsafeBufferPointer(
                    start: channel,
                    count: Int(outputBuffer.frameLength)
                )
            )
        }
    }
}

private final class ConverterInputBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var didProvide = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
