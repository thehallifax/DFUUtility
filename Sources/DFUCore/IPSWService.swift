import Foundation

public enum SigningStatus: String, Codable, Sendable { case unknown }

public struct IPSWRelease: Codable, Hashable, Sendable {
    public let version: String
    public let build: String
    public let downloadURL: URL
    public var fileSize: Int64?
    public let checksum: String?
    public let supportedDevices: [String]
    public let signingStatus: SigningStatus?

    public init(version: String, build: String, downloadURL: URL, fileSize: Int64? = nil, checksum: String? = nil, supportedDevices: [String] = [], signingStatus: SigningStatus? = .unknown, isSigned: Bool? = nil) {
        self.version = version; self.build = build; self.downloadURL = downloadURL
        self.fileSize = fileSize; self.checksum = checksum; self.supportedDevices = supportedDevices
        self.signingStatus = signingStatus
    }

    public var isSigned: Bool? { nil }
}

public struct DownloadProgress: Sendable { public let received: Int64; public let total: Int64?; public let bytesPerSecond: Double; public let resumed: Bool }

public enum DownloadEvent: Sendable {
    case started(release: IPSWRelease)
    case resumed(existingBytes: Int64)
    case progress(completed: Int64, total: Int64?, bytesPerSecond: Double?)
    case validating
    case completed(url: URL)
    case cancelled
}

public protocol IPSWService: Sendable {
    func availableImages(for device: DFUDevice?) async throws -> [IPSWRelease]
    func recommendedImage(for device: DFUDevice?) async throws -> IPSWRelease
    func download(_ release: IPSWRelease, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL
    func downloadEvents(_ release: IPSWRelease) -> AsyncThrowingStream<DownloadEvent, Error>
}

public extension IPSWService {
    func availableImages(for device: DFUDevice) async throws -> [IPSWRelease] { try await availableImages(for: Optional(device)) }
    func recommendedImage(for device: DFUDevice) async throws -> IPSWRelease { try await recommendedImage(for: Optional(device)) }
    func download(_ release: IPSWRelease) async throws -> URL { try await download(release, progress: { _ in }) }
    func downloadEvents(_ release: IPSWRelease) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.started(release: release))
                do {
                    let url = try await download(release) { value in continuation.yield(.progress(completed: value.received, total: value.total, bytesPerSecond: value.bytesPerSecond)) }
                    continuation.yield(.completed(url: url)); continuation.finish()
                } catch is CancellationError { continuation.yield(.cancelled); continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public enum IPSWServiceError: LocalizedError, Equatable {
    case malformedCatalogue(String), noReleases, unknownBuild(String), untrustedURL(String), http(Int)
    case incorrectSize(expected: Int64, actual: Int64), checksumMismatch(expected: String, actual: String)
    public var errorDescription: String? {
        switch self {
        case .malformedCatalogue(let reason): "Apple IPSW catalogue is malformed: \(reason)"
        case .noReleases: "Apple's catalogue contains no applicable macOS restore images."
        case .unknownBuild(let build): "No discovered IPSW has build \(build)."
        case .untrustedURL(let url): "Refusing non-Apple firmware URL: \(url)"
        case .http(let status): "Apple download server returned HTTP \(status)."
        case .incorrectSize(let expected, let actual): "Downloaded size is incorrect (expected \(expected), got \(actual))."
        case .checksumMismatch(let expected, let actual): "IPSW checksum mismatch (expected \(expected), got \(actual))."
        }
    }
}

public struct AppleIPSWService: IPSWService {
    private let catalogue: any IPSWCatalogueFetching; private let downloader: any IPSWDownloading
    private let cache: IPSWCache; private let validator: any IPSWValidating
    public init(catalogue: any IPSWCatalogueFetching = AppleIPSWCatalogue(), downloader: any IPSWDownloading = AppleIPSWDownloader(), cache: IPSWCache = IPSWCache(), validator: any IPSWValidating = IPSWValidator()) {
        self.catalogue = catalogue; self.downloader = downloader; self.cache = cache; self.validator = validator
    }
    public func availableImages(for device: DFUDevice?) async throws -> [IPSWRelease] {
        let releases = try await catalogue.releases()
        let filtered = device?.model.map { model in releases.filter { $0.supportedDevices.isEmpty || $0.supportedDevices.contains(model) } } ?? releases
        return Self.sortNewestFirst(filtered)
    }
    public func recommendedImage(for device: DFUDevice?) async throws -> IPSWRelease {
        guard let first = try await availableImages(for: device).first else { throw IPSWServiceError.noReleases }; return first
    }
    public func download(_ release: IPSWRelease, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        try cache.prepare()
        if let hit = try cache.validCachedURL(for: release, validator: validator) { return hit }
        let partial = cache.partialURL(for: release)
        try await downloader.download(release, to: partial, progress: progress)
        try validator.validate(partial, release: release, verifyChecksum: true)
        return try cache.commit(partial: partial, release: release)
    }
    public func downloadEvents(_ release: IPSWRelease) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.started(release: release))
                do {
                    try cache.prepare()
                    if let hit = try cache.validCachedURL(for: release, validator: validator) { continuation.yield(.completed(url: hit)); continuation.finish(); return }
                    let partial = cache.partialURL(for: release)
                    let existing = ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size]) as? NSNumber)?.int64Value ?? 0
                    if existing > 0 { continuation.yield(.resumed(existingBytes: existing)) }
                    try await downloader.download(release, to: partial) { value in continuation.yield(.progress(completed: value.received, total: value.total, bytesPerSecond: value.bytesPerSecond)) }
                    try Task.checkCancellation(); continuation.yield(.validating)
                    try validator.validate(partial, release: release, verifyChecksum: true)
                    try Task.checkCancellation(); let url = try cache.commit(partial: partial, release: release)
                    continuation.yield(.completed(url: url)); continuation.finish()
                } catch is CancellationError { continuation.yield(.cancelled); continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public static func sortNewestFirst(_ releases: [IPSWRelease]) -> [IPSWRelease] {
        releases.sorted { a, b in
            let lhs = a.version.split(separator: ".").map { Int($0) ?? 0 }, rhs = b.version.split(separator: ".").map { Int($0) ?? 0 }
            if lhs != rhs { return rhs.lexicographicallyPrecedes(lhs) }
            return a.build.localizedStandardCompare(b.build) == .orderedDescending
        }
    }
}
