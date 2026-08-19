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
    case transitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .authorizationCancelled: "Administrator authorization was cancelled."
        case .authorizationFailed(let detail): "Administrator authorization failed.\n\(detail)"
        case .authorizationRequestUnavailable(let detail): "Could not request administrator authorization.\n\(detail)"
        case .transitionFailed(let detail): "DFU transition failed.\n\(detail)"
        }
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
        catch { throw CommunityDFUError.authorizationRequestUnavailable(error.localizedDescription) }
        guard result.status == 0 else {
            let output = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = output.lowercased()
            if lower.contains("(-128)") || lower.contains("user canceled") || lower.contains("user cancelled") {
                throw CommunityDFUError.authorizationCancelled
            }
            if lower.contains("(-60007)") || lower.contains("not authorized") || lower.contains("authorization denied") {
                throw CommunityDFUError.authorizationFailed(output.isEmpty ? "osascript exited with status \(result.status)." : output)
            }
            throw CommunityDFUError.transitionFailed(output.isEmpty ? "macvdmtool exited through osascript with status \(result.status)." : output)
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
