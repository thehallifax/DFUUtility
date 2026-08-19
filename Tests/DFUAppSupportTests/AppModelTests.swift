import DFUAppSupport
import DFUCore
import Foundation
import Testing

private let testURL = URL(fileURLWithPath: "/tmp/test.ipsw")
private func makeRelease(_ version: String = "26.6.2", _ build: String = "25G83") -> IPSWRelease { IPSWRelease(version: version, build: build, downloadURL: URL(string: "https://updates.cdn-apple.com/test.ipsw")!, fileSize: 100) }
private func tempCache() -> IPSWCache { IPSWCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) }

private struct AppMockService: IPSWService {
    var releases: [IPSWRelease] = [makeRelease()]
    var events: [DownloadEvent] = []
    var failure: String?
    func availableImages(for device: DFUDevice?) async throws -> [IPSWRelease] { if let failure { throw DFUError.invalidIPSW(failure) }; return AppleIPSWService.sortNewestFirst(releases) }
    func recommendedImage(for device: DFUDevice?) async throws -> IPSWRelease { try await availableImages(for: device)[0] }
    func download(_ release: IPSWRelease, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL { testURL }
    func downloadEvents(_ release: IPSWRelease) -> AsyncThrowingStream<DownloadEvent, Error> { AsyncThrowingStream { continuation in events.forEach { continuation.yield($0) }; continuation.finish() } }
}
private struct AppMockDiscovery: DeviceDiscovering { let values: [DFUDevice]; func devices() throws -> [DFUDevice] { values } }
private struct AppMockValidator: IPSWValidating { let valid: Bool; func validate(_ url: URL, release: IPSWRelease?, verifyChecksum: Bool) throws { if !valid { throw DFUError.invalidIPSW("mock invalid") } } }
private struct AppMockDiagnostics: DiagnosticsProviding {
    let reportValue: DoctorReport
    init(macVDM: Bool = true) { reportValue = DoctorReport(status: UtilityStatus(host: HostStatus(isAppleSilicon: true, macOSVersion: "26.6.1", macVDMToolPath: macVDM ? URL(fileURLWithPath: "/macvdmtool") : nil, cfgutilPath: URL(fileURLWithPath: "/cfgutil")), targets: []), configuratorPresent: true, cacheDirectory: URL(fileURLWithPath: "/cache"), cacheWritable: true, restoreSupported: true) }
    func report() throws -> DoctorReport { reportValue }
}
private struct AppMockRestore: RestoreOperating { func events(for action: RestoreAction) -> AsyncThrowingStream<RestoreEvent, Error> { AsyncThrowingStream { $0.yield(.completed); $0.finish() } } }
private struct AppMockDFU: DFUOperating { func enterDFU(timeout: TimeInterval) throws {} }
private struct CancelledDFU: DFUOperating { func enterDFU(timeout: TimeInterval) throws { throw PrivilegedDFUClientError.authorizationCancelled } }
private final class AppMockLogger: @unchecked Sendable, OperationLogging {
    private let lock = NSLock(); private(set) var starts = 0; private(set) var lastECID: String?
    func start(operation: String, target: DFUDevice?, release: IPSWRelease?) throws -> URL { lock.withLock { starts += 1; lastECID = target?.ecid }; return URL(fileURLWithPath: "/tmp/mock-operation.log") }
    func append(_ message: String, to url: URL) throws {}
}
private let noOpLogger = AppMockLogger()

@MainActor private func model(service: AppMockService = AppMockService(), devices: [DFUDevice] = [], validator: AppMockValidator = AppMockValidator(valid: true), cache: IPSWCache = tempCache(), demo: Bool = false) -> AppModel {
    AppModel(ipswService: service, discovery: AppMockDiscovery(values: devices), cache: cache, validator: validator, diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, isDemoMode: demo)
}

@Test @MainActor func catalogueLoadsAndSelectsLatest() async {
    let app = model(service: AppMockService(releases: [makeRelease("15.7", "24A"), makeRelease("26.6.2", "25G83")]))
    await app.load(); #expect(app.catalogueState == .loaded); #expect(app.selectedRelease?.build == "25G83"); #expect(app.availableReleases.count == 2)
}

@Test @MainActor func selectingAnotherReleaseUpdatesSelection() async {
    let older = makeRelease("26.6", "25G70"), app = model(service: AppMockService(releases: [makeRelease(), older])); await app.load(); app.selectRelease(older); #expect(app.selectedRelease == older)
}

@Test @MainActor func cacheStatePropagatesToReady() async throws {
    let cache = tempCache(), value = makeRelease(); try cache.prepare(); let partial = cache.partialURL(for: value); try Data("x".utf8).write(to: partial); let ready = try cache.commit(partial: partial, release: value)
    let app = model(cache: cache); await app.load(); #expect(app.imageState == .ready(ready))
}

@Test @MainActor func downloadEventsUpdateProgressAndCompletion() async {
    let value = makeRelease(), events: [DownloadEvent] = [.started(release: value), .progress(completed: 50, total: 100, bytesPerSecond: 10), .validating, .completed(url: testURL)]
    let app = model(service: AppMockService(events: events)); await app.load(); await app.downloadSelected(); #expect(app.downloadState == .idle); #expect(app.imageState == .ready(testURL))
}

@Test @MainActor func downloadCancellationIsRecoverable() async {
    let app = model(service: AppMockService(events: [.started(release: makeRelease()), .cancelled])); await app.load(); await app.downloadSelected(); #expect(app.downloadState == .cancelled); #expect(app.imageURL == nil)
}

@Test @MainActor func activeDownloadTaskCancelsCleanly() async throws {
    let app = AppModel(ipswService: DemoIPSWService(), discovery: AppMockDiscovery(values: []), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, isDemoMode: true)
    await app.load(); app.beginDownload(); try await Task.sleep(for: .milliseconds(180)); app.cancelDownload(); try await Task.sleep(for: .milliseconds(180))
    #expect(app.downloadState == .cancelled); #expect(app.imageURL == nil)
}

@Test @MainActor func manualIPSWValidationSuccess() async {
    let app = model(); await app.validateManualIPSW(testURL); #expect(app.imageState == .ready(testURL)); #expect(app.selectedRelease == nil)
}

@Test @MainActor func manualIPSWValidationFailurePresentsError() async {
    let app = model(validator: AppMockValidator(valid: false)); await app.validateManualIPSW(testURL); if case .invalid = app.imageState {} else { Issue.record("Expected invalid image") }; #expect(app.presentedError?.contains("incomplete or invalid") == true)
}

@Test @MainActor func restoreDisabledWithoutDFU() async {
    let app = model(); await app.validateManualIPSW(testURL); #expect(!app.canRestore)
}

@Test @MainActor func restoreDisabledWithoutValidImage() {
    let app = model(devices: [DFUDevice(state: .dfu)]); #expect(!app.canRestore)
}

@Test @MainActor func restoreEnabledOnlyForRealDFUAndImage() async {
    let app = model(devices: [DFUDevice(state: .dfu)]); await app.refreshDiagnosticsAndTarget(); await app.validateManualIPSW(testURL); #expect(app.canRestore)
}

@Test @MainActor func demoDFUTargetCannotEnableRestore() async {
    let app = model(demo: true); app.setDemoTarget(.dfu); await app.validateManualIPSW(testURL); #expect(!app.canRestore); #expect(!app.canRevive); #expect(!app.canEnterDFU)
}

@Test @MainActor func doctorStatePropagates() async {
    let app = model(); await app.refreshDiagnosticsAndTarget(); #expect(app.doctorReport?.isFundamentallyUsable == true); #expect(!app.canEnterDFU)
}

@Test @MainActor func communityStartupDoesNotRequireOrQueryHelper() async {
    let app = AppModel(ipswService: AppMockService(), discovery: AppMockDiscovery(values: []), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, privilegeMode: .community)
    await app.refreshDiagnosticsAndTarget()
    #expect(app.privilegeMode == .community)
    #expect(app.privilegedHelperState == .notRegistered)
}

@Test @MainActor func catalogueErrorIsActionable() async {
    let app = model(service: AppMockService(failure: "offline")); await app.load(); if case .failed = app.catalogueState {} else { Issue.record("Expected failed catalogue") }; #expect(app.presentedError?.contains("could not be reached") == true)
}

@Test @MainActor func guiAuthorizationCancellationLeavesAppUsable() async {
    let target = DFUDevice(state: .normal, model: "Mac14,2", ecid: "0xABC")
    let app = AppModel(ipswService: AppMockService(), discovery: AppMockDiscovery(values: [target]), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: CancelledDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    await app.refreshDiagnosticsAndTarget(); #expect(app.canEnterDFU)
    await app.enterDFU()
    #expect(app.presentedError == "Administrator authorization was cancelled.")
    if case .failed = app.restoreState {} else { Issue.record("Expected recoverable failure state") }
}

@Test @MainActor func syntheticECIDCannotReachProductionOperationLog() async {
    let logger = AppMockLogger(), target = DFUDevice(state: .normal, model: "Mac14,2", ecid: "TEST")
    let app = AppModel(ipswService: AppMockService(), discovery: AppMockDiscovery(values: [target]), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: logger, requiresPrivilegedHelperSetup: false)
    await app.refreshDiagnosticsAndTarget(); #expect(!app.canEnterDFU); await app.enterDFU()
    #expect(logger.starts == 0); #expect(app.presentedError?.contains("synthetic test target") == true)
}

@Test @MainActor func realTargetECIDReachesOperationLog() async {
    let logger = AppMockLogger(), target = DFUDevice(state: .normal, model: "Mac14,2", ecid: "0x1569301A08C01E")
    let app = AppModel(ipswService: AppMockService(), discovery: AppMockDiscovery(values: [target]), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: logger, requiresPrivilegedHelperSetup: false)
    await app.refreshDiagnosticsAndTarget(); await app.enterDFU()
    #expect(logger.lastECID == "0x1569301A08C01E")
}

private struct SuccessfulPrivilegedRequest: PrivilegedDFURequesting { func enterDFU() throws {} }
private final class AppSequencedDiscovery: @unchecked Sendable, DeviceDiscovering {
    private let lock = NSLock(); private var values: [[DFUDevice]]
    init(_ values: [[DFUDevice]]) { self.values = values }
    func devices() throws -> [DFUDevice] { lock.withLock { values.count > 1 ? values.removeFirst() : (values.first ?? []) } }
}

@Test func privilegedGUIOperationVerifiesSameECID() throws {
    let normal = DFUDevice(state: .normal, model: "Mac14,2", ecid: "0xABC")
    let dfu = DFUDevice(state: .dfu, model: "Mac14,2", ecid: "0xabc")
    try PrivilegedDFUOperator(discovery: AppSequencedDiscovery([[normal], [dfu]]), client: SuccessfulPrivilegedRequest()).enterDFU(timeout: 1)
}

@Test func privilegedGUIOperationRejectsDifferentTarget() {
    let normal = DFUDevice(state: .normal, model: "Mac14,2", ecid: "0xABC")
    let other = DFUDevice(state: .dfu, model: "Mac14,2", ecid: "0xDEF")
    #expect(throws: DFUError.targetChanged(expected: "0xABC", actual: "0xDEF")) {
        try PrivilegedDFUOperator(discovery: AppSequencedDiscovery([[normal], [other]]), client: SuccessfulPrivilegedRequest()).enterDFU(timeout: 1)
    }
}

@Test func postOperationReconnectSuccessAndTimeout() async {
    let normal = DFUDevice(state: .normal, model: "Mac14,2", ecid: "TEST")
    #expect(await ReconnectVerifier(discovery: AppMockDiscovery(values: [normal])).wait(attempts: 1, interval: .zero) == .restarted(normal))
    #expect(await ReconnectVerifier(discovery: AppMockDiscovery(values: [])).wait(attempts: 1, interval: .zero) == .unverified)
}

@Test func operationProgressWaitingIsIndeterminate() {
    let state = OperationProgressReducer.reduce(.idle, event: .waitingForDevice, operation: "Restore")
    let value = OperationProgressPresentation(state: state, macOSVersion: "26.6.2")
    #expect(value.phase == .active); #expect(value.title == "Restoring macOS 26.6.2")
    #expect(value.stage == "Waiting for the device"); #expect(value.fraction == nil)
}

@Test func operationProgressNormalizesStageAndRetainsStepMetadata() {
    let state = OperationProgressReducer.reduce(.idle, event: .stageStarted(name: "Step 2 of 2: Installing System", index: 2, total: 2), operation: "Restore")
    let value = OperationProgressPresentation(state: state)
    #expect(value.stage == "Installing System — Step 2 of 2")
    #expect(value.fraction == nil)
}

@Test func operationProgressIsStageLocalClampedAndReset() {
    var state = OperationProgressReducer.reduce(.idle, event: .stageStarted(name: "Installing System", index: 1, total: 2), operation: "Restore")
    state = OperationProgressReducer.reduce(state, event: .progress(stage: "Installing System", fraction: 0.495), operation: "Restore")
    #expect(OperationProgressPresentation(state: state).fraction == 0.495)
    state = OperationProgressReducer.reduce(state, event: .stageStarted(name: "Finishing", index: 2, total: 2), operation: "Restore")
    #expect(OperationProgressPresentation(state: state).fraction == nil)
    state = OperationProgressReducer.reduce(state, event: .progress(stage: "Finishing", fraction: 4), operation: "Restore")
    #expect(OperationProgressPresentation(state: state).fraction == 1)
}

@Test func operationProgressSuppressesSentinelAndRawMessages() {
    var state = OperationProgressReducer.reduce(.idle, event: .stageStarted(name: "Unzipping System", index: nil, total: nil), operation: "Revive")
    let beforeMessage = state
    state = OperationProgressReducer.reduce(state, event: .message("cfgutil: revive: target OS is 26.6.2"), operation: "Revive")
    #expect(state == beforeMessage)
    state = OperationProgressReducer.reduce(state, event: .progress(stage: "Unzipping System", fraction: -1), operation: "Revive")
    #expect(OperationProgressPresentation(state: state).fraction == nil)
}

@Test func operationProgressReconnectCompletionAndFailureStates() {
    let reconnecting = OperationProgressPresentation(state: .reconnecting(operation: "Restore"))
    #expect(reconnecting.phase == .reconnecting); #expect(reconnecting.title == "Restore completed")
    let completed = OperationProgressPresentation(state: .completed("Restore completed successfully."))
    #expect(completed.phase == .completed); #expect(completed.message == "Restore completed successfully.")
    let failed = OperationProgressPresentation(state: .failed("Cable disconnected."))
    #expect(failed.phase == .failed); #expect(failed.message == "Cable disconnected.")
}

@Test func reviveAndRestoreShareProgressPresentationModel() {
    let restore = OperationProgressPresentation(state: .running(operation: "Restore", stage: "Installing System", stageIndex: nil, stageTotal: nil, fraction: 0.49), macOSVersion: "26.6.2")
    let revive = OperationProgressPresentation(state: .running(operation: "Revive", stage: "Unzipping System", stageIndex: nil, stageTotal: nil, fraction: 0.34))
    #expect(restore.title == "Restoring macOS 26.6.2"); #expect(restore.fraction == 0.49)
    #expect(revive.title == "Reviving Mac"); #expect(revive.fraction == 0.34)
}
