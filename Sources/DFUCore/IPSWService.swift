import Foundation

public struct IPSWRelease: Codable, Hashable, Sendable {
    public let version: String
    public let build: String
    public let downloadURL: URL
    public let fileSize: Int64?
    public let checksum: String?
    public let supportedDevices: [String]
    public let isSigned: Bool?

    public init(version: String, build: String, downloadURL: URL, fileSize: Int64? = nil, checksum: String? = nil, supportedDevices: [String] = [], isSigned: Bool? = nil) {
        self.version = version; self.build = build; self.downloadURL = downloadURL
        self.fileSize = fileSize; self.checksum = checksum; self.supportedDevices = supportedDevices; self.isSigned = isSigned
    }
}

public protocol IPSWService: Sendable {
    func availableImages(for device: DFUDevice) async throws -> [IPSWRelease]
    func recommendedImage(for device: DFUDevice) async throws -> IPSWRelease
    func download(_ release: IPSWRelease) async throws -> URL
}

public struct IPSWCache: Sendable {
    public let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DFUUtility/IPSW", isDirectory: true)
    }

    public func cachedURL(for release: IPSWRelease) -> URL? {
        let candidate = destination(for: release)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              release.fileSize == nil || release.fileSize == size else { return nil }
        return candidate
    }

    public func destination(for release: IPSWRelease) -> URL {
        let safe = "UniversalMac_\(release.version)_\(release.build)_Restore.ipsw"
            .replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent(safe)
    }
}
