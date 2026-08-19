import Combine
import DFUCore
import Foundation

public enum CatalogueState: Equatable { case idle, loading, loaded, failed(String) }
public enum ImageState: Equatable { case none, partial(Int64), validating, ready(URL), invalid(String) }
public enum AppDownloadState: Equatable { case idle, downloading(completed: Int64, total: Int64?, bytesPerSecond: Double?), validating, cancelled, failed(String) }
public enum AppRestoreState: Equatable {
    case idle
    case running(operation: String, stage: String, fraction: Double?)
    case reconnecting(operation: String)
    case completed(String)
    case failed(String)
}
public enum TargetWorkflowState: String, Equatable, Sendable { case noTarget = "No target", normal = "Normal", transitioning = "Transitioning to DFU", dfu = "DFU", recovery = "Recovery", restoring = "Restoring", reviving = "Reviving", reconnecting = "Reconnecting", completed = "Completed", failed = "Failed" }

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
    @Published public private(set) var lastLogURL: URL?
    @Published public private(set) var privilegedHelperState: PrivilegedHelperState = .notRegistered
    @Published public private(set) var helperRegistrationErrorDetails: String?

    public let isDemoMode: Bool
    public let privilegeMode: PrivilegeMode
    private let ipswService: any IPSWService
    private let discovery: any DeviceDiscovering
    private let cache: IPSWCache
    private let validator: any IPSWValidating
    private let diagnostics: any DiagnosticsProviding
    private let restoreEngine: any RestoreOperating
    private let dfuController: any DFUOperating
    private let operationLogger: any OperationLogging
    private let requiresPrivilegedHelperSetup: Bool
    private var downloadTask: Task<Void, Never>?

    public init(ipswService: any IPSWService = AppleIPSWService(), discovery: any DeviceDiscovering = ConfiguratorDeviceDiscovery(), cache: IPSWCache = IPSWCache(), validator: any IPSWValidating = IPSWValidator(), diagnostics: any DiagnosticsProviding = DoctorService(), restoreEngine: any RestoreOperating = RestoreEngine(), dfuController: (any DFUOperating)? = nil, operationLogger: any OperationLogging = OperationLogger(), requiresPrivilegedHelperSetup: Bool = true, privilegeMode: PrivilegeMode? = nil, isDemoMode: Bool = false) {
        let resolvedMode = privilegeMode ?? (requiresPrivilegedHelperSetup ? PrivilegeModeSelector.select() : .community)
        self.ipswService = ipswService; self.discovery = discovery; self.cache = cache; self.validator = validator
        self.diagnostics = diagnostics; self.restoreEngine = restoreEngine
        self.dfuController = dfuController ?? PrivilegedDFUOperator(discovery: discovery, client: resolvedMode == .signedHelper ? PrivilegedDFUClient() : CommunityDFURequest())
        self.operationLogger = operationLogger; self.requiresPrivilegedHelperSetup = resolvedMode == .signedHelper; self.privilegeMode = resolvedMode; self.isDemoMode = isDemoMode
    }

    public var target: DFUDevice? { targetDevices.count == 1 ? targetDevices[0] : nil }
    public var targetWorkflowState: TargetWorkflowState {
        switch restoreState {
        case .running(let operation, _, _): if operation == "Enter DFU" { return .transitioning }; return operation == "Restore" ? .restoring : .reviving
        case .reconnecting: return .reconnecting
        case .completed: return .completed
        case .failed: return .failed
        case .idle: break
        }
        switch target?.state {
        case .normal: return .normal
        case .dfu: return .dfu
        case .recovery: return .recovery
        case .none, .unknown: return .noTarget
        }
    }
    public var imageURL: URL? { if case .ready(let url) = imageState { return url }; return nil }
    public var canEnterDFU: Bool { !isDemoMode && target?.state == .normal && !hasSyntheticProductionIdentity && doctorReport?.status.host.macVDMToolPath != nil && (!requiresPrivilegedHelperSetup || privilegedHelperState.isReady) && restoreState == .idle }
    private var hasSyntheticProductionIdentity: Bool {
        guard !isDemoMode, let value = target?.ecid?.uppercased() else { return false }
        return value == "TEST" || value.hasPrefix("DEMO") || value.hasPrefix("TEST-")
    }
    public var canRestore: Bool { !isDemoMode && target?.state == .dfu && imageURL != nil && restoreState == .idle }
    public var canRevive: Bool { !isDemoMode && (target?.state == .dfu || target?.state == .recovery) && restoreState == .idle }

    public func load() async {
        await refreshDiagnosticsAndTarget()
        catalogueState = .loading
        do {
            availableReleases = try await ipswService.availableImages(for: target)
            selectedRelease = availableReleases.first; catalogueState = .loaded; refreshSelectedCacheState()
        } catch { catalogueState = .failed(error.localizedDescription); presentedError = "Apple firmware catalogue could not be reached.\n\(error.localizedDescription)" }
    }

    public func refreshDiagnosticsAndTarget() async {
        if privilegeMode == .signedHelper { privilegedHelperState = await Task.detached { PrivilegedDFUClient().state() }.value }
        do { doctorReport = try diagnostics.report() } catch { presentedError = error.localizedDescription }
        do { targetDevices = try discovery.devices() } catch { presentedError = "Target discovery failed.\n\(error.localizedDescription)" }
    }

    public func setUpPrivilegedHelper() async {
        privilegedHelperState = .registrationRequested
        helperRegistrationErrorDetails = nil
        do {
            privilegedHelperState = try await Task.detached { try PrivilegedDFUClient().setUp() }.value
        } catch {
            if case .registrationFailed(let details) = error as? PrivilegedDFUClientError {
                helperRegistrationErrorDetails = details
                presentedError = "DFU helper setup failed.\n\(details)"
            } else {
                helperRegistrationErrorDetails = NSErrorDiagnostics.describe(error)
                presentedError = "DFU helper setup failed.\n\(error.localizedDescription)"
            }
            privilegedHelperState = .failed("Registration failed")
        }
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
        guard !hasSyntheticProductionIdentity else { presentedError = "A synthetic test target identity was rejected in production mode."; return }
        guard canEnterDFU else { presentedError = "macvdmtool is not installed or DFU is unavailable."; return }
        let log = try? operationLogger.start(operation: "Enter DFU", target: target, release: nil)
        lastLogURL = log
        restoreState = .running(operation: "Enter DFU", stage: "Requesting administrator authorization…", fraction: nil)
        do {
            if let log { try? operationLogger.append("Privilege mode: \(privilegeMode.displayName)\nAuthorization requested via \(privilegeMode == .community ? "macOS system administrator prompt" : "signed helper")", to: log) }
            let controller = dfuController; try await Task.detached { try controller.enterDFU(timeout: 30) }.value
            if let log { try? operationLogger.append("Transition result: success\nFinal verified state: DFU, same ECID", to: log) }
            restoreState = .idle; await refreshDiagnosticsAndTarget()
        } catch {
            if let log { try? operationLogger.append("FAILED: \(error.localizedDescription)", to: log) }
            restoreState = .failed(error.localizedDescription); presentedError = error.localizedDescription
        }
    }

    public func restoreConfirmed() { guard canRestore, let url = imageURL else { presentedError = "Restore requires a valid IPSW and a real DFU target."; return }; runRestore(.restore(url)) }
    public func revive() { guard canRevive else { presentedError = "No supported real target is connected for revive."; return }; runRestore(.revive) }
    private func runRestore(_ action: RestoreAction) {
        Task {
            let log = try? operationLogger.start(operation: action.operationName, target: target, release: selectedRelease)
            lastLogURL = log
            do {
                for try await event in restoreEngine.events(for: action) {
                    if let log { try? operationLogger.append(String(describing: event), to: log) }
                    switch event {
                    case .preparing: restoreState = .running(operation: action.operationName, stage: "Preparing…", fraction: nil)
                    case .waitingForDevice: restoreState = .running(operation: action.operationName, stage: "Waiting for the device", fraction: nil)
                    case .stageStarted(let name, _, _): restoreState = .running(operation: action.operationName, stage: name, fraction: nil)
                    case .progress(let stage, let fraction): restoreState = .running(operation: action.operationName, stage: stage, fraction: fraction)
                    case .stageCompleted(let name): restoreState = .running(operation: action.operationName, stage: name, fraction: 1)
                    case .message(let text): restoreState = .running(operation: action.operationName, stage: text, fraction: nil)
                    case .reconnecting: restoreState = .reconnecting(operation: action.operationName)
                    case .completed:
                        restoreState = .reconnecting(operation: action.operationName)
                        await verifyReconnect(operation: action.operationName)
                    case .failed(let message): restoreState = .failed(message)
                    }
                }
            } catch { if let log { try? operationLogger.append("FAILED: \(error.localizedDescription)", to: log) }; restoreState = .failed(error.localizedDescription); presentedError = "Restore failed.\n\(error.localizedDescription)" }
        }
    }

    private func verifyReconnect(operation: String) async {
        switch await ReconnectVerifier(discovery: discovery).wait() {
        case .restarted(let device):
            targetDevices = [device]
            restoreState = .completed("\(operation) completed successfully. Target restarted.")
        case .unverified:
            restoreState = .completed("\(operation) completed successfully. Target restart could not be verified.")
        }
    }

    public func setDemoTarget(_ state: DeviceState?) { guard isDemoMode else { return }; targetDevices = state.map { [DFUDevice(state: $0, model: "DemoMac", ecid: "DEMO-ECID")] } ?? [] }
    public func setDemoRestoreFailure() { guard isDemoMode else { return }; restoreState = .failed("Demonstration failure — no command was run.") }
}
