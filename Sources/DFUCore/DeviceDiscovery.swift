import Foundation

public protocol DeviceDiscovering: Sendable {
    func devices() throws -> [DFUDevice]
}

public struct ConfiguratorDeviceDiscovery: DeviceDiscovering {
    private let runner: any CommandRunning
    private let cfgutil: URL?

    public init(runner: any CommandRunning = ProcessRunner(), cfgutil: URL? = ToolLocator.executable(named: "cfgutil")) {
        self.runner = runner
        self.cfgutil = cfgutil
    }

    public func devices() throws -> [DFUDevice] {
        guard let cfgutil else { return try usbFallback() }
        let list = try runner.run(cfgutil, arguments: ["--format", "JSON", "--timeout", "1", "list"])
        guard list.status == 0 else {
            throw DFUError.commandFailed(command: "cfgutil list", status: list.status, output: list.combinedOutput)
        }
        guard let object = try? JSONSerialization.jsonObject(with: list.stdout) as? [String: Any],
              let rawDevices = object["Devices"] as? [Any], !rawDevices.isEmpty else {
            return try usbFallback()
        }

        var result: [DFUDevice] = []
        for raw in rawDevices {
            let selector: String
            if let scalar = raw as? String {
                selector = scalar
            } else if let dictionary = raw as? [String: Any], let ecid = dictionary["ECID"] ?? dictionary["ecid"] {
                selector = String(describing: ecid)
            } else {
                continue
            }
            var args = ["--format", "JSON", "--timeout", "1"]
            if !selector.isEmpty { args += ["--ecid", selector] }
            args += ["get", "ECID", "deviceType", "deviceClass", "bootedState", "isRestorable", "UDID", "serialNumber"]
            let details = try runner.run(cfgutil, arguments: args)
            let values = Self.flattenJSON(details.stdout)
            let state = Self.state(from: values)
            result.append(DFUDevice(
                state: state,
                model: Self.first(values, keys: ["deviceType", "DeviceType"]),
                identifier: Self.first(values, keys: ["UDID", "serialNumber"]),
                ecid: Self.first(values, keys: ["ECID"]) ?? selector
            ))
        }
        return result
    }

    private func usbFallback() throws -> [DFUDevice] {
        let ioreg = URL(fileURLWithPath: "/usr/sbin/ioreg")
        let output = try runner.run(ioreg, arguments: ["-p", "IOUSB", "-l", "-w", "0"])
        let text = output.stdoutString
        let blocks = text.components(separatedBy: "+-o ")
        return blocks.compactMap { block in
            guard block.localizedCaseInsensitiveContains("Apple") else { return nil }
            let isDFU = block.localizedCaseInsensitiveContains("DFU Mode") || block.contains("0x1227")
            let isRecovery = block.localizedCaseInsensitiveContains("Recovery Mode") || block.contains("0x1281")
            guard isDFU || isRecovery else { return nil }
            let name = block.split(separator: " ", maxSplits: 1).first.map(String.init)
            return DFUDevice(state: isDFU ? .dfu : .recovery, model: name)
        }
    }

    private static func flattenJSON(_ data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        var values: [String: String] = [:]
        func visit(_ value: Any, key: String?) {
            if let dictionary = value as? [String: Any] {
                for (childKey, child) in dictionary { visit(child, key: childKey) }
            } else if let array = value as? [Any] {
                for child in array { visit(child, key: key) }
            } else if let key {
                values[key] = String(describing: value)
            }
        }
        visit(root, key: nil)
        return values
    }

    private static func first(_ values: [String: String], keys: [String]) -> String? {
        keys.lazy.compactMap { values[$0] }.first
    }

    private static func state(from values: [String: String]) -> DeviceState {
        let joined = values.values.joined(separator: " ").lowercased()
        if joined.contains("dfu") { return .dfu }
        if joined.contains("recovery") || joined.contains("restore") { return .recovery }
        if joined.contains("booted") || joined.contains("normal") { return .normal }
        return .unknown
    }
}

public struct StatusService: Sendable {
    private let discovery: any DeviceDiscovering
    public init(discovery: any DeviceDiscovering = ConfiguratorDeviceDiscovery()) { self.discovery = discovery }

    public func status() throws -> UtilityStatus {
        var size = 0
        sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
        var arm64 = Int32(0)
        size = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0)
        let macVDMTool = ToolLocator.macVDMTool()
        return UtilityStatus(host: HostStatus(
            isAppleSilicon: arm64 == 1,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            macVDMToolPath: macVDMTool?.url,
            cfgutilPath: ToolLocator.executable(named: "cfgutil"),
            macVDMToolSource: macVDMTool?.source
        ), targets: try discovery.devices())
    }
}
