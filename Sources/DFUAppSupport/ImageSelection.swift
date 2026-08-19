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
        case .downloaded: "Downloaded"
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
    public var id: String { release.build }
    public let release: IPSWRelease
    public let isRecommended: Bool
    public let cacheState: IPSWChoiceCacheState
    public let compatibility: IPSWCompatibility
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
