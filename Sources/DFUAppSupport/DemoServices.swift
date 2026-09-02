import DFUCore
import Foundation

public enum DemoFirmwareLibrary {
    private static func url(_ name: String) -> URL { URL(string: "https://firmware.demo.invalid/\(name).ipsw")! }
    private static func cacheURL(_ platform: RestorePlatform, _ build: String) -> URL {
        URL(fileURLWithPath: "/demo/cache/\(platform.rawValue)/\(build)/Restore.ipsw")
    }

    public static let catalogueReleases: [IPSWRelease] = [
        IPSWRelease(platform: .macOS, version: "26.6.2", build: "25G83-DEMO", downloadURL: url("macos-26.6.2"), fileSize: 19_772_231_540, supportedDevices: ["Mac14,2"]),
        IPSWRelease(platform: .iOS, version: "26.6.1", build: "23G83-DEMO", downloadURL: url("ios-26.6.1"), fileSize: 8_420_000_000, supportedDevices: ["iPhone15,2"]),
        IPSWRelease(platform: .iOS, version: "18.7.10", build: "22H374-DEMO", downloadURL: url("ios-18.7.10"), fileSize: 7_860_000_000, supportedDevices: ["iPhone15,2"]),
        IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G84-DEMO", downloadURL: url("ipados-26.6.1"), fileSize: 9_180_000_000, supportedDevices: ["iPad13,18"])
    ]

    public static let cachedEntries: [ManagedIPSWEntry] = {
        let releases = [
            IPSWRelease(platform: .macOS, version: "26.5", build: "25F74-DEMO", downloadURL: url("macos-26.5"), fileSize: 18_940_000_000, supportedDevices: ["Mac14,2"]),
            catalogueReleases.first { $0.platform == .iOS && $0.build == "22H374-DEMO" }!,
            IPSWRelease(platform: .iOS, version: "16.7.16", build: "20H392-DEMO", downloadURL: url("ios-16.7.16"), fileSize: 6_040_000_000, supportedDevices: ["iPhone15,2"]),
            IPSWRelease(platform: .iOS, version: "12.5.8", build: "16H88-DEMO", downloadURL: url("ios-12.5.8"), fileSize: 4_320_000_000, supportedDevices: ["iPhone15,2"]),
            IPSWRelease(platform: .iPadOS, version: "18.7.10", build: "22H374-IPAD-DEMO", downloadURL: url("ipados-18.7.10"), fileSize: 7_920_000_000, supportedDevices: ["iPad13,18"])
        ]
        return releases.map { release in
            ManagedIPSWEntry(release: release, state: .completeValidated, sizeBytes: release.fileSize ?? 0,
                url: cacheURL(release.platform, release.build))
        }
    }()
}

public struct DemoIPSWService: IPSWService {
    public let releases: [IPSWRelease]
    public init() { releases = DemoFirmwareLibrary.catalogueReleases }
    public func availableImages(for device: DFUDevice?) async throws -> [IPSWRelease] {
        let platformFiltered = device.map { device in releases.filter { $0.platform == device.family.restorePlatform } } ?? releases
        let compatible = device?.restoreProductType.map { product in
            platformFiltered.filter { $0.supportedDevices.contains(product) }
        } ?? platformFiltered
        return AppleIPSWService.sortNewestFirst(compatible)
    }
    public func recommendedImage(for device: DFUDevice?) async throws -> IPSWRelease {
        guard let release = try await availableImages(for: device).first else { throw IPSWServiceError.noReleases }
        return release
    }
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
