import Combine
import DFUCore
import Foundation

public enum CatalogueState: Equatable { case idle, loading, loaded, failed(String) }
public enum ImageState: Equatable { case none, partial(Int64), validating, ready(URL), invalid(String) }
public enum AppDownloadState: Equatable { case idle, downloading(completed: Int64, total: Int64?, bytesPerSecond: Double?), validating, cancelled, failed(String) }
public enum AppRestoreState: Equatable { case idle, running(String), completed, failed(String) }

public protocol DiagnosticsProviding: Sendable { func report() throws -> DoctorReport }
extension DoctorService: DiagnosticsProviding {}
public protocol RestoreOperating: Sendable { func events(for action: RestoreAction) -> AsyncThrowingStream<RestoreEvent, Error> }
extension RestoreEngine: RestoreOperating {}
public protocol DFUOperating: Sendable { func enterDFU(timeout: TimeInterval) throws }
extension DFUController: DFUOperating {}

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var catalogueState: CatalogueState = .idle
    @Published public private(set) var availableReleases: [IPSWRelease] = []
    @Published public var selectedRelease: IPSWRelease?
    @Published public private(set) var targetDevices: [DFUDevice] = []
    @Published public private(set) var imageState: ImageState = .none
    @Published public private(set) var downloadState: AppDownloadState = .idle
    @Published public private(set) var restoreState: AppRestoreState = .idle
    @Published public private(set) var doctorReport: DoctorReport?
    @Published public var presentedError: String?

    public let isDemoMode: Bool
    private let ipswService: any IPSWService
    private let discovery: any DeviceDiscovering
    private let cache: IPSWCache
    private let validator: any IPSWValidating
    private let diagnostics: any DiagnosticsProviding
    private let restoreEngine: any RestoreOperating
    private let dfuController: any DFUOperating
    private var downloadTask: Task<Void, Never>?

    public init(ipswService: any IPSWService = AppleIPSWService(), discovery: any DeviceDiscovering = ConfiguratorDeviceDiscovery(), cache: IPSWCache = IPSWCache(), validator: any IPSWValidating = IPSWValidator(), diagnostics: any DiagnosticsProviding = DoctorService(), restoreEngine: any RestoreOperating = RestoreEngine(), dfuController: any DFUOperating = DFUController(), isDemoMode: Bool = false) {
        self.ipswService = ipswService; self.discovery = discovery; self.cache = cache; self.validator = validator
        self.diagnostics = diagnostics; self.restoreEngine = restoreEngine; self.dfuController = dfuController; self.isDemoMode = isDemoMode
    }

    public var target: DFUDevice? { targetDevices.count == 1 ? targetDevices[0] : nil }
    public var imageURL: URL? { if case .ready(let url) = imageState { return url }; return nil }
    public var canEnterDFU: Bool { !isDemoMode && doctorReport?.status.host.macVDMToolPath != nil && restoreState == .idle }
    public var canRestore: Bool { !isDemoMode && target?.state == .dfu && imageURL != nil && restoreState == .idle }
    public var canRevive: Bool { !isDemoMode && (target?.state == .dfu || target?.state == .recovery) && restoreState == .idle }

    public func load() async {
        await refreshDiagnosticsAndTarget()
        catalogueState = .loading
        do {
            availableReleases = try await ipswService.availableImages(for: nil)
            selectedRelease = availableReleases.first; catalogueState = .loaded; refreshSelectedCacheState()
        } catch { catalogueState = .failed(error.localizedDescription); presentedError = "Apple firmware catalogue could not be reached.\n\(error.localizedDescription)" }
    }

    public func refreshDiagnosticsAndTarget() async {
        do { doctorReport = try diagnostics.report() } catch { presentedError = error.localizedDescription }
        do { targetDevices = try discovery.devices() } catch { presentedError = "Target discovery failed.\n\(error.localizedDescription)" }
    }

    public func selectRelease(_ release: IPSWRelease) { selectedRelease = release; refreshSelectedCacheState() }

    public func refreshSelectedCacheState() {
        guard let release = selectedRelease else { imageState = .none; return }
        if let url = try? cache.validCachedURL(for: release, validator: validator) { imageState = .ready(url); return }
        let partial = cache.partialURL(for: release)
        let size = ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size]) as? NSNumber)?.int64Value ?? 0
        imageState = size > 0 ? .partial(size) : .none
    }

    public func beginDownload() {
        guard downloadTask == nil else { return }
        downloadTask = Task { [weak self] in await self?.downloadSelected(); self?.downloadTask = nil }
    }

    public func downloadSelected() async {
        guard let release = selectedRelease else { return }
        do {
            for try await event in ipswService.downloadEvents(release) {
                switch event {
                case .started: downloadState = .downloading(completed: 0, total: release.fileSize, bytesPerSecond: nil)
                case .resumed(let bytes): imageState = .partial(bytes); downloadState = .downloading(completed: bytes, total: release.fileSize, bytesPerSecond: nil)
                case .progress(let completed, let total, let speed): downloadState = .downloading(completed: completed, total: total, bytesPerSecond: speed)
                case .validating: downloadState = .validating; imageState = .validating
                case .completed(let url): downloadState = .idle; imageState = .ready(url)
                case .cancelled: downloadState = .cancelled; refreshSelectedCacheState()
                }
            }
        } catch is CancellationError { downloadState = .cancelled; refreshSelectedCacheState() }
        catch { downloadState = .failed(error.localizedDescription); presentedError = "Image download failed.\n\(error.localizedDescription)"; refreshSelectedCacheState() }
    }

    public func cancelDownload() {
        guard downloadTask != nil else { return }
        downloadTask?.cancel(); downloadTask = nil; downloadState = .cancelled; refreshSelectedCacheState()
    }

    public func validateManualIPSW(_ url: URL) async {
        imageState = .validating
        do {
            let validator = validator
            try await Task.detached { try validator.validate(url, release: nil, verifyChecksum: false) }.value
            selectedRelease = nil; imageState = .ready(url)
        } catch { imageState = .invalid(error.localizedDescription); presentedError = "The selected IPSW is incomplete or invalid.\n\(error.localizedDescription)" }
    }

    public func enterDFU() async {
        guard canEnterDFU else { presentedError = "macvdmtool is not installed or DFU is unavailable."; return }
        restoreState = .running("Requesting DFU…")
        do { let controller = dfuController; try await Task.detached { try controller.enterDFU(timeout: 30) }.value; restoreState = .idle; await refreshDiagnosticsAndTarget() }
        catch { restoreState = .failed(error.localizedDescription); presentedError = error.localizedDescription }
    }

    public func restoreConfirmed() { guard canRestore, let url = imageURL else { presentedError = "Restore requires a valid IPSW and a real DFU target."; return }; runRestore(.restore(url)) }
    public func revive() { guard canRevive else { presentedError = "No supported real target is connected for revive."; return }; runRestore(.revive) }
    private func runRestore(_ action: RestoreAction) {
        Task {
            do {
                for try await event in restoreEngine.events(for: action) {
                    switch event {
                    case .preparing: restoreState = .running("Preparing…")
                    case .waitingForDevice: restoreState = .running("Waiting for target…")
                    case .started: restoreState = .running("Operation started…")
                    case .progress(let value): restoreState = .running(value.map { "\(Int($0 * 100))%" } ?? "Working…")
                    case .message(let text): restoreState = .running(text)
                    case .completed: restoreState = .completed
                    }
                }
            } catch { restoreState = .failed(error.localizedDescription); presentedError = "Restore failed.\n\(error.localizedDescription)" }
        }
    }

    public func setDemoTarget(_ state: DeviceState?) { guard isDemoMode else { return }; targetDevices = state.map { [DFUDevice(state: $0, model: "DemoMac", ecid: "DEMO-ECID")] } ?? [] }
    public func setDemoRestoreFailure() { guard isDemoMode else { return }; restoreState = .failed("Demonstration failure — no command was run.") }
}
