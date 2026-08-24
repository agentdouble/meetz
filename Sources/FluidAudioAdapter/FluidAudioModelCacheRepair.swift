import Foundation

enum FluidAudioModelCacheRepair {
    static func removeInterruptedLSEENDDihard3Bundles() throws {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return
        }

        let cacheRoot = applicationSupport
            .appendingPathComponent("FluidAudio/Models/ls-eend/dih3", isDirectory: true)
            .standardizedFileURL

        guard fileManager.fileExists(atPath: cacheRoot.path),
              let enumerator = fileManager.enumerator(
                  at: cacheRoot,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )
        else {
            return
        }

        var incompleteBundles = Set<URL>()
        for case let partialURL as URL in enumerator where partialURL.pathExtension == "partial" {
            let completedURL = partialURL.deletingPathExtension()
            guard !fileManager.fileExists(atPath: completedURL.path),
                  let bundleURL = compiledModelBundle(containing: partialURL, boundedBy: cacheRoot)
            else {
                continue
            }
            incompleteBundles.insert(bundleURL)
        }

        for bundleURL in incompleteBundles {
            try fileManager.removeItem(at: bundleURL)
        }
    }

    private static func compiledModelBundle(containing fileURL: URL, boundedBy root: URL) -> URL? {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var candidate = fileURL.deletingLastPathComponent().standardizedFileURL

        while candidate.path.hasPrefix(rootPath) {
            if candidate.pathExtension == "mlmodelc" {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }

        return nil
    }
}
