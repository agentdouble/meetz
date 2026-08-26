import CaptureCore
import Foundation

public actor DurableAudioJournal {
    public struct Configuration: Sendable, Equatable {
        public let minimumBlockDuration: TimeInterval
        public let maximumBlockDuration: TimeInterval
        public let quietRootMeanSquare: Double
        public let synchronizationInterval: TimeInterval

        public init(
            minimumBlockDuration: TimeInterval = 20,
            maximumBlockDuration: TimeInterval = 30,
            quietRootMeanSquare: Double = 0.003,
            synchronizationInterval: TimeInterval = 1
        ) {
            self.minimumBlockDuration = minimumBlockDuration
            self.maximumBlockDuration = maximumBlockDuration
            self.quietRootMeanSquare = quietRootMeanSquare
            self.synchronizationInterval = synchronizationInterval
        }
    }

    private struct WriterKey: Hashable {
        let meetingID: UUID
        let input: AudioInputKind
    }

    private final class WAVWriter {
        let meetingID: UUID
        let input: AudioInputKind
        let sequence: Int
        let startTime: TimeInterval
        let sampleRate: Int
        let partialURL: URL
        let finalURL: URL
        let handle: FileHandle
        var sampleCount = 0
        var samplesSinceSynchronization = 0

        init(
            meetingID: UUID,
            input: AudioInputKind,
            sequence: Int,
            startTime: TimeInterval,
            sampleRate: Int,
            sessionIdentifier: String,
            directory: URL
        ) throws {
            self.meetingID = meetingID
            self.input = input
            self.sequence = sequence
            self.startTime = startTime
            self.sampleRate = sampleRate

            let startMilliseconds = Int64((startTime * 1_000).rounded())
            let baseName = String(
                format: "%06d_%@_%012lld_%@.wav",
                sequence,
                input.rawValue,
                startMilliseconds,
                sessionIdentifier
            )
            finalURL = directory.appendingPathComponent(baseName)
            partialURL = directory.appendingPathComponent(baseName + ".part")

            guard FileManager.default.createFile(
                atPath: partialURL.path,
                contents: Self.header(sampleRate: sampleRate, sampleCount: 0)
            ) else {
                throw AudioJournalError.cannotCreateFile(partialURL)
            }
            handle = try FileHandle(forUpdating: partialURL)
            try handle.seekToEnd()
        }

        var duration: TimeInterval {
            Double(sampleCount) / Double(sampleRate)
        }

        func append(_ samples: [Float], synchronizationSampleCount: Int) throws {
            guard !samples.isEmpty else { return }
            var integers = [Int16]()
            integers.reserveCapacity(samples.count)
            for sample in samples {
                let bounded = min(max(sample, -1), 1)
                integers.append(Int16((bounded * Float(Int16.max)).rounded()))
            }
            let data = integers.withUnsafeBytes { Data($0) }
            try handle.write(contentsOf: data)
            sampleCount += integers.count
            samplesSinceSynchronization += integers.count
            try updateHeader()
            if samplesSinceSynchronization >= synchronizationSampleCount {
                try handle.synchronize()
                samplesSinceSynchronization = 0
            }
        }

        func finalize() throws -> RecordedAudioBlock {
            try updateHeader()
            try handle.synchronize()
            try handle.close()
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: partialURL, to: finalURL)
            return RecordedAudioBlock(
                id: Self.blockID(meetingID: meetingID, fileURL: finalURL),
                meetingID: meetingID,
                input: input,
                sequence: sequence,
                startTime: startTime,
                duration: duration,
                sampleRate: sampleRate,
                fileURL: finalURL
            )
        }

        private func updateHeader() throws {
            let header = Self.header(sampleRate: sampleRate, sampleCount: sampleCount)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header)
            try handle.seekToEnd()
        }

        static func blockID(meetingID: UUID, fileURL: URL) -> String {
            "\(meetingID.uuidString)/\(fileURL.lastPathComponent)"
        }

        static func header(sampleRate: Int, sampleCount: Int) -> Data {
            let dataByteCount = UInt32(clamping: sampleCount * MemoryLayout<Int16>.size)
            let riffByteCount = UInt32(clamping: 36 + Int(dataByteCount))
            let byteRate = UInt32(clamping: sampleRate * MemoryLayout<Int16>.size)
            let blockAlign = UInt16(MemoryLayout<Int16>.size)
            var data = Data()
            data.appendASCII("RIFF")
            data.appendLittleEndian(riffByteCount)
            data.appendASCII("WAVE")
            data.appendASCII("fmt ")
            data.appendLittleEndian(UInt32(16))
            data.appendLittleEndian(UInt16(1))
            data.appendLittleEndian(UInt16(1))
            data.appendLittleEndian(UInt32(clamping: sampleRate))
            data.appendLittleEndian(byteRate)
            data.appendLittleEndian(blockAlign)
            data.appendLittleEndian(UInt16(16))
            data.appendASCII("data")
            data.appendLittleEndian(dataByteCount)
            return data
        }
    }

    private let rootURL: URL
    private let configuration: Configuration
    private let sessionIdentifier: String
    private var writers: [WriterKey: WAVWriter] = [:]
    private var nextSequenceByKey: [WriterKey: Int] = [:]

    public init(
        rootURL: URL? = nil,
        configuration: Configuration = Configuration(),
        sessionIdentifier: String = String(UUID().uuidString.prefix(8))
    ) throws {
        self.rootURL = try rootURL ?? Self.defaultRootURL()
        self.configuration = configuration
        let normalizedSessionIdentifier = sessionIdentifier.filter { $0.isLetter || $0.isNumber }
        self.sessionIdentifier = normalizedSessionIdentifier.isEmpty
            ? String(UUID().uuidString.prefix(8))
            : normalizedSessionIdentifier
        try FileManager.default.createDirectory(
            at: self.rootURL,
            withIntermediateDirectories: true
        )
    }

    public func append(
        _ chunk: AudioChunk,
        meetingID: UUID
    ) throws -> [RecordedAudioBlock] {
        guard chunk.sampleRate > 0, !chunk.samples.isEmpty else { return [] }
        let key = WriterKey(meetingID: meetingID, input: chunk.input)
        let writer = try writer(for: key, chunk: chunk)
        guard writer.sampleRate == chunk.sampleRate else {
            throw AudioJournalError.sampleRateChanged(
                expected: writer.sampleRate,
                received: chunk.sampleRate
            )
        }

        let synchronizationSamples = max(
            1,
            Int(configuration.synchronizationInterval * Double(chunk.sampleRate))
        )
        try writer.append(
            chunk.samples,
            synchronizationSampleCount: synchronizationSamples
        )

        let isQuiet = AudioMath.rootMeanSquare(of: chunk.samples)
            <= configuration.quietRootMeanSquare
        let shouldFinalize = writer.duration >= configuration.maximumBlockDuration
            || (writer.duration >= configuration.minimumBlockDuration && isQuiet)
        guard shouldFinalize else { return [] }

        writers.removeValue(forKey: key)
        return [try writer.finalize()]
    }

    public func finish(meetingID: UUID) throws -> [RecordedAudioBlock] {
        let keys = writers.keys
            .filter { $0.meetingID == meetingID }
            .sorted { $0.input.rawValue < $1.input.rawValue }
        var blocks: [RecordedAudioBlock] = []
        for key in keys {
            guard let writer = writers.removeValue(forKey: key) else { continue }
            if writer.sampleCount >= Int(Double(writer.sampleRate) * 0.3) {
                blocks.append(try writer.finalize())
            } else {
                try? writer.handle.close()
                try? FileManager.default.removeItem(at: writer.partialURL)
            }
        }
        return blocks
    }

    public func recoverPendingBlocks() throws -> [RecordedAudioBlock] {
        try repairPartialFiles()
        let meetingDirectories = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var blocks: [RecordedAudioBlock] = []
        for directory in meetingDirectories {
            guard let meetingID = UUID(uuidString: directory.lastPathComponent) else { continue }
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            for fileURL in files where fileURL.pathExtension == "wav" {
                if let block = try Self.block(from: fileURL, meetingID: meetingID) {
                    blocks.append(block)
                }
            }
        }
        return blocks.sorted {
            if $0.meetingID != $1.meetingID {
                return $0.meetingID.uuidString < $1.meetingID.uuidString
            }
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.input.rawValue < $1.input.rawValue
        }
    }

    public func acknowledge(_ block: RecordedAudioBlock) throws {
        let resolvedFile = block.fileURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedFile.path.hasPrefix(resolvedRoot.path + "/") else {
            throw AudioJournalError.invalidFile(block.fileURL)
        }
        if FileManager.default.fileExists(atPath: block.fileURL.path) {
            try FileManager.default.removeItem(at: block.fileURL)
        }
        try removeDirectoryIfEmpty(block.fileURL.deletingLastPathComponent())
    }

    public func discardMeeting(_ meetingID: UUID) throws {
        let directory = rootURL.appendingPathComponent(meetingID.uuidString, isDirectory: true)
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedDirectory.path.hasPrefix(resolvedRoot.path + "/") else {
            throw AudioJournalError.invalidFile(directory)
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func writer(for key: WriterKey, chunk: AudioChunk) throws -> WAVWriter {
        if let writer = writers[key] { return writer }
        let directory = rootURL.appendingPathComponent(key.meetingID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sequence = nextSequenceByKey[key, default: 0]
        nextSequenceByKey[key] = sequence + 1
        let writer = try WAVWriter(
            meetingID: key.meetingID,
            input: key.input,
            sequence: sequence,
            startTime: chunk.startTime,
            sampleRate: chunk.sampleRate,
            sessionIdentifier: sessionIdentifier,
            directory: directory
        )
        writers[key] = writer
        return writer
    }

    private func repairPartialFiles() throws {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.lastPathComponent.hasSuffix(".wav.part") else { continue }
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            let fileSize = values.fileSize ?? 0
            guard fileSize >= 44 + Int(0.3 * 16_000 * 2) else {
                try? FileManager.default.removeItem(at: fileURL)
                continue
            }
            let sampleCount = max(0, (fileSize - 44) / 2)
            let handle = try FileHandle(forUpdating: fileURL)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: WAVWriter.header(sampleRate: 16_000, sampleCount: sampleCount))
            try handle.synchronize()
            try handle.close()
            let finalURL = fileURL.deletingPathExtension()
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            } else {
                try FileManager.default.moveItem(at: fileURL, to: finalURL)
            }
        }
    }

    private static func block(from fileURL: URL, meetingID: UUID) throws -> RecordedAudioBlock? {
        let components = fileURL.deletingPathExtension().lastPathComponent.split(separator: "_")
        guard (components.count == 3 || components.count == 4),
              let sequence = Int(components[0]),
              let input = AudioInputKind(rawValue: String(components[1])),
              let startMilliseconds = Int64(components[2])
        else { return nil }
        let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let sampleCount = max(0, (fileSize - 44) / 2)
        guard sampleCount >= Int(0.3 * 16_000) else { return nil }
        return RecordedAudioBlock(
            id: WAVWriter.blockID(meetingID: meetingID, fileURL: fileURL),
            meetingID: meetingID,
            input: input,
            sequence: sequence,
            startTime: Double(startMilliseconds) / 1_000,
            duration: Double(sampleCount) / 16_000,
            sampleRate: 16_000,
            fileURL: fileURL
        )
    }

    private func removeDirectoryIfEmpty(_ directory: URL) throws {
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        if remaining.isEmpty {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private static func defaultRootURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("Meeting", isDirectory: true)
            .appendingPathComponent("AudioJournal", isDirectory: true)
    }
}

public enum AudioJournalError: LocalizedError, Sendable {
    case cannotCreateFile(URL)
    case invalidFile(URL)
    case sampleRateChanged(expected: Int, received: Int)

    public var errorDescription: String? {
        switch self {
        case let .cannotCreateFile(url):
            "Impossible de creer le journal audio local : \(url.lastPathComponent)"
        case let .invalidFile(url):
            "Le fichier audio ne fait pas partie du journal Meeting : \(url.lastPathComponent)"
        case let .sampleRateChanged(expected, received):
            "Le taux audio a change pendant un bloc (\(expected) vers \(received) Hz)."
        }
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(value.data(using: .ascii)!)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
