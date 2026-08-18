import Foundation

public struct DFUController: Sendable {
    private let discovery: any DeviceDiscovering
    private let runner: any CommandRunning
    private let tool: URL?

    public init(discovery: any DeviceDiscovering = ConfiguratorDeviceDiscovery(), runner: any CommandRunning = ProcessRunner(), tool: URL? = ToolLocator.executable(named: "macvdmtool")) {
        self.discovery = discovery
        self.runner = runner
        self.tool = tool
    }

    public func enterDFU(timeout: TimeInterval = 30) throws {
        guard ProcessInfo.processInfo.machineHardwareName == "arm64" else { throw DFUError.unsupportedHost }
        guard let tool else { throw DFUError.toolUnavailable("macvdmtool (set DFUCTL_MACVDMTOOL_PATH if installed elsewhere)") }

        let existing = try discovery.devices()
        if existing.count > 1 { throw DFUError.multipleTargets(existing.count) }
        let command: URL
        let arguments: [String]
        if geteuid() == 0 {
            command = tool; arguments = ["dfu"]
        } else {
            command = URL(fileURLWithPath: "/usr/bin/sudo"); arguments = [tool.path, "dfu"]
        }
        let result = try runner.run(command, arguments: arguments)
        guard result.status == 0 else {
            throw DFUError.commandFailed(command: "macvdmtool dfu", status: result.status, output: result.combinedOutput)
        }

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try discovery.devices().contains(where: { $0.state == .dfu }) { return }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        throw DFUError.transitionTimedOut
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var system = utsname(); uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
