import Foundation

/// Read-only presentation of macOS accessory-authorization readiness.
///
/// Apple documents the user-facing setting and managed restriction, but does
/// not provide ordinary applications with a supported API for reading the
/// effective policy. Keep this honest until such an API exists; do not infer a
/// value from private preferences or System Settings implementation details.
public struct AccessoryConnectionReadiness: Equatable, Sendable {
    public enum Policy: Equatable, Sendable {
        case notReliablyReadable
    }

    public let policy: Policy

    public init(policy: Policy = .notReliablyReadable) {
        self.policy = policy
    }

    public var detectedState: String {
        switch policy {
        case .notReliablyReadable: "Not available — macOS does not provide DFUUtility a supported way to read this setting"
        }
    }

    public var diagnosticLines: [String] {
        [
            "Accessory Connections: \(detectedState)",
            "Check in System Settings: Privacy & Security → Accessories → Allow accessories to connect",
            "Dedicated workstation guidance: Automatically allow when unlocked reduces repeated approval prompts while retaining protection when the Mac is locked."
        ]
    }
}
