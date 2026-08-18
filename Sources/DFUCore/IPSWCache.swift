import Foundation

public struct CachedIPSW: Sendable { public let release: IPSWRelease; public let url: URL; public let isValid: Bool }
public struct IPSWCache: Sendable {
    public let directory: URL
    public init(directory: URL? = nil) { self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DFUUtility/IPSW", isDirectory: true) }
    public var downloadsDirectory: URL { directory.appendingPathComponent("downloads", isDirectory: true) }
    public func prepare() throws { try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true) }
    public func releaseDirectory(for release: IPSWRelease) -> URL { directory.appendingPathComponent(safe(release.build), isDirectory: true) }
    public func destination(for release: IPSWRelease) -> URL { releaseDirectory(for: release).appendingPathComponent("UniversalMac_\(safe(release.version))_\(safe(release.build))_Restore.ipsw") }
    public func partialURL(for release: IPSWRelease) -> URL { downloadsDirectory.appendingPathComponent("\(safe(release.build)).partial") }
    public func validCachedURL(for release: IPSWRelease, validator: any IPSWValidating) throws -> URL? {
        let url = destination(for: release); guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { try validator.validate(url, release: release, verifyChecksum: false); return url } catch { return nil }
    }
    public func cachedURL(for release: IPSWRelease) -> URL? { let url = destination(for: release); return FileManager.default.fileExists(atPath: url.path) ? url : nil }
    public func commit(partial: URL, release: IPSWRelease) throws -> URL {
        let fm = FileManager.default, target = destination(for: release); try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }; try fm.moveItem(at: partial, to: target)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(release).write(to: releaseDirectory(for: release).appendingPathComponent("metadata.json"), options: .atomic); return target
    }
    public func entries(validator: any IPSWValidating) throws -> [CachedIPSW] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }; let fm = FileManager.default
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("metadata.json")), let release = try? JSONDecoder().decode(IPSWRelease.self, from: data) else { return nil }
            let url = destination(for: release), valid = (try? validator.validate(url, release: release, verifyChecksum: false)) != nil
            return CachedIPSW(release: release, url: url, isValid: valid)
        }.sorted { $0.release.version.localizedStandardCompare($1.release.version) == .orderedDescending }
    }
    @discardableResult public func clean(partials: Bool, invalid: Bool, validator: any IPSWValidating) throws -> Int {
        var removed = 0; let fm = FileManager.default
        if partials, fm.fileExists(atPath: downloadsDirectory.path) { for url in try fm.contentsOfDirectory(at: downloadsDirectory, includingPropertiesForKeys: nil) where url.pathExtension == "partial" { try fm.removeItem(at: url); removed += 1 } }
        if invalid { for entry in try entries(validator: validator) where !entry.isValid { try fm.removeItem(at: entry.url.deletingLastPathComponent()); removed += 1 } }
        return removed
    }
    private func safe(_ input: String) -> String { String(input.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-" }) }
}
