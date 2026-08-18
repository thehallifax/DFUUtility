import DFUCore
import Foundation

public enum ReconnectResult: Equatable, Sendable { case restarted(DFUDevice), unverified }

public struct ReconnectVerifier: Sendable {
    private let discovery: any DeviceDiscovering
    public init(discovery: any DeviceDiscovering) { self.discovery = discovery }
    public func wait(attempts: Int = 10, interval: Duration = .seconds(2)) async -> ReconnectResult {
        for index in 0..<attempts {
            if index > 0 { try? await Task.sleep(for: interval) }
            if let devices = try? discovery.devices(), devices.count == 1, devices[0].state == .normal { return .restarted(devices[0]) }
        }
        return .unverified
    }
}
