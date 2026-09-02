import Foundation

public enum DeviceState: String, Codable, Sendable {
    case normal = "Normal"
    case recovery = "Recovery"
    case dfu = "DFU"
    case unknown = "Unknown"
}

public enum AppleDeviceFamily: String, Codable, CaseIterable, Sendable {
    case mac
    case iPhone
    case iPad
    case unknown

    public var displayName: String {
        switch self { case .mac: "Mac"; case .iPhone: "iPhone"; case .iPad: "iPad"; case .unknown: "Apple device" }
    }

    public var restorePlatform: RestorePlatform {
        switch self {
        case .mac, .unknown: .macOS
        case .iPhone: .iOS
        case .iPad: .iPadOS
        }
    }
}

public struct DFUDevice: Codable, Equatable, Sendable {
    public var family: AppleDeviceFamily
    public var state: DeviceState
    public var model: String?
    public var identifier: String?
    public var ecid: String?
    public var productType: String?
    public var modelIdentifier: String?
    public var serialNumber: String?

    public init(family: AppleDeviceFamily = .mac, state: DeviceState, model: String? = nil, identifier: String? = nil, ecid: String? = nil, productType: String? = nil, modelIdentifier: String? = nil, serialNumber: String? = nil) {
        self.family = family; self.state = state
        self.model = model
        self.identifier = identifier
        self.ecid = ecid
        self.productType = productType ?? model
        self.modelIdentifier = modelIdentifier ?? (family == .mac ? model : nil)
        self.serialNumber = serialNumber
    }

    public var restoreProductType: String? { productType ?? modelIdentifier ?? model }

    public var friendlyName: String? {
        switch restoreProductType {
        case "Mac14,2": "MacBook Air M2"
        case "iPhone7,2": "iPhone 6"
        case "iPad7,11": "iPad (7th generation)"
        case "iPhone15,2": "iPhone 14 Pro"
        case "iPad13,18", "iPad13,19": "iPad (10th generation)"
        default: family == .unknown ? nil : family.displayName
        }
    }
}

public struct HostStatus: Equatable, Sendable {
    public var isAppleSilicon: Bool
    public var macOSVersion: String
    public var macVDMToolPath: URL?
    public var cfgutilPath: URL?
    public var macVDMToolSource: ToolSource?

    public init(isAppleSilicon: Bool, macOSVersion: String, macVDMToolPath: URL? = nil, cfgutilPath: URL? = nil, macVDMToolSource: ToolSource? = nil) {
        self.isAppleSilicon = isAppleSilicon; self.macOSVersion = macOSVersion; self.macVDMToolPath = macVDMToolPath; self.cfgutilPath = cfgutilPath; self.macVDMToolSource = macVDMToolSource
    }
}

public struct UtilityStatus: Equatable, Sendable {
    public var host: HostStatus
    public var targets: [DFUDevice]

    public init(host: HostStatus, targets: [DFUDevice]) { self.host = host; self.targets = targets }
}

public enum DFUError: LocalizedError, Equatable {
    case unsupportedHost
    case toolUnavailable(String)
    case noTarget
    case multipleTargets(Int)
    case targetNotInDFU
    case invalidTargetState(operation: String, target: String, allowedStates: [String])
    case transitionTimedOut
    case targetChanged(expected: String, actual: String?)
    case invalidIPSW(String)
    case commandFailed(command: String, status: Int32, output: String)
    case privilegeRequired(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedHost: "The host must be an Apple Silicon Mac."
        case .toolUnavailable(let tool): "Required tool is unavailable: \(tool)."
        case .noTarget: "No suitable target Apple device was detected. Check the data-capable cable and connection mode."
        case .multipleTargets(let count): "Found \(count) possible targets. Disconnect all but one target."
        case .targetNotInDFU: "A target is connected, but it is not in DFU mode."
        case .invalidTargetState(let operation, let target, let allowedStates):
            "\(operation) requires the \(target) to be in \(Self.joinedStates(allowedStates)) mode."
        case .transitionTimedOut: "The target did not appear in DFU mode before the timeout. Check the cable and DFU port."
        case .targetChanged(let expected, let actual): "DFU transition could not be verified for the original target (expected ECID \(expected), found \(actual ?? "unknown"))."
        case .invalidIPSW(let reason): "Invalid IPSW: \(reason)"
        case .commandFailed(let command, let status, let output):
            "Command failed (exit \(status)): \(command)\n\(output)"
        case .privilegeRequired(let output): "Administrator authorization for macvdmtool failed.\n\(output)"
        }
    }

    private static func joinedStates(_ states: [String]) -> String {
        guard let last = states.last else { return "a supported" }
        guard states.count > 1 else { return last }
        return states.dropLast().joined(separator: ", ") + " or " + last
    }
}
