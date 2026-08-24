import AVFoundation
import CaptureCore
import CoreMedia
import Foundation

enum AudioBufferMeter {
    static func level(in sampleBuffer: CMSampleBuffer) -> Double? {
        guard
            let formatDescription = sampleBuffer.formatDescription,
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
            )?.pointee,
            streamDescription.mFormatID == kAudioFormatLinearPCM
        else {
            return nil
        }

        var requiredSize = 0
        var retainedBlockBuffer: CMBlockBuffer?

        let sizingStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )

        guard sizingStatus == noErr, requiredSize > 0 else { return nil }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let bufferListPointer = rawPointer.bindMemory(
            to: AudioBufferList.self,
            capacity: 1
        )

        retainedBlockBuffer = nil
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferListPointer,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )

        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        let isFloat = streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = streamDescription.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0

        var squareSum = 0.0
        var sampleCount = 0

        for buffer in buffers {
            guard let data = buffer.mData else { continue }

            if isFloat, streamDescription.mBitsPerChannel == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<count {
                    let value = Double(samples[index])
                    squareSum += value * value
                }
                sampleCount += count
            } else if isSignedInteger, streamDescription.mBitsPerChannel == 16 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                let samples = data.assumingMemoryBound(to: Int16.self)
                for index in 0..<count {
                    let value = Double(samples[index]) / Double(Int16.max)
                    squareSum += value * value
                }
                sampleCount += count
            }
        }

        guard sampleCount > 0 else { return nil }
        let rootMeanSquare = sqrt(squareSum / Double(sampleCount))
        return AudioMath.meterLevel(fromRootMeanSquare: rootMeanSquare)
    }
}
