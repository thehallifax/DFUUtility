import DFUCore
import Foundation

public struct DemoIPSWService: IPSWService {
    public let releases: [IPSWRelease]
    public init() { releases = [IPSWRelease(version: "26.6.2", build: "25G83-DEMO", downloadURL: URL(string: "https://updates.cdn-apple.com/demo.ipsw")!, fileSize: 19_772_231_540, supportedDevices: ["DemoMac"])] }
    public func availableImages(for device: DFUDevice?) async throws -> [IPSWRelease] { releases }
    public func recommendedImage(for device: DFUDevice?) async throws -> IPSWRelease { releases[0] }
    public func download(_ release: IPSWRelease, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL { throw CancellationError() }
    public func downloadEvents(_ release: IPSWRelease) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.started(release: release))
                do {
                    for step in 1...20 { try await Task.sleep(for: .milliseconds(120)); try Task.checkCancellation(); continuation.yield(.progress(completed: Int64(step) * (release.fileSize ?? 20) / 20, total: release.fileSize, bytesPerSecond: 41_000_000)) }
                    continuation.yield(.validating); try await Task.sleep(for: .milliseconds(300)); continuation.yield(.cancelled); continuation.finish()
                } catch { continuation.yield(.cancelled); continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct DemoDiscovery: DeviceDiscovering { public init() {}; public func devices() throws -> [DFUDevice] { [] } }
public struct DemoDiagnostics: DiagnosticsProviding {
    public init() {}
    public func report() throws -> DoctorReport { DoctorReport(status: UtilityStatus(host: HostStatus(isAppleSilicon: true, macOSVersion: "Demo", macVDMToolPath: nil, cfgutilPath: nil), targets: []), configuratorPresent: false, cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("DFUUtility-Demo"), cacheWritable: true, restoreSupported: false) }
}
public struct DemoRestoreEngine: RestoreOperating { public init() {}; public func events(for action: RestoreAction) -> AsyncThrowingStream<RestoreEvent, Error> { AsyncThrowingStream { $0.finish() } } }
public struct DemoDFUController: DFUOperating { public init() {}; public func enterDFU(timeout: TimeInterval) throws { throw DFUError.toolUnavailable("Demo mode never invokes macvdmtool") } }
