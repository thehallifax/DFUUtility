import Foundation

public struct DoctorReport: Sendable {
    public let status: UtilityStatus; public let configuratorPresent: Bool; public let cacheDirectory: URL; public let cacheWritable: Bool; public let restoreSupported: Bool
    public var isFundamentallyUsable: Bool { status.host.isAppleSilicon && status.host.cfgutilPath != nil && configuratorPresent && cacheWritable && restoreSupported }
    public var setupComplete: Bool { isFundamentallyUsable && status.host.macVDMToolPath != nil }
    public init(status: UtilityStatus, configuratorPresent: Bool, cacheDirectory: URL, cacheWritable: Bool, restoreSupported: Bool) {
        self.status = status; self.configuratorPresent = configuratorPresent; self.cacheDirectory = cacheDirectory; self.cacheWritable = cacheWritable; self.restoreSupported = restoreSupported
    }
}
public struct DoctorService: Sendable {
    private let statusService: StatusService; private let cache: IPSWCache; private let runner: any CommandRunning
    public init(statusService: StatusService = StatusService(), cache: IPSWCache = IPSWCache(), runner: any CommandRunning = ProcessRunner()) { self.statusService = statusService; self.cache = cache; self.runner = runner }
    public func report() throws -> DoctorReport {
        let status = try statusService.status(); let app = FileManager.default.fileExists(atPath: "/Applications/Apple Configurator.app")
        var writable = false; do { try cache.prepare(); let probe = cache.directory.appendingPathComponent(".write-probe-\(UUID().uuidString)"); try Data().write(to: probe); try FileManager.default.removeItem(at: probe); writable = true } catch {}
        var restore = false
        if let cfgutil = status.host.cfgutilPath { let help = try? runner.run(cfgutil, arguments: ["help", "restore"]); restore = help?.status == 0 && help?.combinedOutput.contains("--ipsw") == true }
        return DoctorReport(status: status, configuratorPresent: app, cacheDirectory: cache.directory, cacheWritable: writable, restoreSupported: restore)
    }
}
