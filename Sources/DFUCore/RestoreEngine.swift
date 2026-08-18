import Foundation

public enum RestoreAction: Sendable { case restore(URL), revive, reboot }

public enum RestoreEvent: Sendable { case preparing, waitingForDevice, started, progress(Double?), message(String), completed }

public struct RestoreEngine: Sendable {
    private let discovery: any DeviceDiscovering
    private let runner: any CommandRunning
    private let cfgutil: URL?

    public init(discovery: any DeviceDiscovering = ConfiguratorDeviceDiscovery(), runner: any CommandRunning = ProcessRunner(), cfgutil: URL? = ToolLocator.executable(named: "cfgutil")) {
        self.discovery = discovery
        self.runner = runner
        self.cfgutil = cfgutil
    }

    public func validateIPSW(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw DFUError.invalidIPSW("file does not exist")
        }
        guard url.pathExtension.lowercased() == "ipsw" else { throw DFUError.invalidIPSW("expected a .ipsw file") }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 1_000_000 else {
            throw DFUError.invalidIPSW("file is implausibly small")
        }
        let listing = try runner.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z1", url.path])
        guard listing.status == 0 else { throw DFUError.invalidIPSW("ZIP directory is unreadable: \(listing.stderrString)") }
        let entries = listing.stdoutString
        guard entries.contains("BuildManifest.plist"), entries.contains("Restore.plist") else {
            throw DFUError.invalidIPSW("missing BuildManifest.plist or Restore.plist")
        }
    }

    public func perform(_ action: RestoreAction) throws {
        guard let cfgutil else { throw DFUError.toolUnavailable("cfgutil (install Apple Configurator Automation Tools)") }
        if case .restore(let url) = action { try validateIPSW(url) }
        let devices = try discovery.devices()
        guard !devices.isEmpty else { throw DFUError.noTarget }
        guard devices.count == 1 else { throw DFUError.multipleTargets(devices.count) }
        let stateAllowed: Bool
        switch action {
        case .restore: stateAllowed = devices[0].state == .dfu
        case .revive: stateAllowed = devices[0].state == .dfu || devices[0].state == .recovery
        case .reboot: stateAllowed = true
        }
        guard stateAllowed else { throw DFUError.targetNotInDFU }

        var arguments = ["--progress", "--verbose", "--timeout", "30"]
        if let ecid = devices[0].ecid, !ecid.isEmpty { arguments += ["--ecid", ecid] }
        switch action {
        case .restore(let url):
            arguments += ["restore", "--ipsw", url.path]
        case .revive: arguments += ["revive"]
        case .reboot: arguments += ["restart"]
        }
        let result = try runner.runStreaming(cfgutil, arguments: arguments)
        guard result.status == 0 else {
            throw DFUError.commandFailed(command: "cfgutil \(arguments.joined(separator: " "))", status: result.status, output: result.combinedOutput)
        }
    }

    public func events(for action: RestoreAction) -> AsyncThrowingStream<RestoreEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                continuation.yield(.preparing)
                do {
                    try Task.checkCancellation(); continuation.yield(.waitingForDevice)
                    try Task.checkCancellation(); continuation.yield(.started)
                    try perform(action); continuation.yield(.completed); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
