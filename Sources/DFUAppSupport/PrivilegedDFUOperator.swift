import DFUCore
import Foundation

/// Shared GUI DFU transition verifier. The injected requester may use either the
/// signed service or the system-owned Community authorization dialog.
public struct PrivilegedDFUOperator: DFUOperating {
    private let discovery: any DeviceDiscovering
    private let client: any PrivilegedDFURequesting

    public init(discovery: any DeviceDiscovering = ConfiguratorDeviceDiscovery(), client: any PrivilegedDFURequesting = PrivilegedDFUClient()) {
        self.discovery = discovery; self.client = client
    }

    public func enterDFU(timeout: TimeInterval) throws {
        let before = try discovery.devices()
        guard before.count == 1 else { if before.isEmpty { throw DFUError.noTarget }; throw DFUError.multipleTargets(before.count) }
        guard before[0].state == .normal else { throw DFUError.targetNotInDFU }
        let expected = before[0].ecid
        try client.enterDFU()
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let devices = try discovery.devices()
            if let dfu = devices.first(where: { $0.state == .dfu }) {
                if let expected, dfu.ecid?.caseInsensitiveCompare(expected) != .orderedSame { throw DFUError.targetChanged(expected: expected, actual: dfu.ecid) }
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        throw DFUError.transitionTimedOut
    }
}
