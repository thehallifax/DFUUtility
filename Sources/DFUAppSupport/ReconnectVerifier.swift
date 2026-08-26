import DFUCore
import Foundation

public enum ReconnectResult: Equatable, Sendable { case restarted(DFUDevice), unverified }

public struct ReconnectVerifier: Sendable {
    private let discovery: any DeviceDiscovering
    public init(discovery: any DeviceDiscovering) { self.discovery = discovery }
    public func wait(expectedECID: String? = nil, attempts: Int = 10, interval: Duration = .seconds(2)) async -> ReconnectResult {
        for index in 0..<attempts {
            guard !Task.isCancelled else { return .unverified }
            if index > 0 {
                do { try await Task.sleep(for: interval) }
                catch { return .unverified }
            }
            guard !Task.isCancelled else { return .unverified }
            if let devices = try? discovery.devices() {
                if let expectedECID, let device = devices.first(where: { $0.state == .normal && $0.ecid?.caseInsensitiveCompare(expectedECID) == .orderedSame }) { return .restarted(device) }
                if expectedECID == nil, devices.count == 1, devices[0].state == .normal { return .restarted(devices[0]) }
            }
        }
        return .unverified
    }
}
