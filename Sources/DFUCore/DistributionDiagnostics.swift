import Foundation
import Security

public struct CodeSignatureInfo: Equatable, Sendable {
    public let identifier: String?, teamIdentifier: String?, isValid: Bool, hardenedRuntime: Bool
    public init(identifier: String?, teamIdentifier: String?, isValid: Bool, hardenedRuntime: Bool) {
        self.identifier = identifier; self.teamIdentifier = teamIdentifier; self.isValid = isValid; self.hardenedRuntime = hardenedRuntime
    }
    public static func inspect(_ url: URL) -> CodeSignatureInfo {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return .init(identifier: nil, teamIdentifier: nil, isValid: false, hardenedRuntime: false) }
        var raw: CFDictionary?
        let valid = SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [CFString: Any] else { return .init(identifier: nil, teamIdentifier: nil, isValid: valid, hardenedRuntime: false) }
        let flags = (info[kSecCodeInfoFlags] as? NSNumber)?.uint32Value ?? 0
        let codeSignatureRuntimeFlag: UInt32 = 0x0001_0000 // CS_RUNTIME from cs_blobs.h
        return .init(identifier: info[kSecCodeInfoIdentifier] as? String, teamIdentifier: info[kSecCodeInfoTeamIdentifier] as? String, isValid: valid, hardenedRuntime: flags & codeSignatureRuntimeFlag != 0)
    }
}

public enum AcceptanceDiagnostics {
    public static func render(report: DoctorReport?, helperState: PrivilegedHelperState, appURL: URL = Bundle.main.bundleURL) -> String {
        let app = CodeSignatureInfo.inspect(appURL)
        let helperURL = appURL.appendingPathComponent("Contents/Library/LaunchServices/DFUPrivilegedHelper")
        let helper = CodeSignatureInfo.inspect(helperURL)
        var lines = [
            "DFUUtility Diagnostics", "App version: \(BuildMetadata.displayVersion)", "Git commit: \(BuildMetadata.gitCommit)", "Build date: \(BuildMetadata.buildDate)",
            "Architecture: \(runtimeArchitecture)", "App signature: \(app.isValid ? "Valid" : "Invalid/Unavailable")", "App Team ID: \(app.teamIdentifier ?? "Ad hoc / unavailable")",
            "App hardened runtime: \(app.hardenedRuntime ? "Yes" : "No")", "Privileged helper: \(helperState.description)", "Required helper protocol: \(BuildMetadata.helperProtocolVersion)",
            "Helper signature: \(helper.isValid ? "Valid" : "Invalid/Unavailable")", "Helper Team ID: \(helper.teamIdentifier ?? "Ad hoc / unavailable")", "macvdmtool revision: \(BuildMetadata.macVDMToolRevision)"
        ]
        if let report {
            lines += ["macOS: \(report.status.host.macOSVersion)", "Apple Configurator: \(report.configuratorPresent ? "Available" : "Unavailable")", "cfgutil: \(report.status.host.cfgutilPath?.path ?? "Unavailable")", "macvdmtool: \(report.status.host.macVDMToolPath?.path ?? "Unavailable")", "Cache: \(report.cacheDirectory.path)"]
            if report.status.targets.isEmpty { lines.append("Target: None") }
            for target in report.status.targets { lines.append("Target: \(target.state.rawValue), model \(target.model ?? "Unknown"), ECID \(target.ecid ?? "Unknown")") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
    private static var runtimeArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
