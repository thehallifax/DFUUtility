import Foundation

public enum DeviceState: String, Codable, Sendable {
    case normal = "Normal"
    case recovery = "Recovery"
    case dfu = "DFU"
    case unknown = "Unknown"
}

public struct DFUDevice: Codable, Equatable, Sendable {
    public var state: DeviceState
    public var model: String?
    public var identifier: String?
    public var ecid: String?

    public init(state: DeviceState, model: String? = nil, identifier: String? = nil, ecid: String? = nil) {
        self.state = state
        self.model = model
        self.identifier = identifier
        self.ecid = ecid
    }

    public var friendlyName: String? {
        switch model { case "Mac14,2": "MacBook Air M2"; default: nil }
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
    case transitionTimedOut
    case targetChanged(expected: String, actual: String?)
    case invalidIPSW(String)
    case commandFailed(command: String, status: Int32, output: String)
    case privilegeRequired(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedHost: "The host must be an Apple Silicon Mac."
        case .toolUnavailable(let tool): "Required tool is unavailable: \(tool)."
        case .noTarget: "No suitable target Mac was detected. Check the data-capable cable and DFU port."
        case .multipleTargets(let count): "Found \(count) possible targets. Disconnect all but one target."
        case .targetNotInDFU: "A target is connected, but it is not in DFU mode."
        case .transitionTimedOut: "The target did not appear in DFU mode before the timeout. Check the cable and DFU port."
        case .targetChanged(let expected, let actual): "DFU transition could not be verified for the original target (expected ECID \(expected), found \(actual ?? "unknown"))."
        case .invalidIPSW(let reason): "Invalid IPSW: \(reason)"
        case .commandFailed(let command, let status, let output):
            "Command failed (exit \(status)): \(command)\n\(output)"
        case .privilegeRequired(let output): "Administrator authorization for macvdmtool failed.\n\(output)"
        }
    }
}
