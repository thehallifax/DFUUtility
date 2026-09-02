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

    public let isDemoMode: Bool
    public let deviceSessions: DeviceSessionManager
    public let batchCoordinator: BatchCoordinator
    public var isScreenshotPresentation: Bool { screenshotScenario != nil }
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
    private let requiresPrivilegedHelperSetup: Bool
    private let targetDiscoveryAttempts: Int
    private let reconnectAttempts: Int
    private let reconnectInterval: Duration
    private var downloadTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var operationGeneration: UInt64 = 0
    private var batchFollowupTask: Task<Void, Never>?
    private var observations: Set<AnyCancellable> = []
    private var catalogueReleases: [IPSWRelease] = []
    private var validatedCacheEntries: [FirmwareReleaseKey: ManagedIPSWEntry] = [:]

    public init(ipswService: any IPSWService = AppleIPSWService(), discovery: any DeviceDiscovering = ConfiguratorDeviceDiscovery(), cache: IPSWCache = IPSWCache(), validator: any IPSWValidating = IPSWValidator(), diagnostics: any DiagnosticsProviding = DoctorService(), restoreEngine: any RestoreOperating = RestoreEngine(), dfuController: (any DFUOperating)? = nil, operationLogger: any OperationLogging = OperationLogger(), requiresPrivilegedHelperSetup: Bool = true, privilegeMode: PrivilegeMode? = nil, isDemoMode: Bool = false, screenshotScenario: String? = nil, targetDiscoveryAttempts: Int = 1, reconnectAttempts: Int = 10, reconnectInterval: Duration = .seconds(2)) {
        let resolvedMode = privilegeMode ?? (requiresPrivilegedHelperSetup ? PrivilegeModeSelector.select() : .community)
        let sessionManager = DeviceSessionManager()
        self.deviceSessions = sessionManager
        self.batchCoordinator = BatchCoordinator(sessions: sessionManager, operatorService: DefaultBatchTargetOperator(restore: restoreEngine, discovery: discovery, reconnectAttempts: reconnectAttempts, reconnectInterval: reconnectInterval), logger: operationLogger)
        self.ipswService = ipswService; self.discovery = discovery; self.cache = cache; self.validator = validator
        self.diagnostics = diagnostics; self.restoreEngine = restoreEngine
        self.dfuController = dfuController ?? PrivilegedDFUOperator(discovery: discovery, client: resolvedMode == .signedHelper ? PrivilegedDFUClient() : CommunityDFURequest())
        self.operationLogger = operationLogger; self.requiresPrivilegedHelperSetup = resolvedMode == .signedHelper; self.privilegeMode = resolvedMode; self.isDemoMode = isDemoMode; self.screenshotScenario = screenshotScenario; self.targetDiscoveryAttempts = max(1, targetDiscoveryAttempts); self.reconnectAttempts = max(1, reconnectAttempts); self.reconnectInterval = reconnectInterval
        sessionManager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        batchCoordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
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
    public var managedCacheDirectoryURL: URL { cache.directory }
    public func cacheRevealURL(for entry: ManagedIPSWEntry) -> URL { entry.url }
    public func prepareCacheDirectoryForReveal() -> URL? { do { try cache.prepare(); return cache.directory } catch { presentedError = "Unable to open the IPSW cache.\n\(error.localizedDescription)"; return nil } }
    public var operationInProgress: Bool {
        if batchCoordinator.isRunning { return true }
        if case .running = restoreState { return true }
        if case .reconnecting = restoreState { return true }
        return false
    }
    public var reconnectInProgress: Bool { if case .reconnecting = restoreState { true } else { false } }
    public var canEnterDFU: Bool { !isDemoMode && targetDevices.count == 1 && target?.family == .mac && target?.state == .normal && !hasSyntheticProductionIdentity && doctorReport?.status.host.macVDMToolPath != nil && (!requiresPrivilegedHelperSetup || privilegedHelperState.isReady) && !operationInProgress }
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
    public var isFirmwareLibraryMode: Bool { target == nil }
    public var targetRestorePlatform: RestorePlatform { target?.family.restorePlatform ?? browsePlatform }
    public var restoreSectionTitle: String { isFirmwareLibraryMode ? "Firmware Library" : "\(targetRestorePlatform.displayName) Restore" }
    public var manageDownloadsAvailable: Bool { true }
    private var hasSyntheticProductionIdentity: Bool {
        guard !isDemoMode, let value = target?.ecid?.uppercased() else { return false }
        return value == "TEST" || value.hasPrefix("DEMO") || value.hasPrefix("TEST-")
    }
    public var canRestore: Bool {
        guard !isDemoMode, let target else { return false }
        return RestoreTargetStatePolicy.allowsRestore(target) && imageURL != nil && selectedImageMatchesTarget && !operationInProgress
    }
    public var restoreUnavailableMessage: String {
        if let target, (target.family == .iPhone || target.family == .iPad), !RestoreTargetStatePolicy.allowsRestore(target) {
            return "Restore requires the \(target.family.displayName) to be in Recovery or DFU mode."
        }
        return "Restore requires a compatible validated image and a positively detected supported target."
    }
    public var canRevive: Bool {
        guard !isDemoMode, let target, !operationInProgress else { return false }
        return target.family == .mac ? (target.state == .dfu || target.state == .recovery) : target.state == .recovery
    }
    private var selectedImageMatchesTarget: Bool {
        guard let release = selectedRelease, let product = target?.restoreProductType else { return selectedRelease == nil }
        return !release.supportedDevices.isEmpty && release.supportedDevices.contains(product)
    }

    public func load() async {
        if let screenshotScenario { configureScreenshot(screenshotScenario); return }
        if isDemoMode { deviceSessions.configureDemo(); await refreshCatalogue(); return }
        await refreshDiagnosticsAndTarget()
        if catalogueState == .idle { await refreshCatalogue() }
        await refreshManagedCache()
    }

    private func configureScreenshot(_ scenario: String) {
        let macRelease = IPSWRelease(version: "26.6.2", build: "25G83", downloadURL: URL(string: "https://updates.cdn-apple.com/demo-mac.ipsw")!, fileSize: 19_772_231_540, supportedDevices: ["Mac14,2"])
        let iOSRelease = IPSWRelease(platform: .iOS, version: "12.5.8", build: "16H88", downloadURL: URL(string: "https://updates.cdn-apple.com/demo-ios.ipsw")!, fileSize: 4_321_000_000, supportedDevices: ["iPhone7,2"])
        let iPadRelease = IPSWRelease(platform: .iPadOS, version: "18.7.10", build: "22H374", downloadURL: URL(string: "https://updates.cdn-apple.com/demo-ipados.ipsw")!, fileSize: 7_860_000_000, supportedDevices: ["iPad7,11"])
        let release = scenario == "firmware-chooser" ? iPadRelease : (scenario == "download-progress" || scenario == "restore-progress" || scenario == "completed-restore" ? iOSRelease : macRelease)
        let image = URL(fileURLWithPath: "/demo/(release.build)/Restore.ipsw")
        availableReleases = [release]; selectedRelease = release; imageState = .ready(image); catalogueState = .loaded
        imageChoices = [.init(release: release, isRecommended: true, cacheState: .downloaded(image), compatibility: .compatible(model: release.supportedDevices[0]))]
        doctorReport = DoctorReport(status: UtilityStatus(host: HostStatus(isAppleSilicon: true, macOSVersion: "26.6.1", macVDMToolPath: URL(fileURLWithPath: "/demo/macvdmtool"), cfgutilPath: URL(fileURLWithPath: "/demo/cfgutil")), targets: []), configuratorPresent: true, cacheDirectory: URL(fileURLWithPath: "/demo/cache"), cacheWritable: true, restoreSupported: true)
        switch scenario {
        case "normal-mac", "normal": targetDevices = [DFUDevice(state: .normal, model: "Mac14,2", ecid: "DEMO-MAC-001")]
        case "mac-dfu", "dfu": targetDevices = [DFUDevice(state: .dfu, model: "Mac14,2", ecid: "DEMO-MAC-001")]
        case "iphone-guided-dfu": targetDevices = [DFUDevice(family: .iPhone, state: .normal, model: "iPhone 6", ecid: "DEMO-PHONE-001", productType: "iPhone7,2")]
        case "ipad-guided-dfu", "firmware-chooser": targetDevices = [DFUDevice(family: .iPad, state: .normal, model: "iPad (7th generation)", ecid: "DEMO-IPAD-001", productType: "iPad7,11")]
        case "download-progress":
            targetDevices = [DFUDevice(family: .iPhone, state: .normal, model: "iPhone 6", ecid: "DEMO-PHONE-001", productType: "iPhone7,2")]
            imageState = .partial(1_850_000_000); downloadState = .downloading(completed: 1_850_000_000, total: 4_321_000_000, bytesPerSecond: 42_600_000)
        case "restore-progress", "progress":
            targetDevices = [DFUDevice(family: .iPhone, state: .dfu, model: "iPhone 6", ecid: "DEMO-PHONE-001", productType: "iPhone7,2")]
            restoreState = .running(operation: "Restore", stage: "Installing System", stageIndex: 4, stageTotal: 4, fraction: 0.66)
        case "completed-restore", "completed":
            targetDevices = [DFUDevice(family: .iPhone, state: .normal, model: "iPhone 6", ecid: "DEMO-PHONE-001", productType: "iPhone7,2")]
            restoreState = .completed("Restore completed successfully. Target restarted.")
        case "manage-downloads":
            targetDevices = [DFUDevice(state: .normal, model: "Mac14,2", ecid: "DEMO-MAC-001")]
            managedCacheEntries = [
                .init(release: macRelease, state: .completeValidated, sizeBytes: macRelease.fileSize!, url: URL(fileURLWithPath: "/demo/cache/25G83/Restore.ipsw")),
                .init(release: iOSRelease, state: .completeValidated, sizeBytes: iOSRelease.fileSize!, url: URL(fileURLWithPath: "/demo/cache/iOS/16H88/Restore.ipsw")),
                .init(release: iPadRelease, state: .completeValidated, sizeBytes: iPadRelease.fileSize!, url: URL(fileURLWithPath: "/demo/cache/iPadOS/22H374/Restore.ipsw"))
            ]
        default: targetDevices = []
        }
        selectedTargetECID = targetDevices.count == 1 ? targetDevices[0].ecid : nil
        deviceSessions.reconcile(targetDevices)
    }

    public func refreshCatalogue() async {
        catalogueState = .loading; catalogueErrorMessage = nil
        do {
            let queried = if let target { try await ipswService.availableImages(for: target) } else { try await ipswService.availableImages(for: browsePlatform) }
            catalogueReleases = AppleIPSWService.sortNewestFirst(releasesForCurrentFirmwareContext(queried))
            await loadManagedCache(knownReleases: catalogueReleases)
            rebuildAvailableReleases()
            guard !availableReleases.isEmpty else {
                selectedRelease = nil; imageState = .none; imageChoices = []; catalogueState = .loaded
                return
            }
            let compatible = target?.restoreProductType.flatMap { product in availableReleases.first { $0.supportedDevices.contains(product) } }
            if selectedRelease == nil || (target?.restoreProductType != nil && !selectedImageMatchesTarget) { selectedRelease = compatible ?? (target == nil ? availableReleases.first : nil) }
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
        let platformFiltered = releases.filter { $0.platform == targetRestorePlatform }
        return target?.restoreProductType.map { product in
            platformFiltered.filter { !$0.supportedDevices.isEmpty && $0.supportedDevices.contains(product) }
        } ?? platformFiltered
    }

    public func refreshDiagnosticsAndTarget() async {
        guard !isDemoMode else { return }
        if case .reconnecting(let operation) = restoreState {
            operationGeneration &+= 1
            operationTask?.cancel(); operationTask = nil
            restoreState = .completed("\(operation) completed successfully. Target restart could not be verified.")
        }
        let previousContext = target.map(TargetContext.init)
        if privilegeMode == .signedHelper { privilegedHelperState = await Task.detached { PrivilegedDFUClient().state() }.value }
        do {
            let discovery = discovery
            let discovered = try await Self.discoverTargets(using: discovery, attempts: targetDiscoveryAttempts)
            targetDevices = discovered
            deviceSessions.reconcile(discovered)
            if targetDevices.count == 1 { selectedTargetECID = targetDevices[0].ecid }
            else if !targetDevices.contains(where: { $0.ecid == selectedTargetECID }) { selectedTargetECID = nil }
            let targetChanged = previousContext != target.map(TargetContext.init)
            if targetChanged { resetTargetSpecificImageState() }
            refreshImageChoices()
            if targetChanged { await refreshCatalogue() }
        } catch { presentedError = "Target discovery failed.\n\(error.localizedDescription)" }
        do {
            let diagnostics = diagnostics, targets = targetDevices
            let report = try await Task.detached { try diagnostics.report(targets: targets) }.value
            doctorReport = Self.report(report, replacingTargetsWith: targets)
        } catch { presentedError = error.localizedDescription }
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
        syncCurrentSessionFirmware()
        selectedTargetECID = ecid; resetTargetSpecificImageState()
        if let session = deviceSessions.sessions.first(where: { $0.ecid?.caseInsensitiveCompare(ecid) == .orderedSame }) {
            selectedRelease = session.selectedRelease
            if let url = session.selectedImageURL { imageState = .ready(url) }
        }
        Task { await refreshCatalogue() }
    }

    public func selectBrowsePlatform(_ platform: RestorePlatform) async {
        guard target == nil, browsePlatform != platform else { return }
        browsePlatform = platform
        resetTargetSpecificImageState()
        await refreshCatalogue()
    }

    public func selectSessionForDetail(_ id: DeviceSessionID) {
        guard let session = deviceSessions.sessions.first(where: { $0.id == id }), let ecid = session.ecid else { return }
        selectTarget(ecid: ecid)
    }
    public func setSessionSelected(_ id: DeviceSessionID, selected: Bool) { deviceSessions.select(id, selected: selected) }
    public func selectAllRestoreEligibleSessions() { deviceSessions.selectAllRestoreEligible() }
    public func clearSessionSelection() { deviceSessions.clearSelection() }
    public func applyCurrentFirmwareToSelectedSessions() {
        deviceSessions.applySharedFirmware(release: selectedRelease, url: imageURL, to: Set(deviceSessions.selectedSessions.map(\.id)))
    }
    public func useLatestCompatibleFirmwareForSelectedSessions() async {
        for snapshot in deviceSessions.selectedSessions {
            do {
                let releases = try await ipswService.availableImages(for: snapshot.device)
                guard let product = snapshot.device.restoreProductType,
                      let release = AppleIPSWService.sortNewestFirst(releases).first(where: { $0.supportedDevices.contains(product) }) else {
                    deviceSessions.setFirmware(for: snapshot.id, release: nil, url: nil, validation: .incompatible("No compatible Apple restore image was found for \(snapshot.device.restoreProductType ?? "this product")."))
                    continue
                }
                let url = try? cache.validCachedURL(for: release, validator: validator)
                deviceSessions.setFirmware(for: snapshot.id, release: release, url: url, validation: url == nil ? .selected : .validated)
            } catch {
                deviceSessions.setFirmware(for: snapshot.id, release: nil, url: nil, validation: .invalid(error.localizedDescription))
            }
        }
    }
    public func startBatchRestore() {
        startBatch(.restore)
    }
    public func startBatch(_ kind: BatchOperationKind) {
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

    private struct TargetContext: Equatable {
        let family: AppleDeviceFamily
        let productType: String?
        let ecid: String?

        init(_ device: DFUDevice) {
            family = device.family
            productType = device.restoreProductType
            ecid = device.ecid?.lowercased()
        }
    }

    private func resetTargetSpecificImageState() {
        downloadTask?.cancel(); downloadTask = nil
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
        if let entry = validatedCacheEntries[FirmwareReleaseKey(release)] { imageState = .ready(entry.url); syncCurrentSessionFirmware(); return }
        if let url = try? cache.validCachedURL(for: release, validator: validator) { imageState = .ready(url); syncCurrentSessionFirmware(); return }
        if cache.cachedURL(for: release) != nil { imageState = .invalid("The cached image is no longer valid. Download it again."); syncCurrentSessionFirmware(); return }
        let partial = cache.partialURL(for: release)
        let size = ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size]) as? NSNumber)?.int64Value ?? 0
        imageState = size > 0 ? .partial(size) : .none
        syncCurrentSessionFirmware()
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
                case .started:
                    let existing = if case .partial(let bytes) = imageState { bytes } else { Int64(0) }
                    downloadState = .downloading(completed: existing, total: release.fileSize, bytesPerSecond: nil)
                case .resumed(let bytes): imageState = .partial(bytes); downloadState = .downloading(completed: bytes, total: release.fileSize, bytesPerSecond: nil)
                case .progress(let completed, let total, let speed): downloadState = .downloading(completed: completed, total: total, bytesPerSecond: speed)
                case .validating: downloadState = .validating; imageState = .validating
                case .completed(let url): downloadState = .idle; imageState = .ready(url); syncCurrentSessionFirmware(); await refreshManagedCache()
                case .cancelled: downloadState = .cancelled; refreshSelectedCacheState(); await refreshManagedCache()
                }
                refreshImageChoices()
            }
        } catch is CancellationError { downloadState = .cancelled; refreshSelectedCacheState(); await refreshManagedCache() }
        catch { downloadState = .failed(error.localizedDescription); imageState = .invalid(error.localizedDescription); presentedError = "Image download failed.\n\(error.localizedDescription)"; refreshImageChoices(); await refreshManagedCache() }
    }

    public func cancelDownload() {
        guard downloadTask != nil else { return }
        downloadTask?.cancel(); downloadTask = nil; downloadState = .cancelled; refreshSelectedCacheState(); refreshImageChoices()
    }

    public func refreshManagedCache() async {
        await loadManagedCache(knownReleases: catalogueReleases)
        rebuildAvailableReleases()
        refreshImageChoices()
    }

    public func cacheRemovalDisabledReason(for entry: ManagedIPSWEntry) -> String? {
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
            let compatibility: IPSWRelease? = try target.flatMap { target in
                guard target.family == .iPhone || target.family == .iPad else { return nil }
                guard let product = target.restoreProductType else { throw DFUError.invalidIPSW("the connected mobile target does not expose a product type") }
                let platform: RestorePlatform = target.family == .iPhone ? .iOS : .iPadOS
                return IPSWRelease(platform: platform, version: "Local", build: "Local", downloadURL: url, supportedDevices: [product])
            }
            try await Task.detached { try validator.validate(url, release: compatibility, verifyChecksum: false) }.value
            imageState = .ready(url); syncCurrentSessionFirmware(); refreshImageChoices()
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
        let visible = availableReleases.filter { release in
            guard let model = target?.restoreProductType, !release.supportedDevices.isEmpty else { return target == nil }
            return release.supportedDevices.contains(model)
        }
        let recommendedKey = catalogueReleases.first.map(FirmwareReleaseKey.init)
        imageChoices = visible.map { release in
            let compatibility: IPSWCompatibility
            if release.supportedDevices.isEmpty { compatibility = .universalAppleSilicon }
            else if let model = target?.restoreProductType, release.supportedDevices.contains(model) { compatibility = .compatible(model: model) }
            else { compatibility = .uncertain }
            return IPSWChoice(release: release, isRecommended: FirmwareReleaseKey(release) == recommendedKey, cacheState: cacheState(for: release), compatibility: compatibility)
        }
    }

    private func syncCurrentSessionFirmware() {
        guard let target, let ecid = target.ecid,
              let session = deviceSessions.sessions.first(where: { $0.ecid?.caseInsensitiveCompare(ecid) == .orderedSame }) else { return }
        let state: SessionFirmwareState
        switch imageState {
        case .ready: state = .validated
        case .invalid(let reason): state = .invalid(reason)
        case .none, .partial, .validating: state = selectedRelease == nil ? .unselected : .selected
        }
        deviceSessions.setFirmware(for: session.id, release: selectedRelease, url: imageURL, validation: state)
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
        let log = try? operationLogger.start(operation: "Enter DFU", target: target, release: nil)
        lastLogURL = log
        restoreState = .running(operation: "Enter DFU", stage: "Requesting administrator authorization…", stageIndex: nil, stageTotal: nil, fraction: nil)
        do {
            if let log { try? operationLogger.append("Privilege mode: \(privilegeMode.displayName)\nAuthorization requested via \(privilegeMode == .community ? "macOS system administrator prompt" : "signed helper")", to: log) }
            let controller = dfuController; try await Task.detached { try controller.enterDFU(timeout: 30) }.value
            if let log { try? operationLogger.append("Transition result: success\nFinal verified state: DFU, same ECID", to: log) }
            restoreState = .idle; await refreshDiagnosticsAndTarget()
        } catch {
            let failure = DFUFailurePresentation(error: error)
            if let log { try? operationLogger.append("FAILED\n\(failure.diagnosticDetails)\nOperation context cleared", to: log) }
            restoreState = .failed(failure.userMessage)
            presentedError = failure.userMessage + (log == nil ? "" : "\n\nTechnical details were saved to the operation log. Use View Log to review them.")
        }
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
        guard canRestore, let url = imageURL, let target else { presentedError = restoreUnavailableMessage; return }
        runRestore(targetDevices.count > 1 && target.ecid != nil ? .targetedRestore(url, ecid: target.ecid!) : .restore(url))
    }
    public func revive() {
        guard canRevive, let target else { presentedError = "No supported real target is connected for revive."; return }
        runRestore(targetDevices.count > 1 && target.ecid != nil ? .targetedRevive(ecid: target.ecid!) : .revive)
    }
    private func runRestore(_ action: RestoreAction) {
        guard !operationInProgress else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        let operationTarget = target
        let log = try? operationLogger.start(operation: action.operationName, target: target, release: selectedRelease)
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
                restoreState = .failed(error.localizedDescription); presentedError = "\(action.operationName) failed.\n\(error.localizedDescription)"
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
