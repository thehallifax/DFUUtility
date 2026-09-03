import DFUCore
import Foundation

public enum ShareableDiagnostics {
    @MainActor public static func render(
        report: DoctorReport?,
        privilegeMode: PrivilegeMode,
        cacheEntries: [ManagedIPSWEntry],
        updateState: AppUpdateState,
        updateSourceHealth: String,
        operationState: AppRestoreState,
        operationLogAvailable: Bool
    ) -> String {
        var lines = [
            "DFUUtility Sanitized Diagnostics",
            "App version: \(BuildMetadata.displayVersion)",
            "Architecture: \(architecture)",
            "Privilege mode: \(privilegeMode == .community ? "Community" : "Signed helper")"
        ] + AccessoryConnectionReadiness().diagnosticLines
        if let report {
            lines += [
                "macOS: \(report.status.host.macOSVersion)",
                "cfgutil: \(report.status.host.cfgutilPath == nil ? "Unavailable" : "Available")",
                "macvdmtool: \(toolDescription(report.status.host))"
            ]
            if report.status.targets.isEmpty {
                lines.append("Targets: None")
            } else {
                lines.append("Targets: \(report.status.targets.count)")
                for target in report.status.targets {
                    lines.append("Target: family \(target.family.displayName), state \(target.state.rawValue), product \(target.restoreProductType ?? "Unknown"), stable identity \(target.ecid?.isEmpty == false ? "Yes" : "No")")
                }
            }
        } else {
            lines += ["System diagnostics: Not loaded", "cfgutil: Unknown", "macvdmtool: Unknown", "Targets: Unknown"]
        }
        let validated = cacheEntries.filter { $0.state == .completeValidated }.count
        let partial = cacheEntries.filter { $0.state == .partial }.count
        let invalid = cacheEntries.filter { $0.state == .invalid }.count
        let total = cacheEntries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        lines.append("Firmware cache: \(cacheEntries.count) item(s), \(validated) validated, \(partial) partial, \(invalid) invalid, \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
        lines.append("Update source: \(updateSourceHealth); \(updateDescription(updateState))")
        lines.append("Most recent operation: \(operationDescription(operationState))")
        lines.append("Operation log available: \(operationLogAvailable ? "Yes" : "No")")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func toolDescription(_ host: HostStatus) -> String {
        guard host.macVDMToolPath != nil else { return "Unavailable" }
        return "Available (\(host.macVDMToolSource?.category ?? "source unknown"))"
    }

    private static func updateDescription(_ state: AppUpdateState) -> String {
        switch state {
        case .idle: "not checked this session"
        case .checking: "Checking"
        case .current: "Healthy; current"
        case .available: "Healthy; update available"
        case .unavailable(let message): "Unavailable — \(sanitizedCategory(message))"
        case .preparing: "Preparing update"
        case .failed: "Check failed"
        }
    }

    private static func operationDescription(_ state: AppRestoreState) -> String {
        switch state {
        case .idle: "None this session"
        case .running(let operation, _, _, _, _): "\(operation) in progress"
        case .reconnecting(let operation): "\(operation) waiting for reconnect"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    private static func sanitizedCategory(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("source folder") { return "recorded source unavailable" }
        return "update unavailable"
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
