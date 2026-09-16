import DFUCore
import Foundation

public enum RestoreFailurePresentation {
    public static let hostSoftwareTitle = "Host macOS Update Required"

    public static func hostSoftwareMessage(target: DFUDevice?, release: IPSWRelease?) -> String {
        var lines = [
            "Apple's restore framework on this Mac is too old for the selected restore.",
            "Update macOS, then try again."
        ]
        if let product = target?.restoreProductType {
            lines.append("\nTarget: \(target?.friendlyName ?? product) (\(product))")
        }
        if let release {
            lines.append("Selected system: \(release.platform.displayName) \(release.version) (\(release.build))")
        }
        lines.append("\nThe restore could not proceed because Apple's host restore framework was rejected.")
        return lines.joined(separator: "\n")
    }

    public static func message(for error: Error, target: DFUDevice?, release: IPSWRelease?) -> String? {
        guard let error = error as? DFUError, error.restoreFailureKind == .hostSoftwareOutOfDate else { return nil }
        return hostSoftwareMessage(target: target, release: release)
    }
}
