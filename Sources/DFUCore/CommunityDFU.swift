import Foundation

public enum PrivilegeMode: String, Equatable, Sendable {
    case community
    case signedHelper

    public var displayName: String { self == .community ? "Community" : "Signed helper" }
}

public enum PrivilegeModeSelector {
    public static func select(appURL: URL = Bundle.main.bundleURL) -> PrivilegeMode {
        guard appURL.pathExtension == "app" else { return .community }
        let app = CodeSignatureInfo.inspect(appURL)
        let helper = CodeSignatureInfo.inspect(appURL.appendingPathComponent("Contents/Library/LaunchServices/\(PrivilegedDFUConstants.helperExecutableName)"))
        return select(app: app, helper: helper)
    }

    public static func select(app: CodeSignatureInfo, helper: CodeSignatureInfo) -> PrivilegeMode {
        guard app.isValid, helper.isValid,
              app.identifier == PrivilegedDFUConstants.appIdentifier,
              helper.identifier == PrivilegedDFUConstants.machService,
              let appTeam = app.teamIdentifier, !appTeam.isEmpty,
              appTeam == helper.teamIdentifier else { return .community }
        return .signedHelper
    }
}

public enum CommunityDFUError: LocalizedError, Equatable {
    case authorizationCancelled
    case authorizationFailed(String)
    case authorizationRequestUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .authorizationCancelled: "Administrator authorization was cancelled."
        case .authorizationFailed(let detail): "Administrator authorization failed.\n\(detail)"
        case .authorizationRequestUnavailable(let detail): "Could not request administrator authorization.\n\(detail)"
        }
    }
}

public enum MacVDMToolFailureKind: String, Equatable, Sendable {
    case noCompatibleTargetPath
    case targetCommunication
    case processLaunch
    case unknown
}

public struct MacVDMToolFailure: LocalizedError, Equatable, Sendable {
    public let kind: MacVDMToolFailureKind
    public let exitStatus: Int32
    public let wrapperExitStatus: Int32?
    public let output: String
    public let replyCode: String?

    public init(kind: MacVDMToolFailureKind, exitStatus: Int32, output: String, replyCode: String? = nil, wrapperExitStatus: Int32? = nil) {
        self.kind = kind; self.exitStatus = exitStatus; self.output = output; self.replyCode = replyCode; self.wrapperExitStatus = wrapperExitStatus
    }

    public static func classify(status: Int32, output: String) -> Self {
        let lower = output.lowercased()
        let kind: MacVDMToolFailureKind
        if lower.contains("no matching devices") || lower.contains("no connection detected") || lower.contains("no rid") {
            kind = .noCompatibleTargetPath
        } else if lower.contains("vdm failed") || lower.contains("failed to send vdm") || lower.contains("did not get a reply to vdm") || lower.contains("failed to enter dbma mode") || lower.contains("failed to unlock device") || lower.contains("readregister failed") || lower.contains("writeregister failed") {
            kind = .targetCommunication
        } else {
            kind = .unknown
        }
        let reply = output.range(of: #"(?i)VDM failed \(reply:\s*(0x[0-9a-f]+)\)"#, options: .regularExpression).flatMap { range -> String? in
            let match = String(output[range]); return match.range(of: #"0x[0-9a-f]+"#, options: [.regularExpression, .caseInsensitive]).map { String(match[$0]) }
        }
        let toolStatus: Int32? = output.range(of: #"\(([0-9]{1,3})\)\s*$"#, options: .regularExpression).flatMap { range in
            String(output[range]).filter(\.isNumber).isEmpty ? nil : Int32(String(output[range]).filter(\.isNumber))
        }
        return Self(kind: kind, exitStatus: toolStatus ?? status, output: output, replyCode: reply, wrapperExitStatus: toolStatus == nil || toolStatus == status ? nil : status)
    }

    public var errorDescription: String? {
        switch kind {
        case .noCompatibleTargetPath: "Couldn’t enter DFU mode. No compatible USB-C DFU connection was found."
        case .targetCommunication where reachedDBMaWithoutFinalReply: "Couldn’t verify the DFU transition. The connected Mac reached the transition stage, but macvdmtool did not receive the final VDM reply."
        case .targetCommunication: "Couldn’t enter DFU mode. The connected Mac was detected, but it did not accept the DFU transition."
        case .processLaunch: "Couldn’t start the bundled DFU component."
        case .unknown: "Couldn’t enter DFU mode because the bundled DFU component failed."
        }
    }

    public var recoverySuggestion: String? {
        switch kind {
        case .noCompatibleTargetPath: "Confirm the data cable is connected to the correct DFU port, then try again."
        case .targetCommunication where reachedDBMaWithoutFinalReply: "The Mac may already be in DFU. Wait briefly, then click Refresh. If it remains absent, reconnect the cable. On newer MacBooks, consult Apple’s model-specific DFU-port guidance and try the alternate appropriate USB-C port."
        case .targetCommunication: "Keep the USB-C cable connected, confirm the target Mac is powered on normally, check Apple’s model-specific DFU-port guidance, then try Enter DFU again."
        case .processLaunch: "Rebuild or reinstall DFUUtility, then try again."
        case .unknown: "Use View Log for technical details, then retry only after checking the target and cable."
        }
    }

    public var diagnosticDescription: String {
        var values = ["macvdmtool failure classification: \(kind.rawValue)", "Exit status: \(exitStatus)"]
        if let wrapperExitStatus { values.append("Authorization wrapper exit status: \(wrapperExitStatus)") }
        if let replyCode { values.append("VDM reply: \(replyCode)") }
        if reachedDBMaWithoutFinalReply {
            values.append("Transition observation: HPM unlock and DBMa transition completed, but the final VDM reply was not received. DFU state remains unverified until rediscovery.")
        }
        values.append("Raw output:\n\(output.isEmpty ? "<none>" : output)")
        return values.joined(separator: "\n")
    }

    public var reachedDBMaWithoutFinalReply: Bool {
        let lower = output.lowercased()
        let unlocked = output.range(of: #"(?im)^Unlocking\.\.\. OK\.?\s*$"#, options: .regularExpression) != nil
        let enteredDBMa = output.range(of: #"(?im)^Entering DBMa mode\.\.\. Status: DBMa\s*$"#, options: .regularExpression) != nil
        return kind == .targetCommunication
            && unlocked && enteredDBMa
            && lower.contains("did not get a reply to vdm")
    }
}

/// The community build exposes exactly one elevated operation. The executable
/// and argument are fixed before AppleScript is constructed; no UI value enters
/// the command string.
public struct CommunityDFURequest: PrivilegedDFURequesting {
    public static let osascriptURL = URL(fileURLWithPath: "/usr/bin/osascript")
    private let runner: any CommandRunning
    private let tool: URL?

    public init(runner: any CommandRunning = ProcessRunner(), tool: URL? = ToolLocator.communityMacVDMTool()?.url) {
        self.runner = runner
        self.tool = tool
    }

    public func enterDFU() throws {
        guard let tool else { throw DFUError.toolUnavailable("bundled/project macvdmtool") }
        guard tool.isFileURL, tool.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw DFUError.toolUnavailable("trusted executable macvdmtool")
        }
        let result: CommandResult
        do { result = try runner.run(Self.osascriptURL, arguments: ["-e", Self.appleScript(tool: tool)]) }
        catch { throw MacVDMToolFailure(kind: .processLaunch, exitStatus: -1, output: error.localizedDescription) }
        guard result.status == 0 else {
            let output = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = output.lowercased()
            if lower.contains("(-128)") || lower.contains("user canceled") || lower.contains("user cancelled") {
                throw CommunityDFUError.authorizationCancelled
            }
            if lower.contains("(-60007)") || lower.contains("not authorized") || lower.contains("authorization denied") {
                throw CommunityDFUError.authorizationFailed(output.isEmpty ? "osascript exited with status \(result.status)." : output)
            }
            throw MacVDMToolFailure.classify(status: result.status, output: output.isEmpty ? "macvdmtool exited through osascript with status \(result.status)." : output)
        }
    }

    public static func appleScript(tool: URL) -> String {
        let command = posixShellQuote(tool.path) + " dfu"
        return "do shell script \(appleScriptLiteral(command)) with administrator privileges"
    }

    public static func posixShellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public extension ToolLocator {
    static func communityMacVDMTool(
        bundleURL: URL? = Bundle.main.bundleURL,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        executableURL: URL? = Bundle.main.executableURL
    ) -> ToolResolution? {
        macVDMTool(environment: [:], bundleURL: bundleURL, bundleResourceURL: bundleResourceURL, executableURL: executableURL, externalCandidates: [])
    }
}
