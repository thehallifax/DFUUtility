import Foundation

public struct CachedIPSW: Sendable {
    public let release: IPSWRelease; public let url: URL; public let validation: IPSWValidationResult
    public var isValid: Bool { validation == .valid }
}
public enum ManagedIPSWEntryState: String, Codable, Sendable { case completeValidated, completeUnvalidated, partial, invalid }
public struct ManagedIPSWEntry: Identifiable, Equatable, Sendable {
    public var id: String { url.standardizedFileURL.path }
    public let release: IPSWRelease
    public let state: ManagedIPSWEntryState
    public let sizeBytes: Int64
    public let url: URL
    public let validationFailure: IPSWValidationFailure?
    public init(release: IPSWRelease, state: ManagedIPSWEntryState, sizeBytes: Int64, url: URL, validationFailure: IPSWValidationFailure? = nil) { self.release = release; self.state = state; self.sizeBytes = sizeBytes; self.url = url; self.validationFailure = validationFailure }
}
public struct IPSWCache: Sendable {
    public let directory: URL
    public init(directory: URL? = nil) { self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DFUUtility/IPSW", isDirectory: true) }
    public var downloadsDirectory: URL { directory.appendingPathComponent("downloads", isDirectory: true) }
    public func prepare() throws { try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true) }
    public func prepare(for release: IPSWRelease) throws {
        let folder = downloadsDirectory(for: release)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try metadataData(for: release).write(to: partialMetadataURL(for: release), options: .atomic)
    }
    private func platformDirectory(for release: IPSWRelease) -> URL { release.platform == .macOS ? directory : directory.appendingPathComponent(release.platform.rawValue, isDirectory: true) }
    private func downloadsDirectory(for release: IPSWRelease) -> URL { release.platform == .macOS ? downloadsDirectory : platformDirectory(for: release).appendingPathComponent("downloads", isDirectory: true) }
    public func releaseDirectory(for release: IPSWRelease) -> URL { platformDirectory(for: release).appendingPathComponent(safe(release.build), isDirectory: true) }
    public func destination(for release: IPSWRelease) -> URL {
        if release.platform == .macOS { return releaseDirectory(for: release).appendingPathComponent("UniversalMac_\(safe(release.version))_\(safe(release.build))_Restore.ipsw") }
        let product = release.supportedDevices.count == 1 ? "\(safe(release.supportedDevices[0]))_" : ""
        return releaseDirectory(for: release).appendingPathComponent("\(product)\(release.platform.rawValue)_\(safe(release.version))_\(safe(release.build))_Restore.ipsw")
    }
    public func partialURL(for release: IPSWRelease) -> URL { downloadsDirectory(for: release).appendingPathComponent("\(safe(release.build)).partial") }
    private func partialMetadataURL(for release: IPSWRelease) -> URL { downloadsDirectory(for: release).appendingPathComponent("\(safe(release.build)).json") }
    public func validCachedURL(for release: IPSWRelease, validator: any IPSWValidating) throws -> URL? {
        let url = destination(for: release); guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return validator.validationResult(url, release: release, verifyChecksum: false) == .valid ? url : nil
    }
    public func cachedURL(for release: IPSWRelease) -> URL? { let url = destination(for: release); return FileManager.default.fileExists(atPath: url.path) ? url : nil }
    public func commit(partial: URL, release: IPSWRelease) throws -> URL {
        let fm = FileManager.default, target = destination(for: release); try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }; try fm.moveItem(at: partial, to: target)
        try metadataData(for: release).write(to: releaseDirectory(for: release).appendingPathComponent("metadata.json"), options: .atomic)
        try? fm.removeItem(at: partialMetadataURL(for: release))
        return target
    }
    public func managedEntries(validator: any IPSWValidating, knownReleases: [IPSWRelease] = []) throws -> [ManagedIPSWEntry] {
        let fm = FileManager.default
        var values = try entries(validator: validator).compactMap { cached -> ManagedIPSWEntry? in
            guard fm.fileExists(atPath: cached.url.path) else { return nil }
            let failure: IPSWValidationFailure? = if case .invalid(let value) = cached.validation { value } else { nil }
            return ManagedIPSWEntry(release: cached.release, state: cached.isValid ? .completeValidated : .invalid, sizeBytes: fileSize(cached.url), url: cached.url, validationFailure: failure)
        }
        let roots = [downloadsDirectory, directory.appendingPathComponent("iOS/downloads"), directory.appendingPathComponent("iPadOS/downloads")]
        for root in roots where fm.fileExists(atPath: root.path) {
            for partial in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) where partial.pathExtension == "partial" {
                let metadata = partial.deletingPathExtension().appendingPathExtension("json")
                let release = (try? Data(contentsOf: metadata)).flatMap { try? JSONDecoder().decode(IPSWRelease.self, from: $0) }
                    ?? knownReleases.first { safe($0.build) == partial.deletingPathExtension().lastPathComponent && downloadsDirectory(for: $0).standardizedFileURL == root.standardizedFileURL }
                if let release { values.append(ManagedIPSWEntry(release: release, state: .partial, sizeBytes: fileSize(partial), url: partial)) }
            }
        }
        return values.sorted {
            if $0.release.platform != $1.release.platform { return $0.release.platform.rawValue < $1.release.platform.rawValue }
            return $0.release.version.localizedStandardCompare($1.release.version) == .orderedDescending
        }
    }
    public func remove(_ entry: ManagedIPSWEntry) throws {
        let fm = FileManager.default
        guard entry.url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") else { throw CocoaError(.fileWriteNoPermission) }
        switch entry.state {
        case .partial:
            if fm.fileExists(atPath: entry.url.path) { try fm.removeItem(at: entry.url) }
            let metadata = entry.url.deletingPathExtension().appendingPathExtension("json")
            if fm.fileExists(atPath: metadata.path) { try fm.removeItem(at: metadata) }
        case .completeValidated, .completeUnvalidated, .invalid:
            let folder = entry.url.deletingLastPathComponent()
            if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        }
    }
    public func entries(validator: any IPSWValidating) throws -> [CachedIPSW] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }; let fm = FileManager.default
        let roots = [directory, directory.appendingPathComponent(RestorePlatform.iOS.rawValue), directory.appendingPathComponent(RestorePlatform.iPadOS.rawValue)]
        let folders = try roots.filter { fm.fileExists(atPath: $0.path) }.flatMap { try fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) }
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("metadata.json")), let release = try? JSONDecoder().decode(IPSWRelease.self, from: data) else { return nil }
            let url = destination(for: release), validation = validator.validationResult(url, release: release, verifyChecksum: false)
            return CachedIPSW(release: release, url: url, validation: validation)
        }.sorted { $0.release.version.localizedStandardCompare($1.release.version) == .orderedDescending }
    }
    @discardableResult public func clean(partials: Bool, invalid: Bool, validator: any IPSWValidating) throws -> Int {
        var removed = 0; let fm = FileManager.default
        if partials {
            let roots = [downloadsDirectory, directory.appendingPathComponent("iOS/downloads"), directory.appendingPathComponent("iPadOS/downloads")]
            for root in roots where fm.fileExists(atPath: root.path) { for url in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where url.pathExtension == "partial" { try fm.removeItem(at: url); removed += 1 } }
        }
        if invalid { for entry in try entries(validator: validator) where !entry.isValid { try fm.removeItem(at: entry.url.deletingLastPathComponent()); removed += 1 } }
        return removed
    }
    private func metadataData(for release: IPSWRelease) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(release) }
    private func fileSize(_ url: URL) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0 }
    private func safe(_ input: String) -> String { String(input.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-" }) }
}
