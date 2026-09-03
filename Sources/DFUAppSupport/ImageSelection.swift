import DFUCore
import Foundation

public enum IPSWChoiceCacheState: Equatable, Sendable {
    case downloaded(URL)
    case partial(Int64)
    case downloadRequired
    case invalid
    case validating

    public var label: String {
        switch self {
        case .downloaded: "Downloaded and validated"
        case .partial: "Partial download"
        case .downloadRequired: "Download required"
        case .invalid: "Invalid cached image"
        case .validating: "Validating"
        }
    }
}

public enum IPSWCompatibility: Equatable, Sendable {
    case universalAppleSilicon
    case compatible(model: String)
    case uncertain

    public var label: String {
        switch self {
        case .universalAppleSilicon: "Universal Apple Silicon image"
        case .compatible(let model): "Compatible with \(model)"
        case .uncertain: "Compatibility depends on connected target"
        }
    }
}

public struct IPSWChoice: Identifiable, Equatable, Sendable {
    public var id: FirmwareReleaseKey { FirmwareReleaseKey(release) }
    public let release: IPSWRelease
    public let isRecommended: Bool
    public let cacheState: IPSWChoiceCacheState
    public let compatibility: IPSWCompatibility
}

public struct FirmwareReleaseKey: Hashable, Sendable {
    public let platform: RestorePlatform
    public let version: String
    public let build: String
    public let supportedDevices: [String]
    public let mobileAssetIdentity: String

    public init(_ release: IPSWRelease) {
        platform = release.platform
        version = release.version
        build = release.build
        // A single mobile OS build can have several product-specific IPSWs.
        // Keep those variants distinct while retaining the historical universal
        // key for macOS and catalogue records whose compatibility is unknown.
        supportedDevices = release.platform == .macOS
            ? []
            : release.supportedDevices.map { $0.lowercased() }.sorted()
        mobileAssetIdentity = release.platform == .macOS
            ? ""
            : release.checksum?.lowercased() ?? release.downloadURL.absoluteString
    }
}

public extension IPSWRelease {
    var conciseSupportedProducts: String? {
        guard platform != .macOS, !supportedDevices.isEmpty else { return nil }
        let products = supportedDevices.sorted()
        if products.count <= 3 { return products.joined(separator: ", ") }
        return "\(products[0]), \(products[1]) +\(products.count - 2) more"
    }
}

public enum SelectedImagePresentation: Equatable, Sendable {
    case unavailable
    case managed(release: IPSWRelease, cacheState: IPSWChoiceCacheState)
    case local(url: URL, isValid: Bool, error: String?)
}

public struct ImageDownloadPresentation: Equatable, Sendable {
    public let release: IPSWRelease
    public let completed: Int64
    public let total: Int64?
    public let bytesPerSecond: Double?
    public var fraction: Double? { total.flatMap { $0 > 0 ? min(max(Double(completed) / Double($0), 0), 1) : nil } }
}

public enum ImageDownloadPresentationState: Equatable, Sendable {
    case idle
    case preparing(ImageDownloadPresentation)
    case downloading(ImageDownloadPresentation)
    case validating
    case completed
    case cancelled
    case failed(String)

    public var progress: ImageDownloadPresentation? {
        switch self { case .preparing(let value), .downloading(let value): value; default: nil }
    }
    public var isDeterminate: Bool { progress?.fraction != nil }
}

public struct MainWindowConfiguration: Equatable, Sendable {
    public let defaultWidth: Double, defaultHeight: Double, minimumWidth: Double, minimumHeight: Double, maximumWorkspaceWidth: Double
    public static let standard = Self(defaultWidth: 1040, defaultHeight: 800, minimumWidth: 760, minimumHeight: 500, maximumWorkspaceWidth: 1160)
}
