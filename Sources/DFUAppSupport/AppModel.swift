import Combine
import DFUCore
import Foundation

public enum CatalogueState: Equatable { case idle, loading, loaded, failed(String) }
public enum ImageState: Equatable { case none, partial(Int64), validating, ready(URL), invalid(String) }
public enum AppDownloadState: Equatable { case idle, downloading(completed: Int64, total: Int64?, bytesPerSecond: Double?), validating, cancelled, failed(String) }
public enum AppRestoreState: Equatable {
    case idle
    case running(operation: String, stage: String, stageIndex: Int?, stageTotal: Int?, fraction: Double?)
    case reconnecting(operation: String)
    case completed(String)
    case failed(String)
}

private enum LatestCompatibleFirmwareResolution {
    case unavailable
    case ambiguous
    case resolved(release: IPSWRelease, cachedURL: URL?)
}

public struct DFUFailurePresentation: Equatable, Sendable {
    public let summary: String
    public let recoverySuggestion: String?
    public let diagnosticDetails: String
    public var userMessage: String { [summary, recoverySuggestion].compactMap { $0 }.joined(separator: "\n") }

    public init(error: Error) {
        diagnosticDetails = Self.diagnostics(for: error)
        switch error {
        case let failure as MacVDMToolFailure:
            summary = failure.errorDescription ?? "Couldn’t enter DFU mode."
            recoverySuggestion = failure.recoverySuggestion
        case CommunityDFUError.authorizationCancelled, PrivilegedDFUClientError.authorizationCancelled:
            summary = "Administrator authorization was cancelled."
            recoverySuggestion = "No changes were made to the target Mac. You can try Enter DFU again."
        case CommunityDFUError.authorizationFailed:
            summary = "Couldn’t authorize DFU mode. macOS did not grant administrator authorization."
            recoverySuggestion = "Try Enter DFU again and approve the standard macOS administrator prompt."
        case CommunityDFUError.authorizationRequestUnavailable:
            summary = "Couldn’t request administrator authorization for DFU mode."
            recoverySuggestion = "Quit and reopen DFUUtility, then try again."
        case DFUError.toolUnavailable:
            summary = "The bundled DFU component is unavailable."
            recoverySuggestion = "Rebuild or reinstall DFUUtility, then try again."
        case DFUError.noTarget:
            summary = "Couldn’t enter DFU mode because no target Mac was detected."
            recoverySuggestion = "Check the data cable and target connection, then click Refresh."
        default:
            summary = "Couldn’t enter DFU mode."
            recoverySuggestion = "Use View Log for technical details, then check the target and cable before trying again."
        }
    }

    private static func diagnostics(for error: Error) -> String {
        if let failure = error as? MacVDMToolFailure { return failure.diagnosticDescription }
        if case .authorizationFailed(let detail) = error as? CommunityDFUError { return "Authorization failed:\n\(detail)" }
        if case .authorizationRequestUnavailable(let detail) = error as? CommunityDFUError { return "Authorization request unavailable:\n\(detail)" }
        if case .commandFailed(let command, let status, let output) = error as? DFUError { return "Command: \(command)\nExit status: \(status)\nRaw output:\n\(output)" }
        return NSErrorDiagnostics.describe(error)
    }
}

public enum OperationProgressReducer {
    public static func reduce(_ current: AppRestoreState, event: RestoreEvent, operation: String) -> AppRestoreState {
        switch event {
        case .preparing:
            return .running(operation: operation, stage: "Preparing", stageIndex: nil, stageTotal: nil, fraction: nil)
        case .waitingForDevice:
            return .running(operation: operation, stage: "Waiting for the device", stageIndex: nil, stageTotal: nil, fraction: nil)
        case .stageStarted(let name, let index, let total):
            return .running(operation: operation, stage: normalizeStageName(name), stageIndex: index, stageTotal: total, fraction: nil)
        case .progress(let stage, let fraction):
            let name = normalizeStageName(stage)
            let metadata: (Int?, Int?)
            if case .running(_, let currentStage, let index, let total, _) = current, normalizeStageName(currentStage) == name { metadata = (index, total) }
            else { metadata = (nil, nil) }
            return .running(operation: operation, stage: name, stageIndex: metadata.0, stageTotal: metadata.1, fraction: fraction >= 0 ? min(max(fraction, 0), 1) : nil)
        case .stageCompleted(let name):
            let cleanName = normalizeStageName(name)
            let metadata: (Int?, Int?)
            if case .running(_, let currentStage, let index, let total, _) = current, normalizeStageName(currentStage) == cleanName { metadata = (index, total) }
            else { metadata = (nil, nil) }
            return .running(operation: operation, stage: cleanName, stageIndex: metadata.0, stageTotal: metadata.1, fraction: 1)
        case .message:
            return current // Raw cfgutil messages remain in the operation log.
        case .reconnecting, .completed:
            return .reconnecting(operation: operation)
        case .failed(let message):
            return .failed(message)
        }
    }

    public static func normalizeStageName(_ value: String) -> String {
        value.replacingOccurrences(of: #"^Step\s+\d+\s+of\s+\d+:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct OperationProgressPresentation: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case hidden, active, reconnecting, completed, failed }
    public let phase: Phase
    public let operation: String?
    public let title: String?
    public let stage: String?
    public let fraction: Double?
    public let message: String?

    public init(state: AppRestoreState, macOSVersion: String? = nil, platform: RestorePlatform = .macOS) {
        switch state {
        case .idle:
            phase = .hidden; operation = nil; title = nil; stage = nil; fraction = nil; message = nil
        case .running(let operationName, let stageName, let index, let total, let value):
            phase = .active; operation = operationName; title = Self.title(operation: operationName, version: macOSVersion, platform: platform)
            let clean = OperationProgressReducer.normalizeStageName(stageName)
            stage = if let index, let total { "\(clean) — Step \(index) of \(total)" } else { clean }
            fraction = value.flatMap { $0 >= 0 ? min(max($0, 0), 1) : nil }; message = nil
        case .reconnecting(let operationName):
            phase = .reconnecting; operation = operationName; title = "\(operationName) completed"; stage = "Waiting for Mac to restart…"; fraction = nil; message = nil
        case .completed(let value):
            phase = .completed; operation = nil; title = nil; stage = nil; fraction = nil; message = value
        case .failed(let value):
            phase = .failed; operation = nil; title = nil; stage = nil; fraction = nil; message = value
        }
    }

    private static func title(operation: String, version: String?, platform: RestorePlatform) -> String {
        switch operation {
        case "Restore": version.map { "Restoring \(platform.displayName) \($0)" } ?? "Restoring \(platform.displayName)"
        case "Revive": platform == .macOS ? "Reviving Mac" : "Reviving \(platform == .iOS ? "iPhone" : "iPad")"
        default: operation
        }
    }
}

public enum TargetPresentation {
    public static func disconnectWarning(for target: DFUDevice?) -> String {
        switch target?.family {
        case .mac: "Do not disconnect the target Mac."
        case .iPhone: "Do not disconnect the iPhone."
        case .iPad: "Do not disconnect the iPad."
        case .unknown, .none: "Do not disconnect the target device."
        }
    }

    public static func restartWaitingText(for target: DFUDevice?) -> String {
        switch target?.family {
        case .mac: "Waiting for Mac to restart…"
        case .iPhone: "Waiting for iPhone to restart…"
        case .iPad: "Waiting for iPad to restart…"
        case .unknown, .none: "Waiting for the target device to restart…"
        }
    }
}

public enum TargetDFUGuidance: Equatable, Sendable {
    case macAdministratorAuthorization
    case guidedPhysicalButtons
    case unsupportedMobileProduct
}
public enum TargetWorkflowState: String, Equatable, Sendable { case noTarget = "No target", normal = "Normal", transitioning = "Transitioning to DFU", dfu = "DFU", recovery = "Recovery", restoring = "Restoring", reviving = "Reviving", reconnecting = "Reconnecting", completed = "Completed", failed = "Failed" }

public protocol DiagnosticsProviding: Sendable {
    func report() throws -> DoctorReport
    func report(targets: [DFUDevice]) throws -> DoctorReport
}
public extension DiagnosticsProviding { func report(targets: [DFUDevice]) throws -> DoctorReport { try report() } }
extension DoctorService: DiagnosticsProviding {}
public protocol RestoreOperating: Sendable { func events(for action: RestoreAction) -> AsyncThrowingStream<RestoreEvent, Error> }
extension RestoreEngine: RestoreOperating {}
public protocol DFUOperating: Sendable { func enterDFU(timeout: TimeInterval) throws }
extension DFUController: DFUOperating {}

@MainActor
public final class AppModel: ObservableObject {
    public static let accessoryDFUGuidance = "If macOS asks to allow the target Mac to connect, choose Allow so DFUUtility can continue detecting the transition."
    public var macDFUInProgress: Bool {
        if case .running(let operation, _, _, _, _) = restoreState { return operation == "Enter DFU" }
        return false
    }
    // Internal timing seams keep hardware-free tests fast. Production uses a
    // monotonic 30-second deadline, including discovery time, with 1-second gaps.
    var dfuVerificationDuration: Duration = .seconds(30)
    var dfuVerificationInterval: Duration = .seconds(1)
    @Published public private(set) var catalogueState: CatalogueState = .idle
    @Published public private(set) var availableReleases: [IPSWRelease] = []
    @Published public var selectedRelease: IPSWRelease?
    @Published public private(set) var imageChoices: [IPSWChoice] = []
    @Published public private(set) var pendingRelease: IPSWRelease?
    @Published public private(set) var catalogueErrorMessage: String?
    @Published public private(set) var targetDevices: [DFUDevice] = []
    @Published public private(set) var imageState: ImageState = .none
    @Published public private(set) var downloadState: AppDownloadState = .idle
    @Published public private(set) var restoreState: AppRestoreState = .idle
    @Published public private(set) var doctorReport: DoctorReport?
    @Published public var presentedError: String?
    @Published public private(set) var lastLogURL: URL?
    @Published public private(set) var privilegedHelperState: PrivilegedHelperState = .notRegistered
    @Published public private(set) var helperRegistrationErrorDetails: String?
    @Published public private(set) var manualImageURL: URL?
    @Published public var selectedTargetECID: String?
    @Published public private(set) var mobileDFUAssistant: MobileDFUAssistantModel?
    @Published public private(set) var managedCacheEntries: [ManagedIPSWEntry] = []
    @Published public private(set) var browsePlatform: RestorePlatform = .macOS
    @Published public var isUpdatePresentationRequested = false

    public let isDemoMode: Bool
    public let isUpdateTestMode: Bool
    public let deviceSessions: DeviceSessionManager
    public let captureSession: DeviceCaptureSession
    public let batchCoordinator: BatchCoordinator
    public let updateCoordinator: UpdateCoordinator
    public var isScreenshotPresentation: Bool { screenshotScenario != nil }
    public var screenshotPresentationScenario: String? { screenshotScenario }
    public let privilegeMode: PrivilegeMode
    private let screenshotScenario: String?
    private let ipswService: any IPSWService
    private let discovery: any DeviceDiscovering
    private let cache: IPSWCache
    private let validator: any IPSWValidating
    private let diagnostics: any DiagnosticsProviding
    private let restoreEngine: any RestoreOperating
    private let dfuController: any DFUOperating
    private let operationLogger: any OperationLogging
    private let applicationTerminator: any ApplicationTerminationRequesting
    private let requiresPrivilegedHelperSetup: Bool
    private let targetDiscoveryAttempts: Int
    private let reconnectAttempts: Int
    private let reconnectInterval: Duration
    private var downloadTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var operationGeneration: UInt64 = 0
    private var batchFollowupTask: Task<Void, Never>?
    private var benchDiscoveryTask: Task<Void, Never>?
    private var discoveryRevision: UInt64 = 0
    public private(set) var benchDiscoveryPollCount: UInt64 = 0
    private var observations: Set<AnyCancellable> = []
    private var catalogueReleases: [IPSWRelease] = []
    private var validatedCacheEntries: [FirmwareReleaseKey: ManagedIPSWEntry] = [:]

    public init(ipswService: any IPSWService = AppleIPSWService(), discovery: any DeviceDiscovering = ConfiguratorDeviceDiscovery(), cache: IPSWCache = IPSWCache(), validator: any IPSWValidating = IPSWValidator(), diagnostics: any DiagnosticsProviding = DoctorService(), restoreEngine: any RestoreOperating = RestoreEngine(), dfuController: (any DFUOperating)? = nil, operationLogger: any OperationLogging = OperationLogger(), updateCoordinator: UpdateCoordinator? = nil, applicationTerminator: (any ApplicationTerminationRequesting)? = nil, requiresPrivilegedHelperSetup: Bool = true, privilegeMode: PrivilegeMode? = nil, isDemoMode: Bool = false, isUpdateTestMode: Bool = false, screenshotScenario: String? = nil, targetDiscoveryAttempts: Int = 1, reconnectAttempts: Int = 10, reconnectInterval: Duration = .seconds(2)) {
        let resolvedMode = privilegeMode ?? (requiresPrivilegedHelperSetup ? PrivilegeModeSelector.select() : .community)
        let sessionManager = DeviceSessionManager()
        self.deviceSessions = sessionManager
        self.captureSession = DeviceCaptureSession()
        self.batchCoordinator = BatchCoordinator(sessions: sessionManager, operatorService: DefaultBatchTargetOperator(restore: restoreEngine, discovery: discovery, reconnectAttempts: reconnectAttempts, reconnectInterval: reconnectInterval), logger: operationLogger)
        self.updateCoordinator = updateCoordinator ?? UpdateCoordinator()
        self.applicationTerminator = applicationTerminator ?? NoOpApplicationTerminator()
        self.ipswService = ipswService; self.discovery = discovery; self.cache = cache; self.validator = validator
        self.diagnostics = diagnostics; self.restoreEngine = restoreEngine
        self.dfuController = dfuController ?? PrivilegedDFUOperator(discovery: discovery, client: resolvedMode == .signedHelper ? PrivilegedDFUClient() : CommunityDFURequest())
        self.operationLogger = operationLogger; self.requiresPrivilegedHelperSetup = resolvedMode == .signedHelper; self.privilegeMode = resolvedMode; self.isDemoMode = isDemoMode; self.isUpdateTestMode = isUpdateTestMode; self.screenshotScenario = screenshotScenario; self.targetDiscoveryAttempts = max(1, targetDiscoveryAttempts); self.reconnectAttempts = max(1, reconnectAttempts); self.reconnectInterval = reconnectInterval
        sessionManager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        batchCoordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        captureSession.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        self.updateCoordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
    }

    public var target: DFUDevice? {
        if targetDevices.count == 1 { return targetDevices[0] }
        guard let selectedTargetECID else { return nil }
        return targetDevices.first { $0.ecid == selectedTargetECID }
    }
    public var targetWorkflowState: TargetWorkflowState {
        switch restoreState {
        case .running(let operation, _, _, _, _): if operation == "Enter DFU" { return .transitioning }; return operation == "Restore" ? .restoring : .reviving
        case .reconnecting: return .reconnecting
        case .completed: break
        case .failed: break
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
    public var selectedImageDisplaySize: Int64? {
        if let catalogueSize = selectedRelease?.fileSize { return catalogueSize }
        guard let imageURL else { return nil }
        return Self.fileSize(at: imageURL)
    }
    public var selectedImagePresentation: SelectedImagePresentation {
        if let release = selectedRelease {
            let state = choice(for: release)?.cacheState ?? {
                switch imageState {
                case .ready(let url): return .downloaded(url)
                case .partial(let bytes): return .partial(bytes)
                case .validating: return .validating
                case .invalid: return .invalid
                case .none: return .downloadRequired
                }
            }()
            return .managed(release: release, cacheState: state)
        }
        switch imageState {
        case .ready(let url): return .local(url: url, isValid: true, error: nil)
        case .invalid(let error): return manualImageURL.map { .local(url: $0, isValid: false, error: error) } ?? .unavailable
        default: return .unavailable
        }
    }
    public var downloadPresentation: ImageDownloadPresentation? {
        guard let release = selectedRelease, case .downloading(let completed, let total, let speed) = downloadState else { return nil }
        return .init(release: release, completed: completed, total: total, bytesPerSecond: speed)
    }
    public var downloadPresentationState: ImageDownloadPresentationState {
        switch downloadState {
        case .idle: return imageURL == nil ? .idle : .completed
        case .downloading(let completed, let total, let speed):
            guard let release = selectedRelease else { return .idle }
            let value = ImageDownloadPresentation(release: release, completed: completed, total: total ?? release.fileSize, bytesPerSecond: speed)
            return completed == 0 && speed == nil ? .preparing(value) : .downloading(value)
        case .validating: return .validating
        case .cancelled: return .cancelled
        case .failed(let message): return .failed(message)
        }
    }
    public var managedCacheTotalBytes: Int64 { managedCacheEntries.reduce(0) { $0 + $1.sizeBytes } }
    public var cfgutilSetupRequired: Bool {
        !isDemoMode && !isUpdateTestMode && doctorReport?.status.host.cfgutilPath == nil
    }
    public var shareableDiagnosticsText: String {
        ShareableDiagnostics.render(
            report: doctorReport,
            privilegeMode: privilegeMode,
            cacheEntries: managedCacheEntries,
            updateState: updateCoordinator.state,
            updateSourceHealth: updateCoordinator.shareableSourceHealth,
            operationState: restoreState,
            operationLogAvailable: lastLogURL != nil
        )
    }
    public var managedCacheDirectoryURL: URL { cache.directory }
    public func cacheRevealURL(for entry: ManagedIPSWEntry) -> URL { entry.url }
    public func prepareCacheDirectoryForReveal() -> URL? { do { try cache.prepare(); return cache.directory } catch { presentedError = "Unable to open the IPSW cache.\n\(error.localizedDescription)"; return nil } }
    public var operationInProgress: Bool {
        if case .preparing = updateCoordinator.state { return true }
        if batchCoordinator.isRunning { return true }
        if case .running = restoreState { return true }
        if case .reconnecting = restoreState { return true }
        return false
    }
    public var canStartUpdate: Bool {
        guard !isDemoMode, !isScreenshotPresentation else { return false }
        let downloading: Bool = if case .downloading = downloadState { true } else { false }
        let validating: Bool = if case .validating = downloadState { true } else if case .validating = imageState { true } else { false }
        return UpdateOperationSnapshot(restoreOrReconnect: operationInProgress, download: downloading, validation: validating, guidedDFU: mobileDFUAssistant?.isMonitoring == true, batch: batchCoordinator.isRunning).permitsUpdate
    }
    public var updateBlockedMessage: String { "Finish the current DFUUtility operation before updating." }
    private var updateLaunchInProgress: Bool { if case .preparing = updateCoordinator.state { true } else { false } }
    public var reconnectInProgress: Bool { if case .reconnecting = restoreState { true } else { false } }
    public var canEnterDFU: Bool { !isDemoMode && !isUpdateTestMode && targetDevices.count == 1 && target?.family == .mac && target?.state == .normal && !hasSyntheticProductionIdentity && doctorReport?.status.host.macVDMToolPath != nil && (!requiresPrivilegedHelperSetup || privilegedHelperState.isReady) && !operationInProgress }
    public var macDFUMultiTargetUnavailable: Bool { targetDevices.count > 1 && targetDevices.contains { $0.family == .mac && $0.state == .normal } }
    public var canUseMobileDFUAssistant: Bool {
        guard let target, target.family == .iPhone || target.family == .iPad, target.state == .normal || target.state == .recovery else { return false }
        return target.ecid?.isEmpty == false && MobileDFUInstructionProfile.profile(for: target) != nil && !operationInProgress
    }
    public var targetDFUGuidance: TargetDFUGuidance? {
        guard !isDemoMode, let target, target.state == .normal || target.state == .recovery else { return nil }
        if target.family == .mac {
            return target.state == .normal && privilegeMode == .community ? .macAdministratorAuthorization : nil
        }
        guard target.family == .iPhone || target.family == .iPad else { return nil }
        return MobileDFUInstructionProfile.profile(for: target) == nil ? .unsupportedMobileProduct : .guidedPhysicalButtons
    }
    public var isFirmwareLibraryMode: Bool { true }
    public var showsSessionPresentation: Bool { !deviceSessions.sessions.isEmpty }
    public var targetRestorePlatform: RestorePlatform { target?.family.restorePlatform ?? browsePlatform }
    public var restoreSectionTitle: String { "Firmware Library" }
    public var detailedSession: DeviceSession? {
        guard let target, let ecid = target.ecid else { return nil }
        return deviceSessions.sessions.first { $0.ecid?.caseInsensitiveCompare(ecid) == .orderedSame }
    }
    public var manageDownloadsAvailable: Bool { true }
    public var shouldShowMissingDFUHelperWarning: Bool {
        !isDemoMode && doctorReport?.status.host.macVDMToolPath == nil
    }
    private var hasSyntheticProductionIdentity: Bool {
        guard !isDemoMode, let value = target?.ecid?.uppercased() else { return false }
        return value == "TEST" || value.hasPrefix("DEMO") || value.hasPrefix("TEST-")
    }
    public var canRestore: Bool {
        guard !isDemoMode, !isUpdateTestMode, let session = detailedSession else { return false }
        return session.canRestore && !operationInProgress
    }
    public var restoreUnavailableMessage: String {
        guard let target else { return "Select a connected target device before restoring." }
        if (target.family == .iPhone || target.family == .iPad), !RestoreTargetStatePolicy.allowsRestore(target) {
            return "Restore requires the \(target.family.displayName) to be in Recovery or DFU mode."
        }
        if !RestoreTargetStatePolicy.allowsRestore(target) { return "Restore requires the Mac to be in DFU mode." }
        if operationInProgress { return "Wait for the current device operation to finish before restoring." }
        return detailedSession?.restoreEligibilityFailure ?? "Restore is unavailable for the selected target and chosen firmware."
    }
    public var presentedErrorTitle: String {
        guard let message = presentedError else { return "DFUUtility" }
        if message.hasPrefix("Restore failed") { return "Restore Failed" }
        if message.hasPrefix("Revive failed") { return "Revive Failed" }
        if message.hasPrefix("Image download failed") { return "Download Failed" }
        if message.hasPrefix("Unable to load Apple restore images") || message.hasPrefix("The selected IPSW") { return "Firmware Unavailable" }
        if message.localizedCaseInsensitiveContains("update") { return "Update Failed" }
        if message.localizedCaseInsensitiveContains("entering DFU") || message.hasPrefix("DFU helper") || message.localizedCaseInsensitiveContains("DFU is unavailable") { return "DFU Entry Failed" }
        return "DFUUtility"
    }
    public var canRevive: Bool {
        guard !isDemoMode, !isUpdateTestMode, let target, !operationInProgress else { return false }
        return target.family == .mac ? (target.state == .dfu || target.state == .recovery) : target.state == .recovery
    }
    public var canRestart: Bool {
        guard !isDemoMode, !isUpdateTestMode, let session = detailedSession, !operationInProgress else { return false }
        return session.restartEligibilityFailure == nil
    }
    public var restartUnavailableMessage: String { detailedSession?.restartEligibilityFailure ?? "Restart is unavailable for the selected device." }
    public func load() async {
        if isUpdateTestMode {
            targetDevices = []; selectedTargetECID = nil
            await updateCoordinator.check(manual: true)
            isUpdatePresentationRequested = true
            return
        }
        if let screenshotScenario { configureScreenshot(screenshotScenario); return }
        if isDemoMode { deviceSessions.configureDemo(); await refreshCatalogue(); return }
        await refreshDiagnosticsAndTarget()
        if catalogueState == .idle { await refreshCatalogue() }
        await refreshManagedCache()
        updateCoordinator.consumeResult()
        Task { await updateCoordinator.automaticCheckIfDue(disabled: isDemoMode || isScreenshotPresentation) }
    }

    /// Owns the single conservative bench-discovery loop. The SwiftUI scene
    /// runs this only while active; cancellation stops it without side effects.
    public var isBenchDiscoveryRunning: Bool { benchDiscoveryTask != nil }

    public func startBenchDiscovery(interval: Duration = .seconds(5)) {
        guard !isDemoMode, !isUpdateTestMode, !isScreenshotPresentation else { return }
        guard benchDiscoveryTask == nil else { return }
        benchDiscoveryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await pollDeviceDiscovery()
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    public func stopBenchDiscovery() {
        benchDiscoveryTask?.cancel()
        benchDiscoveryTask = nil
    }

    /// Read-only discovery/reconciliation used by the bench loop. Failures are
    /// intentionally silent and retain the last valid session snapshot.
    public func pollDeviceDiscovery() async {
        guard !isDemoMode, !isUpdateTestMode, !isScreenshotPresentation else { return }
        guard !macDFUInProgress else { return }
        benchDiscoveryPollCount &+= 1
        var protectedIDs = Set(deviceSessions.sessions.compactMap { session -> DeviceSessionID? in
            switch session.operationState {
            case .running, .reconnecting: session.id
            default: nil
            }
        })
        if operationInProgress, let selectedTargetECID,
           let id = deviceSessions.sessions.first(where: { $0.ecid?.caseInsensitiveCompare(selectedTargetECID) == .orderedSame })?.id {
            protectedIDs.insert(id)
        }
        await reconcileDiscovery(showFailure: false, attempts: 1, preservingDeviceStateFor: protectedIDs)
    }

    public func checkForUpdates(manual: Bool = true) async {
        guard !isDemoMode, !isScreenshotPresentation else { return }
        await updateCoordinator.check(manual: manual)
    }

    public func requestManualUpdateCheck() {
        guard !isDemoMode, !isScreenshotPresentation else { return }
        isUpdatePresentationRequested = true
        Task { await checkForUpdates() }
    }
    public func completeUpdateTest() { updateCoordinator.completeSimulation(); isUpdatePresentationRequested = false }

    public func prepareUpdate() -> Bool {
        guard canStartUpdate else { presentedError = updateBlockedMessage; return false }
        do {
            try updateCoordinator.launchUpdate()
            isUpdatePresentationRequested = false
            if updateCoordinator.isSimulation { completeUpdateTest() }
            else { applicationTerminator.requestTermination() }
            return true
        }
        catch { presentedError = error.localizedDescription; return false }
    }

    private func configureScreenshot(_ scenario: String) {
        let isDeviceCaptureScenario = scenario.hasPrefix("device-capture")
        let macRelease = DemoFirmwareLibrary.catalogueReleases.first { $0.platform == .macOS }!
        let latestIOS = DemoFirmwareLibrary.catalogueReleases.first { $0.platform == .iOS }!
        let cachedIOS = DemoFirmwareLibrary.cachedEntries.first { $0.release.platform == .iOS }!.release
        doctorReport = DoctorReport(status: UtilityStatus(host: HostStatus(isAppleSilicon: true, macOSVersion: "26.6.1", macVDMToolPath: URL(fileURLWithPath: "/demo/macvdmtool"), cfgutilPath: URL(fileURLWithPath: "/demo/cfgutil")), targets: []), configuratorPresent: true, cacheDirectory: URL(fileURLWithPath: "/demo/cache"), cacheWritable: true, restoreSupported: true)
        switch scenario {
        case "normal-mac", "normal": targetDevices = [DFUDevice(state: .normal, model: "Mac14,2", ecid: "DEMO-MAC-001")]
        case "mac-dfu", "dfu": targetDevices = [DFUDevice(state: .dfu, model: "Mac14,2", ecid: "DEMO-MAC-001")]
        case "iphone-guided-dfu": targetDevices = [DFUDevice(family: .iPhone, state: .normal, model: "iPhone 6", ecid: "DEMO-PHONE-001", productType: "iPhone7,2")]
        case "ipad-guided-dfu": targetDevices = [DFUDevice(family: .iPad, state: .normal, model: "iPad (7th generation)", ecid: "DEMO-IPAD-001", productType: "iPad7,11")]
        case "firmware-chooser": browsePlatform = .iOS; targetDevices = []
        case "download-progress":
            targetDevices = [DFUDevice(family: .iPhone, state: .normal, model: "iPhone 14 Pro", ecid: "DEMO-PHONE-001", productType: "iPhone15,2")]
        case "restore-progress", "progress":
            targetDevices = [DFUDevice(family: .iPhone, state: .dfu, model: "iPhone 14 Pro", ecid: "DEMO-PHONE-001", productType: "iPhone15,2")]
        case "completed-restore", "completed":
            targetDevices = [DFUDevice(family: .iPhone, state: .normal, model: "iPhone 14 Pro", ecid: "DEMO-PHONE-001", productType: "iPhone15,2")]
        case "mac-dfu-verification": targetDevices = []
        case "multiple-devices": targetDevices = []; deviceSessions.configureDemo()
        default: targetDevices = []
        }
        if isDeviceCaptureScenario {
            targetDevices = []
            deviceSessions.configureDemo()
        }
        managedCacheEntries = DemoFirmwareLibrary.cachedEntries
        validatedCacheEntries = Dictionary(uniqueKeysWithValues: managedCacheEntries.map { (FirmwareReleaseKey($0.release), $0) })
        catalogueReleases = AppleIPSWService.sortNewestFirst(releasesForCurrentFirmwareContext(DemoFirmwareLibrary.catalogueReleases))
        rebuildAvailableReleases()
        if scenario == "download-progress" { selectedRelease = latestIOS }
        else if scenario == "restore-progress" || scenario == "progress" || scenario == "completed-restore" || scenario == "completed" { selectedRelease = cachedIOS }
        else { selectedRelease = availableReleases.first ?? macRelease }
        refreshSelectedCacheState(); refreshImageChoices(); catalogueState = .loaded
        if scenario == "mac-dfu-verification" {
            restoreState = .running(operation: "Enter DFU", stage: "Checking for DFU…", stageIndex: nil, stageTotal: nil, fraction: nil)
        } else if scenario == "download-progress" {
            imageState = .partial(1_850_000_000); downloadState = .downloading(completed: 1_850_000_000, total: latestIOS.fileSize, bytesPerSecond: 42_600_000)
        } else if scenario == "restore-progress" || scenario == "progress" {
            restoreState = .running(operation: "Restore", stage: "Installing System", stageIndex: 4, stageTotal: 4, fraction: 0.66)
        } else if scenario == "completed-restore" || scenario == "completed" {
            restoreState = .completed("Restore completed successfully. Target restarted.")
        }
        selectedTargetECID = targetDevices.count == 1 ? targetDevices[0].ecid : nil
        if scenario != "multiple-devices" && !isDeviceCaptureScenario { deviceSessions.reconcile(targetDevices) }
        if isDeviceCaptureScenario {
            for (index, session) in deviceSessions.sessions.prefix(3).enumerated() {
                if index == 0 {
                    var device = session.device
                    device.serialNumber = "DEMO-SERIAL-MAC-001"
                    device.identifier = "DEMO-UDID-MAC-001"
                    captureSession.capture(device)
                } else {
                    captureSession.capture(session.device)
                }
            }
        }
    }

    public func refreshCatalogue() async {
        catalogueState = .loading; catalogueErrorMessage = nil
        do {
            let queried = try await ipswService.availableImages(for: browsePlatform)
            catalogueReleases = AppleIPSWService.sortNewestFirst(releasesForCurrentFirmwareContext(queried))
            await loadManagedCache(knownReleases: catalogueReleases)
            rebuildAvailableReleases()
            guard !availableReleases.isEmpty else {
                selectedRelease = nil; imageState = .none; imageChoices = []; catalogueState = .loaded
                return
            }
            if selectedRelease == nil || selectedRelease?.platform != browsePlatform { selectedRelease = availableReleases.first }
            catalogueState = .loaded; refreshSelectedCacheState(); refreshImageChoices()
        } catch {
            catalogueErrorMessage = "Apple’s restore catalogue could not be reached. \(error.localizedDescription)"
            catalogueReleases = []
            await loadManagedCache(knownReleases: [])
            rebuildAvailableReleases()
            if selectedRelease == nil, imageURL == nil { selectedRelease = availableReleases.first }
            refreshSelectedCacheState(); refreshImageChoices()
            catalogueState = .failed(error.localizedDescription)
            if imageURL == nil { presentedError = "Unable to load Apple restore images.\nCheck your internet connection and try again." }
        }
    }

    private func releasesForCurrentFirmwareContext(_ releases: [IPSWRelease]) -> [IPSWRelease] {
        releases.filter { $0.platform == browsePlatform }
    }

    public func refreshDiagnosticsAndTarget() async {
        guard !isDemoMode else { return }
        if case .reconnecting(let operation) = restoreState {
            operationGeneration &+= 1
            operationTask?.cancel(); operationTask = nil
            restoreState = .completed("\(operation) completed successfully. Target restart could not be verified.")
        }
        if privilegeMode == .signedHelper { privilegedHelperState = await Task.detached { PrivilegedDFUClient().state() }.value }
        await reconcileDiscovery(showFailure: true, attempts: targetDiscoveryAttempts)
        do {
            let diagnostics = diagnostics, targets = targetDevices
            let report = try await Task.detached { try diagnostics.report(targets: targets) }.value
            doctorReport = Self.report(report, replacingTargetsWith: targets)
        } catch { presentedError = error.localizedDescription }
    }

    @discardableResult
    private func reconcileDiscovery(showFailure: Bool, attempts: Int, preservingDeviceStateFor protectedIDs: Set<DeviceSessionID> = [], verifyingDFUECID: String? = nil) async -> [DFUDevice]? {
        discoveryRevision &+= 1
        let revision = discoveryRevision
        do {
            let discovery = discovery
            let discovered = try await Self.discoverTargets(using: discovery, attempts: attempts)
            guard revision == discoveryRevision, !Task.isCancelled else { return nil }
            var protectedIDs = protectedIDs
            if let verifyingDFUECID,
               !discovered.contains(where: { $0.state == .dfu && $0.ecid?.caseInsensitiveCompare(verifyingDFUECID) == .orderedSame }),
               let session = deviceSessions.sessions.first(where: { $0.ecid?.caseInsensitiveCompare(verifyingDFUECID) == .orderedSame }) {
                protectedIDs.insert(session.id)
            }
            var effectiveDevices = discovered
            for protectedID in protectedIDs {
                guard let protected = deviceSessions.sessions.first(where: { $0.id == protectedID }) else { continue }
                if let index = effectiveDevices.firstIndex(where: { Self.sameStableDevice($0, protected.device) }) {
                    effectiveDevices[index] = protected.device
                } else {
                    effectiveDevices.append(protected.device)
                }
            }
            let existingSessionIDs = Set(deviceSessions.sessions.map(\.id))
            targetDevices = effectiveDevices
            deviceSessions.reconcile(effectiveDevices, preservingDeviceStateFor: protectedIDs)
            captureSession.observe(discovered)
            let newSessionIDs = Set(deviceSessions.sessions.map(\.id)).subtracting(existingSessionIDs)
            if targetDevices.count == 1 { selectedTargetECID = targetDevices[0].ecid }
            else if !targetDevices.contains(where: { $0.ecid == selectedTargetECID }) { selectedTargetECID = nil }
            refreshImageChoices()
            await autoAssignCachedFirmware(to: newSessionIDs)
            return discovered
        } catch {
            if showFailure && revision == discoveryRevision { presentedError = "Target discovery failed.\n\(error.localizedDescription)" }
            return nil
        }
    }

    private nonisolated static func sameStableDevice(_ lhs: DFUDevice, _ rhs: DFUDevice) -> Bool {
        if let left = lhs.ecid, let right = rhs.ecid { return left.caseInsensitiveCompare(right) == .orderedSame }
        if let left = lhs.identifier, let right = rhs.identifier { return left.caseInsensitiveCompare(right) == .orderedSame }
        if let left = lhs.serialNumber, let right = rhs.serialNumber { return left.caseInsensitiveCompare(right) == .orderedSame }
        return false
    }

    private nonisolated static func discoverTargets(using discovery: any DeviceDiscovering, attempts: Int = 3, retryDelay: Duration = .milliseconds(400)) async throws -> [DFUDevice] {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                let devices = try await Task.detached { try discovery.devices() }.value
                if !devices.isEmpty || attempt == attempts - 1 { return devices }
            } catch {
                lastError = error
                if attempt == attempts - 1 { throw error }
            }
            try? await Task.sleep(for: retryDelay)
        }
        if let lastError { throw lastError }
        return []
    }

    private nonisolated static func report(_ report: DoctorReport, replacingTargetsWith targets: [DFUDevice]) -> DoctorReport {
        DoctorReport(
            status: UtilityStatus(host: report.status.host, targets: targets),
            configuratorPresent: report.configuratorPresent,
            cacheDirectory: report.cacheDirectory,
            cacheWritable: report.cacheWritable,
            restoreSupported: report.restoreSupported
        )
    }

    public func selectTarget(ecid: String) {
        selectedTargetECID = ecid
        refreshImageChoices()
    }

    public func selectBrowsePlatform(_ platform: RestorePlatform) async {
        guard browsePlatform != platform else { return }
        browsePlatform = platform
        resetFirmwareLibrarySelection()
        await refreshCatalogue()
    }

    public func selectSessionForDetail(_ id: DeviceSessionID) {
        guard let session = deviceSessions.sessions.first(where: { $0.id == id }), let ecid = session.ecid else { return }
        selectTarget(ecid: ecid)
    }
    @discardableResult
    public func captureConnectedDevice() -> DeviceCaptureRecord? {
        guard let target else { return nil }
        return captureSession.capture(target)
    }
    public func setSessionSelected(_ id: DeviceSessionID, selected: Bool) { deviceSessions.select(id, selected: selected) }
    public func selectAllRestoreEligibleSessions() { deviceSessions.selectAllRestoreEligible() }
    public func selectFailedSessions() { deviceSessions.selectFailed(for: batchCoordinator.operationKind) }
    public func selectNotStartedSessions() { deviceSessions.selectNotStarted(for: batchCoordinator.operationKind) }
    public func clearSessionSelection() { deviceSessions.clearSelection() }
    public func applyCurrentFirmwareToSelectedSessions() {
        deviceSessions.applySharedFirmware(release: selectedRelease, url: imageURL, to: Set(deviceSessions.selectedSessions.map(\.id)))
    }
    public var canApplyCurrentLibraryFirmwareToSelectedSessions: Bool {
        guard let release = selectedRelease, !deviceSessions.selectedSessions.isEmpty else { return false }
        return deviceSessions.selectedSessions.allSatisfy { session in
            guard let product = session.device.restoreProductType else { return false }
            return release.supportedDevices.contains(product)
        }
    }
    public func prepareFirmwareChooser(for id: DeviceSessionID) async {
        guard let session = deviceSessions.sessions.first(where: { $0.id == id }) else { return }
        await selectBrowsePlatform(session.device.family.restorePlatform)
        beginChoosingFirmware(for: id)
    }
    public func firmwareChoices(for id: DeviceSessionID) -> [IPSWChoice] {
        guard let session = deviceSessions.sessions.first(where: { $0.id == id }),
              let product = session.device.restoreProductType else { return [] }
        return imageChoices.filter { $0.release.supportedDevices.contains(product) }
    }
    public func beginChoosingFirmware(for id: DeviceSessionID) {
        let choices = firmwareChoices(for: id)
        let current = deviceSessions.sessions.first(where: { $0.id == id })?.selectedRelease
        pendingRelease = current.flatMap { release in
            choices.first { FirmwareReleaseKey($0.release) == FirmwareReleaseKey(release) }?.release
        } ?? choices.first?.release
    }
    public func confirmPendingRelease(for id: DeviceSessionID) {
        guard let release = pendingRelease,
              firmwareChoices(for: id).contains(where: { FirmwareReleaseKey($0.release) == FirmwareReleaseKey(release) }) else { return }
        selectedRelease = release
        pendingRelease = nil
        refreshSelectedCacheState()
        refreshImageChoices()
        deviceSessions.applySharedFirmware(release: release, url: imageURL, to: [id])
    }
    public func useLatestCompatibleFirmwareForSelectedSessions() async {
        let selectedSessions = deviceSessions.selectedSessions
        var assignments: [(release: IPSWRelease, url: URL?)] = []
        for snapshot in selectedSessions {
            do {
                switch try await latestCompatibleFirmware(for: snapshot.device) {
                case .unavailable:
                    deviceSessions.setFirmware(for: snapshot.id, release: nil, url: nil, validation: .incompatible("No compatible Apple restore image was found for \(snapshot.device.restoreProductType ?? "this product")."))
                case .ambiguous:
                    deviceSessions.setFirmware(for: snapshot.id, release: nil, url: nil, validation: .incompatible("Multiple latest compatible Apple restore images were found for \(snapshot.device.restoreProductType ?? "this product"); choose firmware explicitly."))
                case .resolved(let release, let url):
                    deviceSessions.setFirmware(for: snapshot.id, release: release, url: url, validation: url == nil ? .selected : .validated)
                    assignments.append((release, url))
                }
            } catch {
                deviceSessions.setFirmware(for: snapshot.id, release: nil, url: nil, validation: .invalid(error.localizedDescription))
            }
        }
        guard assignments.count == selectedSessions.count, let first = assignments.first else {
            if assignments.isEmpty, let product = selectedSessions.first?.device.restoreProductType {
                presentedError = "No compatible Apple restore image was found for \(product)."
            }
            return
        }
        let key = FirmwareReleaseKey(first.release)
        guard assignments.allSatisfy({ FirmwareReleaseKey($0.release) == key }) else { return }
        refreshImageChoices()
    }

    private func latestCompatibleFirmware(for device: DFUDevice) async throws -> LatestCompatibleFirmwareResolution {
        guard let product = device.restoreProductType else { return .unavailable }
        let compatible = AppleIPSWService.sortNewestFirst(try await ipswService.availableImages(for: device)).filter {
            !$0.supportedDevices.isEmpty && $0.supportedDevices.contains(product)
        }
        guard let latest = compatible.first else { return .unavailable }
        let latestVariants = compatible.filter { $0.version == latest.version && $0.build == latest.build }
        let identities = Set(latestVariants.map(FirmwareReleaseKey.init))
        guard identities.count == 1 else { return .ambiguous }
        let release = latestVariants[0]
        let url = validatedCacheEntries[FirmwareReleaseKey(release)]?.url
            ?? (try? cache.validCachedURL(for: release, validator: validator))
        return .resolved(release: release, cachedURL: url)
    }

    private func autoAssignCachedFirmware(to sessionIDs: Set<DeviceSessionID>) async {
        for id in sessionIDs {
            guard let session = deviceSessions.sessions.first(where: { $0.id == id }),
                  session.device.family == .iPhone || session.device.family == .iPad,
                  session.selectedRelease == nil, session.selectedImageURL == nil,
                  session.firmwareState == .unselected else { continue }
            guard case .resolved(let release, let cachedURL) = try? await latestCompatibleFirmware(for: session.device),
                  let cachedURL else { continue }
            // Recheck after the asynchronous catalogue lookup so a user choice
            // made while it was in flight is never overwritten.
            guard let current = deviceSessions.sessions.first(where: { $0.id == id }),
                  current.selectedRelease == nil, current.selectedImageURL == nil,
                  current.firmwareState == .unselected else { continue }
            deviceSessions.setFirmware(for: id, release: release, url: cachedURL, validation: .validated)
        }
    }
    public func startBatchRestore() {
        startBatch(.restore)
    }
    public func startBatch(_ kind: BatchOperationKind) {
        guard !updateLaunchInProgress else { presentedError = "DFUUtility is preparing to update."; return }
        guard !isDemoMode else { presentedError = "Demo mode cannot execute device operations."; return }
        batchCoordinator.start(kind)
        guard batchCoordinator.isRunning else { return }
        batchFollowupTask?.cancel()
        batchFollowupTask = Task { [weak self] in
            guard let self else { return }
            while batchCoordinator.isRunning, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            guard !Task.isCancelled else { return }
            await refreshDiagnosticsAndTarget()
            batchFollowupTask = nil
        }
    }
    public func stopBatchAfterCurrentTarget() { batchCoordinator.stopAfterCurrentTarget() }

    private func resetFirmwareLibrarySelection() {
        // Keep the cancelled task registered until its downloader unwinds and
        // closes the partial-file handle. A second download cannot start in
        // that brief interval.
        downloadTask?.cancel()
        availableReleases = []; selectedRelease = nil; pendingRelease = nil
        manualImageURL = nil; imageState = .none; imageChoices = []
        downloadState = .idle; catalogueState = .idle; catalogueErrorMessage = nil
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

    public func beginChoosingVersion() { pendingRelease = selectedRelease ?? availableReleases.first }
    public func choosePendingRelease(_ release: IPSWRelease) { pendingRelease = release }
    public func cancelChoosingVersion() { pendingRelease = nil }
    public func confirmPendingRelease() {
        guard let release = pendingRelease else { return }
        selectedRelease = release; pendingRelease = nil; refreshSelectedCacheState(); refreshImageChoices()
    }
    public func selectRelease(_ release: IPSWRelease) { selectedRelease = release; refreshSelectedCacheState(); refreshImageChoices() }

    public func refreshSelectedCacheState() {
        guard let release = selectedRelease else { if imageURL == nil { imageState = .none }; refreshImageChoices(); return }
        if let entry = validatedCacheEntries[FirmwareReleaseKey(release)] { imageState = .ready(entry.url); return }
        if let url = try? cache.validCachedURL(for: release, validator: validator) { imageState = .ready(url); return }
        if cache.cachedURL(for: release) != nil { imageState = .invalid("The cached image is no longer valid. Download it again."); return }
        let partial = cache.partialURL(for: release)
        let size = ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size]) as? NSNumber)?.int64Value ?? 0
        imageState = size > 0 ? .partial(size) : .none
    }

    public func beginDownload() {
        guard !updateLaunchInProgress else { presentedError = "DFUUtility is preparing to update."; return }
        guard downloadTask == nil else { return }
        downloadTask = Task { [weak self] in await self?.downloadSelected(); self?.downloadTask = nil }
    }

    public func downloadSelected() async {
        guard let release = selectedRelease else { return }
        do {
            for try await event in ipswService.downloadEvents(release) {
                switch event {
                case .started:
                    let existing = if case .partial(let bytes) = imageState { bytes } else { Int64(0) }
                    downloadState = .downloading(completed: existing, total: release.fileSize, bytesPerSecond: nil)
                case .resumed(let bytes): imageState = .partial(bytes); downloadState = .downloading(completed: bytes, total: release.fileSize, bytesPerSecond: nil)
                case .progress(let completed, let total, let speed): downloadState = .downloading(completed: completed, total: total, bytesPerSecond: speed)
                case .validating: downloadState = .validating; imageState = .validating
                case .completed(let url): downloadState = .idle; imageState = .ready(url); await refreshManagedCache()
                case .cancelled: downloadState = .cancelled; refreshSelectedCacheState(); await refreshManagedCache()
                }
                refreshImageChoices()
            }
        } catch is CancellationError { downloadState = .cancelled; refreshSelectedCacheState(); await refreshManagedCache() }
        catch { downloadState = .failed(error.localizedDescription); imageState = .invalid(error.localizedDescription); presentedError = "Image download failed.\n\(error.localizedDescription)"; refreshImageChoices(); await refreshManagedCache() }
    }

    public func cancelDownload() {
        guard downloadTask != nil else { return }
        downloadTask?.cancel(); downloadState = .cancelled; refreshSelectedCacheState(); refreshImageChoices()
    }

    public func refreshManagedCache() async {
        await loadManagedCache(knownReleases: catalogueReleases)
        rebuildAvailableReleases()
        refreshImageChoices()
    }

    public func cacheRemovalDisabledReason(for entry: ManagedIPSWEntry) -> String? {
        if isDemoMode { return "Demo firmware is read-only." }
        if deviceSessions.isFirmwareInUseByBatch(entry.url) { return "This firmware is being used by the current batch." }
        if case .downloading = downloadState, selectedRelease?.build == entry.release.build && selectedRelease?.platform == entry.release.platform { return "This image is currently downloading." }
        if case .validating = downloadState, selectedRelease?.build == entry.release.build && selectedRelease?.platform == entry.release.platform { return "This image is currently being validated." }
        let operationActive = if case .running = restoreState { true } else if case .reconnecting = restoreState { true } else { false }
        if operationActive, imageURL?.standardizedFileURL == entry.url.standardizedFileURL { return "This image is currently in use by an operation." }
        return nil
    }

    public func removeManagedCacheEntry(_ entry: ManagedIPSWEntry) async {
        guard cacheRemovalDisabledReason(for: entry) == nil else { return }
        do {
            let cache = cache
            let removedSelectedImage = imageURL?.standardizedFileURL == entry.url.standardizedFileURL
                || (selectedRelease?.build == entry.release.build && selectedRelease?.platform == entry.release.platform)
            try await Task.detached { try cache.remove(entry) }.value
            await refreshManagedCache()
            if removedSelectedImage { refreshSelectedCacheState() }
            refreshImageChoices()
        } catch { presentedError = "Unable to remove the cached image.\n\(error.localizedDescription)" }
    }

    public func resumeManagedPartial(_ entry: ManagedIPSWEntry) {
        guard entry.state == .partial, cacheRemovalDisabledReason(for: entry) == nil else { return }
        selectedRelease = entry.release; manualImageURL = nil; refreshSelectedCacheState(); refreshImageChoices(); beginDownload()
    }

    public func validateManualIPSW(_ url: URL) async {
        selectedRelease = nil; manualImageURL = url; imageState = .validating; refreshImageChoices()
        do {
            let validator = validator
            try await Task.detached { try validator.validate(url, release: nil, verifyChecksum: false) }.value
            imageState = .ready(url); refreshImageChoices()
        } catch { imageState = .invalid(error.localizedDescription); presentedError = "The selected IPSW is incomplete or invalid.\n\(error.localizedDescription)" }
    }

    public func choice(for release: IPSWRelease) -> IPSWChoice? { imageChoices.first { FirmwareReleaseKey($0.release) == FirmwareReleaseKey(release) } }
    public func displaySize(for release: IPSWRelease) -> Int64? {
        if let catalogueSize = release.fileSize { return catalogueSize }
        if let entry = validatedCacheEntries[FirmwareReleaseKey(release)] { return entry.sizeBytes }
        guard let url = cache.cachedURL(for: release) else { return nil }
        return Self.fileSize(at: url)
    }

    private nonisolated static func fileSize(at url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value
    }

    private func refreshImageChoices() {
        let visible = availableReleases
        let recommendedKey = catalogueReleases.first.map(FirmwareReleaseKey.init)
        imageChoices = visible.map { release in
            let compatibility: IPSWCompatibility
            if release.supportedDevices.isEmpty { compatibility = release.platform == .macOS ? .universalAppleSilicon : .uncertain }
            else if let model = target?.restoreProductType, release.supportedDevices.contains(model) { compatibility = .compatible(model: model) }
            else { compatibility = .uncertain }
            return IPSWChoice(release: release, isRecommended: FirmwareReleaseKey(release) == recommendedKey, cacheState: cacheState(for: release), compatibility: compatibility)
        }
    }

    private func cacheState(for release: IPSWRelease) -> IPSWChoiceCacheState {
        if selectedRelease?.build == release.build, imageState == .validating { return .validating }
        if let entry = validatedCacheEntries[FirmwareReleaseKey(release)] { return .downloaded(entry.url) }
        if let url = try? cache.validCachedURL(for: release, validator: validator) { return .downloaded(url) }
        if cache.cachedURL(for: release) != nil { return .invalid }
        let partial = cache.partialURL(for: release)
        let size = ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size]) as? NSNumber)?.int64Value ?? 0
        return size > 0 ? .partial(size) : .downloadRequired
    }

    private func loadManagedCache(knownReleases: [IPSWRelease]) async {
        if isDemoMode {
            managedCacheEntries = DemoFirmwareLibrary.cachedEntries
            validatedCacheEntries = Dictionary(uniqueKeysWithValues: managedCacheEntries.map { (FirmwareReleaseKey($0.release), $0) })
            return
        }
        let cache = cache, validator = validator
        managedCacheEntries = (try? await Task.detached { try cache.managedEntries(validator: validator, knownReleases: knownReleases) }.value) ?? []
        validatedCacheEntries = Dictionary(uniqueKeysWithValues: managedCacheEntries.compactMap { entry in
            entry.state == .completeValidated ? (FirmwareReleaseKey(entry.release), entry) : nil
        })
    }

    private func rebuildAvailableReleases() {
        let applicableCached = validatedCacheEntries.values.map(\.release).filter {
            !releasesForCurrentFirmwareContext([$0]).isEmpty
        }
        var merged = Dictionary(uniqueKeysWithValues: applicableCached.map { (FirmwareReleaseKey($0), $0) })
        for release in catalogueReleases {
            let key = FirmwareReleaseKey(release)
            if let cached = merged[key], release.supportedDevices.isEmpty, !cached.supportedDevices.isEmpty {
                merged[key] = IPSWRelease(platform: release.platform, version: release.version, build: release.build,
                    downloadURL: release.downloadURL, fileSize: release.fileSize, checksum: release.checksum,
                    supportedDevices: cached.supportedDevices, signingStatus: release.signingStatus)
            } else {
                merged[key] = release
            }
        }
        availableReleases = AppleIPSWService.sortNewestFirst(Array(merged.values))
        if let selectedRelease, !availableReleases.contains(where: { FirmwareReleaseKey($0) == FirmwareReleaseKey(selectedRelease) }) {
            self.selectedRelease = nil
            imageState = .none
        }
        if selectedRelease == nil { selectedRelease = availableReleases.first }
    }

    public func enterDFU() async {
        guard !hasSyntheticProductionIdentity else { presentedError = "A synthetic test target identity was rejected in production mode."; return }
        guard canEnterDFU else { presentedError = "macvdmtool is not installed or DFU is unavailable."; return }
        operationGeneration &+= 1
        discoveryRevision &+= 1
        let generation = operationGeneration
        defer {
            if generation == operationGeneration, Task.isCancelled { cancelMacDFUVerification() }
        }
        let originalECID = target?.ecid
        presentedError = nil
        let log = try? operationLogger.start(operation: "Enter DFU", target: target, release: nil)
        lastLogURL = log
        restoreState = .running(operation: "Enter DFU", stage: "Requesting administrator authorization…", stageIndex: nil, stageTotal: nil, fraction: nil)
        do {
            if let log { try? operationLogger.append("Privilege mode: \(privilegeMode.displayName)\nAuthorization requested via \(privilegeMode == .community ? "macOS system administrator prompt" : "signed helper")", to: log) }
            let controller = dfuController; try await Task.detached { try controller.enterDFU(timeout: 30) }.value
            guard generation == operationGeneration, !Task.isCancelled else { return }
            if let log { try? operationLogger.append("Transition result: success\nFinal verified state: DFU, same ECID", to: log) }
            restoreState = .idle; await refreshDiagnosticsAndTarget()
        } catch {
            guard generation == operationGeneration, !Task.isCancelled else { return }
            if let toolFailure = error as? MacVDMToolFailure, toolFailure.reachedDBMaWithoutFinalReply {
                if let log { try? operationLogger.append("Unverified transition\n\(toolFailure.diagnosticDescription)\nChecking for same-ECID DFU for up to 30 seconds", to: log) }
                restoreState = .running(operation: "Enter DFU", stage: "Checking for DFU…", stageIndex: nil, stageTotal: nil, fraction: nil)
                let deadline = ContinuousClock.now.advanced(by: dfuVerificationDuration)
                while ContinuousClock.now < deadline, generation == operationGeneration, !Task.isCancelled {
                    // This is the same reconciliation used by Refresh. The bench
                    // poller yields while Enter DFU owns transition verification.
                    let revision = discoveryRevision &+ 1
                    let observed = await reconcileDiscovery(showFailure: false, attempts: 1, verifyingDFUECID: originalECID)
                    guard generation == operationGeneration, !Task.isCancelled else { return }
                    if ContinuousClock.now < deadline, discoveryRevision == revision,
                       let originalECID, !originalECID.isEmpty,
                       observed?.contains(where: { $0.state == .dfu && $0.ecid?.caseInsensitiveCompare(originalECID) == .orderedSame }) == true {
                        restoreState = .completed("Mac entered DFU. The final VDM acknowledgement wasn’t received, but DFUUtility subsequently detected this Mac in DFU mode.")
                        if let log { try? operationLogger.append("Verified success: same ECID rediscovered in DFU. No DFU command was retried.", to: log) }
                        return
                    }
                    do { try await Task.sleep(for: min(dfuVerificationInterval, ContinuousClock.now.duration(to: deadline))) }
                    catch { return }
                }
                guard generation == operationGeneration, !Task.isCancelled else { return }
            }
            let failure = DFUFailurePresentation(error: error)
            if let log { try? operationLogger.append("FAILED\n\(failure.diagnosticDetails)\nOperation context cleared", to: log) }
            restoreState = .failed(failure.userMessage)
            presentedError = failure.userMessage + (log == nil ? "" : "\n\nTechnical details were saved to the operation log. Use View Log to review them.")
        }
    }

    public func cancelMacDFUVerification() {
        guard macDFUInProgress else { return }
        operationGeneration &+= 1
        discoveryRevision &+= 1
        restoreState = .failed("DFU transition verification was cancelled. Click Refresh to check the target’s state.")
    }

    @discardableResult
    public func prepareMobileDFUAssistant() -> Bool {
        guard let target, let ecid = target.ecid, !ecid.isEmpty else {
            presentedError = "The guided DFU assistant requires an ECID-addressable mobile target."
            return false
        }
        guard target.family == .iPhone || target.family == .iPad,
              target.state == .normal || target.state == .recovery,
              let profile = MobileDFUInstructionProfile.profile(for: target) else {
            presentedError = "Guided DFU instructions are not yet available for this product type."
            return false
        }
        mobileDFUAssistant?.deactivate()
        mobileDFUAssistant = MobileDFUAssistantModel(
            target: target,
            profile: profile,
            discovery: discovery,
            operationLogger: operationLogger,
            isDemoMode: isDemoMode,
            onDFUDetected: { [weak self] detected in self?.acceptMobileDFUDetection(detected, expectedECID: ecid) },
            onLogCreated: { [weak self] url in self?.lastLogURL = url }
        )
        return true
    }

    public func dismissMobileDFUAssistant() {
        mobileDFUAssistant?.deactivate()
        mobileDFUAssistant = nil
        Task { await refreshDiagnosticsAndTarget() }
    }

    private func acceptMobileDFUDetection(_ device: DFUDevice, expectedECID: String) {
        guard device.state == .dfu, device.ecid?.lowercased() == expectedECID.lowercased() else { return }
        if let index = targetDevices.firstIndex(where: { $0.ecid?.lowercased() == expectedECID.lowercased() }) { targetDevices[index] = device }
        else { targetDevices.append(device) }
        selectedTargetECID = device.ecid
        refreshImageChoices()
    }

    public func restoreConfirmed() {
        guard canRestore, let url = detailedSession?.selectedImageURL, let target else { presentedError = restoreUnavailableMessage; return }
        runRestore(targetDevices.count > 1 && target.ecid != nil ? .targetedRestore(url, ecid: target.ecid!) : .restore(url))
    }
    public func revive() {
        guard canRevive, let target else { presentedError = "No supported real target is connected for revive."; return }
        runRestore(targetDevices.count > 1 && target.ecid != nil ? .targetedRevive(ecid: target.ecid!) : .revive)
    }
    public func restart() {
        guard canRestart, let target else { presentedError = restartUnavailableMessage; return }
        runRestore(targetDevices.count > 1 && target.ecid != nil ? .targetedReboot(ecid: target.ecid!) : .reboot)
    }
    private func runRestore(_ action: RestoreAction) {
        guard !operationInProgress else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        let operationTarget = target
        let log = try? operationLogger.start(operation: action.operationName, target: target, release: detailedSession?.selectedRelease)
        lastLogURL = log
        restoreState = .running(operation: action.operationName, stage: "Preparing", stageIndex: nil, stageTotal: nil, fraction: nil)
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in restoreEngine.events(for: action) {
                    guard generation == operationGeneration, !Task.isCancelled else { return }
                    if let log { try? operationLogger.append(String(describing: event), to: log) }
                    restoreState = OperationProgressReducer.reduce(restoreState, event: event, operation: action.operationName)
                    if case .completed = event {
                        if let log { try? operationLogger.append("Reconnect verification started", to: log) }
                        await verifyReconnect(operation: action.operationName, originalTarget: operationTarget, generation: generation, log: log)
                    }
                }
            } catch {
                guard generation == operationGeneration, !Task.isCancelled else { return }
                if let log { try? operationLogger.append("FAILED: \(error.localizedDescription)\nOperation context cleared", to: log) }
                restoreState = .failed(error.localizedDescription)
                let logGuidance = log == nil ? "" : " View the operation log for technical details."
                presentedError = "\(action.operationName) failed.\n\(error.localizedDescription)\n\nRefresh and verify the device is still connected. Check the selected firmware where applicable.\(logGuidance)"
            }
            if generation == operationGeneration { operationTask = nil }
        }
    }

    private func verifyReconnect(operation: String, originalTarget: DFUDevice?, generation: UInt64, log: URL?) async {
        let result = await ReconnectVerifier(discovery: discovery).wait(expectedECID: originalTarget?.ecid, attempts: reconnectAttempts, interval: reconnectInterval)
        guard generation == operationGeneration, !Task.isCancelled else { return }
        switch result {
        case .restarted(let device):
            targetDevices = [Self.mergingRediscovered(device, with: originalTarget)]
            selectedTargetECID = device.ecid
            restoreState = .completed("\(operation) completed successfully. Target restarted.")
            if let log { try? operationLogger.append("Reconnect verified\nOperation context cleared", to: log) }
        case .unverified:
            restoreState = .completed("\(operation) completed successfully. Target restart could not be verified.")
            if let log { try? operationLogger.append("Reconnect verification timed out\nOperation context cleared", to: log) }
        }
    }

    private nonisolated static func mergingRediscovered(_ device: DFUDevice, with original: DFUDevice?) -> DFUDevice {
        guard let original, device.ecid?.caseInsensitiveCompare(original.ecid ?? "") == .orderedSame else { return device }
        return DFUDevice(
            family: device.family == .unknown ? original.family : device.family,
            state: device.state,
            model: device.model ?? original.model,
            identifier: device.identifier ?? original.identifier,
            ecid: device.ecid,
            productType: device.productType ?? original.productType,
            modelIdentifier: device.modelIdentifier ?? original.modelIdentifier,
            serialNumber: device.serialNumber ?? original.serialNumber
        )
    }

    public func setDemoTarget(_ state: DeviceState?) { guard isDemoMode else { return }; targetDevices = state.map { [DFUDevice(state: $0, model: "DemoMac", ecid: "DEMO-ECID")] } ?? [] }
    public func setDemoMobileTarget(_ state: DeviceState?) { guard isDemoMode else { return }; targetDevices = state.map { [DFUDevice(family: .iPhone, state: $0, model: "iPhone7,2", ecid: "DEMO-MOBILE-ECID", productType: "iPhone7,2")] } ?? [] }
    public func setDemoRestoreFailure() { guard isDemoMode else { return }; restoreState = .failed("Demonstration failure — no command was run.") }
}
