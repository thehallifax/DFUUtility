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
        guard !existing.isEmpty else { throw DFUError.noTarget }
        if existing.count > 1 { throw DFUError.multipleTargets(existing.count) }
        let expectedECID = existing[0].ecid
        let invocation = Self.command(tool: tool, isRoot: geteuid() == 0)
        let result = try runner.runInteractive(invocation.executable, arguments: invocation.arguments)
        guard result.status == 0 else {
            if invocation.executable.path == "/usr/bin/sudo" {
                let detail = result.combinedOutput.isEmpty ? "sudo exited with status \(result.status). Authentication may have failed or been cancelled." : result.combinedOutput
                throw DFUError.privilegeRequired(detail)
            }
            throw DFUError.commandFailed(command: "macvdmtool dfu", status: result.status, output: result.combinedOutput)
        }

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try discovery.devices().contains(where: { device in
                guard device.state == .dfu else { return false }
                guard let expectedECID, let observedECID = device.ecid else { return true }
                return expectedECID.caseInsensitiveCompare(observedECID) == .orderedSame
            }) { return }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        throw DFUError.transitionTimedOut
    }

    public static func command(tool: URL, isRoot: Bool) -> (executable: URL, arguments: [String]) {
        isRoot ? (tool, ["dfu"]) : (URL(fileURLWithPath: "/usr/bin/sudo"), [tool.path, "dfu"])
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
