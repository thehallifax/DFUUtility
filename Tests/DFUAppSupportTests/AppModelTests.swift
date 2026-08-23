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
private final class TrackingIPSWService: @unchecked Sendable, IPSWService {
    private let lock = NSLock()
    let releases: [IPSWRelease], events: [DownloadEvent]
    private(set) var eventRequests = 0
    init(releases: [IPSWRelease], events: [DownloadEvent] = []) { self.releases = releases; self.events = events }
    func availableImages(for device: DFUDevice?) async throws -> [IPSWRelease] { AppleIPSWService.sortNewestFirst(releases) }
    func recommendedImage(for device: DFUDevice?) async throws -> IPSWRelease { releases[0] }
    func download(_ release: IPSWRelease, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL { testURL }
    func downloadEvents(_ release: IPSWRelease) -> AsyncThrowingStream<DownloadEvent, Error> {
        lock.withLock { eventRequests += 1 }
        return AsyncThrowingStream { continuation in events.forEach { continuation.yield($0) }; continuation.finish() }
    }
}
private final class TargetAwareIPSWService: @unchecked Sendable, IPSWService {
    private let lock = NSLock()
    let phoneRelease: IPSWRelease
    let padRelease: IPSWRelease
    private var requestedFamilies: [AppleDeviceFamily] = []
    init(phoneRelease: IPSWRelease, padRelease: IPSWRelease) { self.phoneRelease = phoneRelease; self.padRelease = padRelease }
    func availableImages(for device: DFUDevice?) async throws -> [IPSWRelease] {
        lock.withLock { requestedFamilies.append(device?.family ?? .unknown) }
        return switch device?.family { case .iPhone: [phoneRelease]; case .iPad: [padRelease]; default: [] }
    }
    func recommendedImage(for device: DFUDevice?) async throws -> IPSWRelease { try await availableImages(for: device).first! }
    func download(_ release: IPSWRelease, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL { testURL }
    var families: [AppleDeviceFamily] { lock.withLock { requestedFamilies } }
}
private struct DelayedDownloadService: IPSWService {
    let release: IPSWRelease
    func availableImages(for device: DFUDevice?) async throws -> [IPSWRelease] { [release] }
    func recommendedImage(for device: DFUDevice?) async throws -> IPSWRelease { release }
    func download(_ release: IPSWRelease, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL { testURL }
    func downloadEvents(_ release: IPSWRelease) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.started(release: release)); continuation.yield(.progress(completed: 50, total: 100, bytesPerSecond: 20))
                try? await Task.sleep(for: .milliseconds(250)); continuation.yield(.validating)
                try? await Task.sleep(for: .milliseconds(50)); continuation.yield(.completed(url: testURL)); continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
private struct AppMockDiscovery: DeviceDiscovering { let values: [DFUDevice]; func devices() throws -> [DFUDevice] { values } }
private struct AppMockValidator: IPSWValidating { let valid: Bool; func validate(_ url: URL, release: IPSWRelease?, verifyChecksum: Bool) throws { if !valid { throw DFUError.invalidIPSW("mock invalid") } } }
private struct AppMockDiagnostics: DiagnosticsProviding {
    let reportValue: DoctorReport
    init(macVDM: Bool = true) { reportValue = DoctorReport(status: UtilityStatus(host: HostStatus(isAppleSilicon: true, macOSVersion: "26.6.1", macVDMToolPath: macVDM ? URL(fileURLWithPath: "/macvdmtool") : nil, cfgutilPath: URL(fileURLWithPath: "/cfgutil")), targets: []), configuratorPresent: true, cacheDirectory: URL(fileURLWithPath: "/cache"), cacheWritable: true, restoreSupported: true) }
    func report() throws -> DoctorReport { reportValue }
}
private final class CapturingTargetDiagnostics: @unchecked Sendable, DiagnosticsProviding {
    private let lock = NSLock(); private(set) var receivedTargets: [DFUDevice] = []
    func report() throws -> DoctorReport { makeReport(targets: []) }
    func report(targets: [DFUDevice]) throws -> DoctorReport { lock.withLock { receivedTargets = targets }; return makeReport(targets: targets) }
    private func makeReport(targets: [DFUDevice]) -> DoctorReport { DoctorReport(status: UtilityStatus(host: HostStatus(isAppleSilicon: true, macOSVersion: "Test", cfgutilPath: URL(fileURLWithPath: "/cfgutil")), targets: targets), configuratorPresent: true, cacheDirectory: URL(fileURLWithPath: "/cache"), cacheWritable: true, restoreSupported: true) }
}
private final class CountingAppDiscovery: @unchecked Sendable, DeviceDiscovering {
    private let lock = NSLock(); let values: [DFUDevice]; private(set) var calls = 0
    init(_ values: [DFUDevice]) { self.values = values }
    func devices() throws -> [DFUDevice] { lock.withLock { calls += 1; return values } }
    var callCount: Int { lock.withLock { calls } }
}
private struct AppMockRestore: RestoreOperating { func events(for action: RestoreAction) -> AsyncThrowingStream<RestoreEvent, Error> { AsyncThrowingStream { $0.yield(.completed); $0.finish() } } }
private final class CountingRestore: @unchecked Sendable, RestoreOperating {
    private let lock = NSLock(); private(set) var calls = 0
    func events(for action: RestoreAction) -> AsyncThrowingStream<RestoreEvent, Error> { lock.withLock { calls += 1 }; return AsyncThrowingStream { $0.finish() } }
    var callCount: Int { lock.withLock { calls } }
}
private struct HoldingRestore: RestoreOperating {
    func events(for action: RestoreAction) -> AsyncThrowingStream<RestoreEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { continuation.yield(.preparing); try? await Task.sleep(for: .seconds(10)); continuation.finish() }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
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

@Test @MainActor func chooserLoadsSortedRecommendedReleaseWithoutDownloading() async {
    let latest = makeRelease("26.6.2", "25G83"), older = makeRelease("26.6", "25G70")
    let service = TrackingIPSWService(releases: [older, latest]), app = AppModel(ipswService: service, discovery: AppMockDiscovery(values: []), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    await app.load()
    #expect(app.imageChoices.map(\.release.build) == ["25G83", "25G70"])
    #expect(app.imageChoices.first?.isRecommended == true); #expect(app.selectedRelease == latest)
    app.beginChoosingVersion(); app.choosePendingRelease(older)
    #expect(app.selectedRelease == latest); #expect(service.eventRequests == 0)
    app.confirmPendingRelease()
    #expect(app.selectedRelease == older); #expect(service.eventRequests == 0); #expect(app.restoreState == .idle)
}

@Test @MainActor func chooserReportsDownloadedRequiredAndPartialCacheStates() async throws {
    let downloaded = makeRelease("26.6.2", "25G83"), partial = makeRelease("26.6.1", "25G76"), required = makeRelease("26.6", "25G70")
    let cache = tempCache(); try cache.prepare()
    let staged = cache.partialURL(for: downloaded); try Data("valid".utf8).write(to: staged); _ = try cache.commit(partial: staged, release: downloaded)
    try Data("partial bytes".utf8).write(to: cache.partialURL(for: partial))
    let app = model(service: AppMockService(releases: [required, partial, downloaded]), cache: cache)
    await app.load()
    #expect(app.choice(for: downloaded)?.cacheState == .downloaded(cache.destination(for: downloaded)))
    #expect(app.choice(for: partial)?.cacheState == .partial(13))
    #expect(app.choice(for: required)?.cacheState == .downloadRequired)
    #expect(app.choice(for: downloaded)?.compatibility == .universalAppleSilicon)
}

@Test @MainActor func chooserUsesCatalogueCompatibilityWithoutFabricatingMatches() async {
    let compatible = IPSWRelease(version: "26.6.2", build: "MATCH", downloadURL: URL(string: "https://updates.cdn-apple.com/match.ipsw")!, supportedDevices: ["Mac14,2"])
    let other = IPSWRelease(version: "26.6.1", build: "OTHER", downloadURL: URL(string: "https://updates.cdn-apple.com/other.ipsw")!, supportedDevices: ["Mac15,3"])
    let target = DFUDevice(state: .normal, model: "Mac14,2", ecid: "0xABC")
    let app = model(service: AppMockService(releases: [other, compatible]), devices: [target])
    await app.load()
    #expect(app.imageChoices.map(\.release.build) == ["MATCH"])
    #expect(app.imageChoices.first?.compatibility == .compatible(model: "Mac14,2"))
}

@Test @MainActor func liveDownloadProgressIsVisibleBeforeValidation() async throws {
    let release = makeRelease(), app = AppModel(ipswService: DelayedDownloadService(release: release), discovery: AppMockDiscovery(values: []), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    await app.load(); app.beginDownload(); try await Task.sleep(for: .milliseconds(40))
    #expect(app.downloadPresentation?.fraction == 0.5); #expect(app.downloadPresentation?.bytesPerSecond == 20)
    try await Task.sleep(for: .milliseconds(320)); #expect(app.imageState == .ready(testURL))
}

@Test @MainActor func windowConfigurationHasStableSensibleDefaultAndMinimum() {
    let value = MainWindowConfiguration.standard
    #expect(value.defaultWidth == 1040); #expect(value.defaultHeight == 800)
    #expect(value.minimumWidth == 820); #expect(value.minimumHeight == 680)
    #expect(value.defaultWidth > value.minimumWidth); #expect(value.defaultHeight > value.minimumHeight)
}

@Test @MainActor func knownAndUnknownDownloadsHaveExplicitInitialPresentation() async {
    let known = makeRelease(), knownApp = model(service: AppMockService(releases: [known], events: [.started(release: known)]))
    await knownApp.load(); await knownApp.downloadSelected()
    #expect(knownApp.downloadPresentationState.isDeterminate); #expect(knownApp.downloadPresentationState.progress?.fraction == 0)
    let unknown = IPSWRelease(version: "26.6.2", build: "UNKNOWN-SIZE", downloadURL: URL(string: "https://updates.cdn-apple.com/unknown.ipsw")!)
    let unknownApp = model(service: AppMockService(releases: [unknown], events: [.started(release: unknown)]))
    await unknownApp.load(); await unknownApp.downloadSelected()
    #expect(!unknownApp.downloadPresentationState.isDeterminate); #expect(unknownApp.downloadPresentationState.progress?.fraction == nil)
}

@Test @MainActor func resumedDownloadStartsAtKnownPartialFractionAndValidationIsSeparate() async {
    let value = makeRelease(), cache = tempCache(); try? cache.prepare(for: value); try? Data(repeating: 1, count: 25).write(to: cache.partialURL(for: value))
    let resumed = model(service: AppMockService(releases: [value], events: [.started(release: value)]), cache: cache)
    await resumed.load(); await resumed.downloadSelected()
    #expect(resumed.downloadPresentationState.progress?.fraction == 0.25)
    let validating = model(service: AppMockService(releases: [value], events: [.started(release: value), .validating]))
    await validating.load(); await validating.downloadSelected()
    #expect(validating.downloadPresentationState == .validating); #expect(validating.downloadPresentationState.progress == nil)
}

@Test @MainActor func removingSelectedManagedImageInvalidatesMainCardAndRefreshesManager() async throws {
    let value = makeRelease(), cache = tempCache(); try cache.prepare(for: value); try Data("valid".utf8).write(to: cache.partialURL(for: value)); let ready = try cache.commit(partial: cache.partialURL(for: value), release: value)
    let app = model(service: AppMockService(releases: [value]), cache: cache); await app.load(); await app.refreshManagedCache()
    #expect(app.imageURL == ready); let entry = try #require(app.managedCacheEntries.first)
    await app.removeManagedCacheEntry(entry)
    #expect(app.imageURL == nil); #expect(app.imageState == .none); #expect(app.managedCacheEntries.isEmpty); #expect(!app.canRestore)
}

@Test @MainActor func activeDownloadCannotRemoveItsManagedPartialAndRevealTargetsAreExact() async throws {
    let value = makeRelease(), cache = tempCache(); try cache.prepare(for: value); try Data("partial".utf8).write(to: cache.partialURL(for: value))
    let app = AppModel(ipswService: DelayedDownloadService(release: value), discovery: AppMockDiscovery(values: []), cache: cache, validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    await app.load(); await app.refreshManagedCache(); let entry = try #require(app.managedCacheEntries.first)
    #expect(app.cacheRevealURL(for: entry) == entry.url); #expect(app.managedCacheDirectoryURL == cache.directory)
    app.beginDownload(); try await Task.sleep(for: .milliseconds(30))
    #expect(app.cacheRemovalDisabledReason(for: entry)?.contains("downloading") == true)
    app.cancelDownload()
}

@Test @MainActor func validatingAndActiveRestoreImagesCannotBeRemoved() async throws {
    let partialRelease = makeRelease(), partialCache = tempCache(); try partialCache.prepare(for: partialRelease); try Data("partial".utf8).write(to: partialCache.partialURL(for: partialRelease))
    let validating = model(service: AppMockService(releases: [partialRelease], events: [.started(release: partialRelease), .validating]), cache: partialCache)
    await validating.load(); await validating.refreshManagedCache(); let partial = try #require(validating.managedCacheEntries.first); await validating.downloadSelected()
    #expect(validating.cacheRemovalDisabledReason(for: partial)?.contains("validated") == true)

    let release = IPSWRelease(version: "26.6.2", build: "RESTORE-IN-USE", downloadURL: URL(string: "https://updates.cdn-apple.com/restore.ipsw")!, supportedDevices: ["Mac14,2"])
    let cache = tempCache(); try cache.prepare(for: release); try Data("valid".utf8).write(to: cache.partialURL(for: release)); _ = try cache.commit(partial: cache.partialURL(for: release), release: release)
    let target = DFUDevice(state: .dfu, model: "Mac14,2", ecid: "0xSAFE")
    let app = AppModel(ipswService: AppMockService(releases: [release]), discovery: AppMockDiscovery(values: [target]), cache: cache, validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: HoldingRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    await app.load(); await app.refreshManagedCache(); let entry = try #require(app.managedCacheEntries.first); app.restoreConfirmed()
    #expect(await waitForRestoreState(app) { if case .running = $0 { true } else { false } })
    #expect(app.cacheRemovalDisabledReason(for: entry)?.contains("in use") == true)
}

@Test @MainActor func cacheManagementRemovalCannotTriggerDeviceOperation() async throws {
    let value = makeRelease(), cache = tempCache(); try cache.prepare(for: value); try Data("partial".utf8).write(to: cache.partialURL(for: value))
    let restore = CountingRestore()
    let app = AppModel(ipswService: AppMockService(releases: [value]), discovery: AppMockDiscovery(values: []), cache: cache, validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: restore, dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    await app.load(); await app.refreshManagedCache(); let entry = try #require(app.managedCacheEntries.first); await app.removeManagedCacheEntry(entry)
    #expect(restore.callCount == 0); #expect(app.managedCacheEntries.isEmpty)
}

@Test @MainActor func cancelledDownloadReturnsToResumablePartialState() async throws {
    let release = makeRelease(), cache = tempCache(); try cache.prepare(); try Data("resume".utf8).write(to: cache.partialURL(for: release))
    let app = model(service: AppMockService(releases: [release], events: [.started(release: release), .resumed(existingBytes: 6), .cancelled]), cache: cache)
    await app.load(); await app.downloadSelected()
    #expect(app.downloadState == .cancelled); #expect(app.imageState == .partial(6)); #expect(app.choice(for: release)?.cacheState == .partial(6))
}

@Test @MainActor func downloadActionUsesExistingEventPipelineOnlyWhenRequested() async throws {
    let release = makeRelease(), service = TrackingIPSWService(releases: [release], events: [.started(release: release), .progress(completed: 40, total: 100, bytesPerSecond: 12), .validating, .completed(url: testURL)])
    let app = AppModel(ipswService: service, discovery: AppMockDiscovery(values: []), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    await app.load(); #expect(service.eventRequests == 0)
    app.beginDownload(); try await Task.sleep(for: .milliseconds(50))
    #expect(service.eventRequests == 1); #expect(app.imageState == .ready(testURL)); #expect(app.downloadState == .idle)
}

@Test @MainActor func offlineCatalogueRetainsValidatedCachedImage() async throws {
    let release = makeRelease(), cache = tempCache(); try cache.prepare()
    let staged = cache.partialURL(for: release); try Data("valid".utf8).write(to: staged); let ready = try cache.commit(partial: staged, release: release)
    let app = model(service: AppMockService(releases: [], failure: "offline"), cache: cache)
    await app.load()
    #expect(app.catalogueErrorMessage?.contains("could not be reached") == true)
    #expect(app.selectedRelease == release); #expect(app.imageState == .ready(ready)); #expect(app.canRestore == false)
}

@Test @MainActor func invalidCachedImageIsNotReady() async throws {
    let release = makeRelease(), cache = tempCache(); try cache.prepare()
    let staged = cache.partialURL(for: release); try Data("bad".utf8).write(to: staged); _ = try cache.commit(partial: staged, release: release)
    let app = model(service: AppMockService(releases: [release]), validator: AppMockValidator(valid: false), cache: cache)
    await app.load()
    #expect(app.choice(for: release)?.cacheState == .invalid); #expect(app.imageURL == nil); #expect(!app.canRestore)
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

@Test @MainActor func mobileTargetsNeverOfferAutomaticDFUAndReviveRequiresRecovery() async {
    let normalPhone = DFUDevice(family: .iPhone, state: .normal, ecid: "PHONE", productType: "iPhone15,2")
    let phone = model(devices: [normalPhone]); await phone.refreshDiagnosticsAndTarget()
    #expect(!phone.canEnterDFU); #expect(!phone.canRevive)
    let recoveryPad = model(devices: [DFUDevice(family: .iPad, state: .recovery, ecid: "PAD", productType: "iPad13,18")]); await recoveryPad.refreshDiagnosticsAndTarget()
    #expect(!recoveryPad.canEnterDFU); #expect(recoveryPad.canRevive)
}

@Test @MainActor func launchPromotesSingleIPhoneWithoutFamilyFiltering() async {
    let phone = DFUDevice(family: .iPhone, state: .normal, model: "iPhone7,2", identifier: "SYNTHETIC-UDID", ecid: "0xABC", productType: "iPhone7,2", serialNumber: "SYNTHETIC-SERIAL")
    let app = model(devices: [phone]); await app.load()
    #expect(app.targetDevices == [phone]); #expect(app.target == phone); #expect(app.selectedTargetECID == "0xABC")
    #expect(app.canUseMobileDFUAssistant); #expect(!app.canEnterDFU)
}

@Test @MainActor func launchPromotesSingleIPadWithoutFamilyFiltering() async {
    let pad = DFUDevice(family: .iPad, state: .normal, ecid: "0xPAD", productType: "iPad13,18")
    let app = model(devices: [pad]); await app.load()
    #expect(app.targetDevices == [pad]); #expect(app.target == pad); #expect(app.selectedTargetECID == "0xPAD")
}

@Test @MainActor func iPad711NormalAndRecoveryExposeExistingGuidedAssistant() async {
    for state in [DeviceState.normal, .recovery] {
        let pad = DFUDevice(family: .iPad, state: state, ecid: "0xPAD", productType: "iPad7,11")
        let app = model(devices: [pad]); await app.load()
        #expect(app.target == pad); #expect(app.canUseMobileDFUAssistant); #expect(app.prepareMobileDFUAssistant())
        #expect(app.mobileDFUAssistant?.profile == .iPad7thGeneration); #expect(!app.canEnterDFU)
        app.dismissMobileDFUAssistant()
    }
}

@Test @MainActor func packagedProductionShapeIPad711EnablesPhysicalButtonAssistantWithoutMacGuidance() async {
    let release = IPSWRelease(platform: .iPadOS, version: "18.7.10", build: "22H374", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad.ipsw")!, supportedDevices: ["iPad7,11"])
    let pad = DFUDevice(
        family: .iPad,
        state: .normal,
        model: "iPad7,11",
        identifier: "SYNTHETIC-IPAD-UDID",
        ecid: "0x5A17E711",
        productType: "iPad7,11",
        modelIdentifier: "iPad7,11",
        serialNumber: "SYNTHETIC-IPAD-SERIAL"
    )
    let app = AppModel(ipswService: AppMockService(releases: [release]), discovery: AppMockDiscovery(values: [pad]), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, privilegeMode: .community, targetDiscoveryAttempts: 3)
    await app.load()

    #expect(app.target == pad)
    #expect(app.canUseMobileDFUAssistant)
    #expect(!app.canEnterDFU)
    #expect(app.targetDFUGuidance == .guidedPhysicalButtons)
    #expect(app.restoreSectionTitle == "iPadOS Restore")
    #expect(app.selectedRelease?.platform == .iPadOS)
    #expect(app.prepareMobileDFUAssistant())
    #expect(app.mobileDFUAssistant?.profile.productType == "iPad7,11")
    #expect(app.mobileDFUAssistant?.profile.powerButtonName == "Top")
    #expect(app.mobileDFUAssistant?.profile.secondaryButtonName == "Home")
    app.dismissMobileDFUAssistant()
}

@Test @MainActor func switchingIPhoneAndIPadInvalidatesAndReloadsTargetSpecificPlatformState() async {
    let phoneRelease = IPSWRelease(platform: .iOS, version: "12.5.8", build: "16H81", downloadURL: URL(string: "https://updates.cdn-apple.com/iphone.ipsw")!, supportedDevices: ["iPhone7,2"])
    let padRelease = IPSWRelease(platform: .iPadOS, version: "18.7.10", build: "22H374", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad.ipsw")!, supportedDevices: ["iPad7,11"])
    let phone = DFUDevice(family: .iPhone, state: .normal, ecid: "0xPHONE", productType: "iPhone7,2")
    let pad = DFUDevice(family: .iPad, state: .normal, ecid: "0xPAD", productType: "iPad7,11")
    let service = TargetAwareIPSWService(phoneRelease: phoneRelease, padRelease: padRelease)
    let discovery = AppSequencedDiscovery([[phone], [pad], [phone]])
    let app = AppModel(ipswService: service, discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, privilegeMode: .community)

    await app.load()
    #expect(app.target?.family == .iPhone); #expect(app.selectedRelease == phoneRelease); #expect(app.restoreSectionTitle == "iOS Restore")
    await app.refreshDiagnosticsAndTarget()
    #expect(app.target?.family == .iPad); #expect(app.selectedRelease == padRelease); #expect(app.restoreSectionTitle == "iPadOS Restore")
    #expect(app.canUseMobileDFUAssistant); #expect(app.targetDFUGuidance == .guidedPhysicalButtons)
    await app.refreshDiagnosticsAndTarget()
    #expect(app.target?.family == .iPhone); #expect(app.selectedRelease == phoneRelease); #expect(app.restoreSectionTitle == "iOS Restore")
    #expect(service.families == [.iPhone, .iPad, .iPhone])
}

@Test func deviceFamilyIsTheSharedRestorePlatformMapping() {
    #expect(AppleDeviceFamily.mac.restorePlatform == .macOS)
    #expect(AppleDeviceFamily.iPhone.restorePlatform == .iOS)
    #expect(AppleDeviceFamily.iPad.restorePlatform == .iPadOS)
}

@Test @MainActor func iPad711CatalogueSelectionAndWrongProductRestoreRemainGated() async throws {
    let compatible = IPSWRelease(platform: .iPadOS, version: "18.7.10", build: "22H374", downloadURL: URL(string: "https://updates.cdn-apple.com/pad.ipsw")!, supportedDevices: ["iPad7,11"])
    let wrong = IPSWRelease(platform: .iPadOS, version: "18.7.10", build: "WRONG", downloadURL: URL(string: "https://updates.cdn-apple.com/wrong-pad.ipsw")!, supportedDevices: ["iPad7,12"])
    let cache = tempCache(); try cache.prepare(for: compatible); let partial = cache.partialURL(for: compatible); try Data("valid".utf8).write(to: partial); _ = try cache.commit(partial: partial, release: compatible)
    let target = DFUDevice(family: .iPad, state: .dfu, ecid: "0xPAD", productType: "iPad7,11")
    let app = model(service: AppMockService(releases: [wrong, compatible]), devices: [target], cache: cache); await app.load()
    #expect(app.imageChoices.map(\.release.build) == ["22H374"]); #expect(app.selectedRelease == compatible); #expect(app.canRestore)
    let wrongOnly = model(service: AppMockService(releases: [wrong]), devices: [target], cache: cache); await wrongOnly.load()
    #expect(wrongOnly.imageChoices.isEmpty); #expect(!wrongOnly.canRestore)
}

@Test @MainActor func launchStillPromotesSingleMac() async {
    let mac = DFUDevice(family: .mac, state: .normal, ecid: "0xMAC", productType: "Mac14,2")
    let app = model(devices: [mac]); await app.load()
    #expect(app.targetDevices == [mac]); #expect(app.target == mac); #expect(app.selectedTargetECID == "0xMAC")
}

@Test @MainActor func refreshUpdatesStateThenClearsDisappearedTarget() async {
    let normal = DFUDevice(family: .iPhone, state: .normal, ecid: "0xABC", productType: "iPhone7,2")
    let recovery = DFUDevice(family: .iPhone, state: .recovery, ecid: "0xABC", productType: "iPhone7,2")
    let discovery = AppSequencedDiscovery([[normal], [recovery], []])
    let app = AppModel(ipswService: AppMockService(), discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    await app.refreshDiagnosticsAndTarget(); #expect(app.target?.state == .normal)
    await app.refreshDiagnosticsAndTarget(); #expect(app.target?.state == .recovery); #expect(app.selectedTargetECID == "0xABC")
    await app.refreshDiagnosticsAndTarget(); #expect(app.targetDevices.isEmpty); #expect(app.target == nil); #expect(app.selectedTargetECID == nil)
}

@Test @MainActor func guiUsesOneGeneralizedDiscoverySnapshotForCardAndDiagnostics() async {
    let phone = DFUDevice(family: .iPhone, state: .normal, ecid: "0xABC", productType: "iPhone7,2")
    let discovery = CountingAppDiscovery([phone]), diagnostics = CapturingTargetDiagnostics()
    let app = AppModel(ipswService: AppMockService(), discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: diagnostics, restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    await app.refreshDiagnosticsAndTarget()
    #expect(discovery.callCount == 1); #expect(app.targetDevices == [phone]); #expect(diagnostics.receivedTargets == [phone]); #expect(app.doctorReport?.status.targets == [phone])
}

@Test @MainActor func packagedLaunchRetriesAnInitialEmptyTargetSnapshot() async {
    let phone = DFUDevice(family: .iPhone, state: .normal, ecid: "0xABC", productType: "iPhone7,2")
    let discovery = AppSequencedDiscovery([[], [phone]])
    let app = AppModel(ipswService: AppMockService(), discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, targetDiscoveryAttempts: 3)
    await app.refreshDiagnosticsAndTarget()
    #expect(app.target == phone); #expect(app.selectedTargetECID == "0xABC"); #expect(app.doctorReport?.status.targets == [phone])
}

@Test @MainActor func demoLoadAndRefreshNeverInvokeInjectedHardwareDiscovery() async {
    let discovery = CountingAppDiscovery([DFUDevice(family: .iPhone, state: .normal, ecid: "REAL", productType: "iPhone7,2")])
    let app = AppModel(ipswService: AppMockService(), discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, isDemoMode: true)
    await app.load(); await app.refreshDiagnosticsAndTarget()
    #expect(discovery.callCount == 0); #expect(app.targetDevices.isEmpty)
}

@Test @MainActor func guidedMobileDFUDetectionUpdatesMainTargetWithoutStartingAnOperation() async {
    let normal = DFUDevice(family: .iPhone, state: .normal, ecid: "0xABC", productType: "iPhone7,2")
    let dfu = DFUDevice(family: .iPhone, state: .dfu, ecid: "0xabc", productType: "iPhone7,2")
    let logger = AppMockLogger(), app = AppModel(ipswService: AppMockService(), discovery: AppMockDiscovery(values: [normal]), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: logger, requiresPrivilegedHelperSetup: false)
    await app.refreshDiagnosticsAndTarget()
    #expect(app.canUseMobileDFUAssistant); #expect(app.prepareMobileDFUAssistant())
    app.mobileDFUAssistant?.activate(); app.mobileDFUAssistant?.start(); app.mobileDFUAssistant?.consume(devices: [dfu])
    #expect(app.target?.state == .dfu); #expect(app.target?.ecid == "0xabc")
    #expect(app.restoreState == .idle); #expect(logger.starts == 1)
    app.dismissMobileDFUAssistant()
}

@Test @MainActor func mobileRestoreRequiresMatchingProductAndDFUState() async throws {
    let compatible = IPSWRelease(platform: .iOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/phone.ipsw")!, supportedDevices: ["iPhone15,2"])
    let wrong = IPSWRelease(platform: .iOS, version: "26.6.1", build: "23G84", downloadURL: URL(string: "https://updates.cdn-apple.com/wrong.ipsw")!, supportedDevices: ["iPhone16,1"])
    let target = DFUDevice(family: .iPhone, state: .dfu, ecid: "PHONE", productType: "iPhone15,2")
    let cache = tempCache(); try cache.prepare(for: compatible); let partial = cache.partialURL(for: compatible); try Data("valid".utf8).write(to: partial); _ = try cache.commit(partial: partial, release: compatible)
    let app = model(service: AppMockService(releases: [wrong, compatible]), devices: [target], cache: cache); await app.load()
    #expect(app.imageChoices.map(\.release.build) == ["23G83"]); #expect(app.canRestore)
    let normal = model(service: AppMockService(releases: [compatible]), devices: [DFUDevice(family: .iPhone, state: .normal, ecid: "PHONE", productType: "iPhone15,2")], cache: cache); await normal.load(); #expect(!normal.canRestore)
}

@Test @MainActor func multipleTargetsRequireExplicitECIDSelection() async {
    let devices = [DFUDevice(family: .mac, state: .dfu, ecid: "MAC", productType: "Mac14,2"), DFUDevice(family: .iPad, state: .dfu, ecid: "PAD", productType: "iPad13,18")]
    let app = model(devices: devices); await app.refreshDiagnosticsAndTarget(); #expect(app.target == nil)
    app.selectTarget(ecid: "PAD"); #expect(app.target?.family == .iPad); #expect(app.selectedTargetECID == "PAD")
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
    let app = model(service: AppMockService(failure: "offline")); await app.load(); if case .failed = app.catalogueState {} else { Issue.record("Expected failed catalogue") }; #expect(app.presentedError?.contains("Unable to load Apple restore images") == true); #expect(app.catalogueErrorMessage?.contains("could not be reached") == true)
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
    let logger = AppMockLogger(), target = DFUDevice(state: .normal, model: "Mac14,2", ecid: "0xABCDEF123456")
    let app = AppModel(ipswService: AppMockService(), discovery: AppMockDiscovery(values: [target]), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: logger, requiresPrivilegedHelperSetup: false)
    await app.refreshDiagnosticsAndTarget(); await app.enterDFU()
    #expect(logger.lastECID == "0xABCDEF123456")
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
    let other = DFUDevice(family: .iPhone, state: .normal, ecid: "OTHER", productType: "iPhone15,2")
    #expect(await ReconnectVerifier(discovery: AppMockDiscovery(values: [other, normal])).wait(expectedECID: "TEST", attempts: 1, interval: .zero) == .restarted(normal))
    #expect(await ReconnectVerifier(discovery: AppMockDiscovery(values: [])).wait(attempts: 1, interval: .zero) == .unverified)
}

@Test func operationProgressWaitingIsIndeterminate() {
    let state = OperationProgressReducer.reduce(.idle, event: .waitingForDevice, operation: "Restore")
    let value = OperationProgressPresentation(state: state, macOSVersion: "26.6.2")
    #expect(value.phase == .active); #expect(value.title == "Restoring macOS 26.6.2")
    #expect(value.stage == "Waiting for the device"); #expect(value.fraction == nil)
}

@Test func disconnectWarningsAreDeviceAware() {
    #expect(TargetPresentation.disconnectWarning(for: DFUDevice(family: .mac, state: .dfu)) == "Do not disconnect the target Mac.")
    #expect(TargetPresentation.disconnectWarning(for: DFUDevice(family: .iPhone, state: .dfu)) == "Do not disconnect the iPhone.")
    #expect(TargetPresentation.disconnectWarning(for: DFUDevice(family: .iPad, state: .dfu)) == "Do not disconnect the iPad.")
}

@Test @MainActor func cachedFileSizeFillsMissingCatalogueSizeButNeverOverridesIt() async throws {
    let unknown = IPSWRelease(platform: .iOS, version: "12.5.8", build: "A", downloadURL: URL(string: "https://updates.cdn-apple.com/a.ipsw")!, supportedDevices: ["iPhone7,2"])
    let known = IPSWRelease(platform: .iOS, version: "12.5.8", build: "B", downloadURL: URL(string: "https://updates.cdn-apple.com/b.ipsw")!, fileSize: 99, supportedDevices: ["iPhone7,2"])
    let cache = tempCache(); try cache.prepare(for: unknown); try cache.prepare(for: known)
    let unknownPartial = cache.partialURL(for: unknown); try Data(repeating: 1, count: 23).write(to: unknownPartial); _ = try cache.commit(partial: unknownPartial, release: unknown)
    let knownPartial = cache.partialURL(for: known); try Data(repeating: 1, count: 17).write(to: knownPartial); _ = try cache.commit(partial: knownPartial, release: known)
    let target = DFUDevice(family: .iPhone, state: .normal, ecid: "0xABC", productType: "iPhone7,2")
    let app = model(service: AppMockService(releases: [unknown, known]), devices: [target], cache: cache); await app.load()
    #expect(app.displaySize(for: unknown) == 23); #expect(app.displaySize(for: known) == 99)
    app.selectRelease(unknown); #expect(app.selectedImageDisplaySize == 23)
}

@Test @MainActor func successfulMobileReconnectRestoresPhysicalStateMetadataAndGuidedProfile() async throws {
    let release = IPSWRelease(platform: .iOS, version: "12.5.8", build: "16H81", downloadURL: URL(string: "https://updates.cdn-apple.com/phone.ipsw")!, supportedDevices: ["iPhone7,2"])
    let cache = tempCache(); try cache.prepare(for: release); let partial = cache.partialURL(for: release); try Data("valid".utf8).write(to: partial); _ = try cache.commit(partial: partial, release: release)
    let dfu = DFUDevice(family: .iPhone, state: .dfu, model: "iPhone7,2", ecid: "0xABC", productType: "iPhone7,2")
    let sparseNormal = DFUDevice(family: .iPhone, state: .normal, ecid: "0xabc")
    let discovery = AppSequencedDiscovery([[dfu], [sparseNormal]])
    let app = AppModel(ipswService: AppMockService(releases: [release]), discovery: discovery, cache: cache, validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    await app.load(); #expect(app.canRestore); app.restoreConfirmed()
    #expect(await waitForRestoreState(app) { if case .completed = $0 { true } else { false } })
    #expect(app.targetWorkflowState == .normal); #expect(app.target?.state == .normal)
    #expect(app.target?.restoreProductType == "iPhone7,2"); #expect(app.canUseMobileDFUAssistant)
    if case .completed(let message) = app.restoreState { #expect(message.contains("Target restarted")) } else { Issue.record("Expected independent completion presentation") }
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

@Test func mobileProgressUsesSharedPlatformAwarePresentation() {
    let restore = OperationProgressPresentation(state: .running(operation: "Restore", stage: "Installing System", stageIndex: 2, stageTotal: 3, fraction: 0.4), macOSVersion: "26.6.1", platform: .iOS)
    let revive = OperationProgressPresentation(state: .running(operation: "Revive", stage: "Unzipping System", stageIndex: nil, stageTotal: nil, fraction: nil), platform: .iPadOS)
    #expect(restore.title == "Restoring iOS 26.6.1"); #expect(restore.fraction == 0.4)
    #expect(revive.title == "Reviving iPad"); #expect(revive.fraction == nil)
}

@MainActor private func waitForRestoreState(_ app: AppModel, timeout: TimeInterval = 2, matching predicate: (AppRestoreState) -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate(app.restoreState) { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return predicate(app.restoreState)
}

@Test @MainActor func liveProcessChunksReachAppModelBeforeProcessCompletion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("fixture-cfgutil")
    let script = #"""
    #!/bin/sh
    sleep 0.30
    printf 'Step = "Wait'
    sleep 0.05
    printf 'ing for the device [1/4]";\nTy'
    sleep 0.05
    printf 'pe = Step;\n'
    sleep 0.30
    printf 'Step = "Step 3 of 4: Unzipping System";\nType = Step;\n'
    sleep 0.25
    printf 'Progress = "0.34";\nStep = "Step 3 of 4: Unzip'
    sleep 0.05
    printf 'ping System";\nType = Progress;\n'
    sleep 0.30
    printf 'Step = "Step 4 of 4: Installing System";\nType = Step;\n'
    sleep 0.25
    printf 'Progress = "0.66";\nStep = "Step 4 of 4: Installing System";\nType = Progress;\n'
    sleep 0.30
    exit 0
    """#
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let dfu = DFUDevice(state: .dfu, model: "Mac14,2", ecid: "0xABC")
    let restarted = DFUDevice(state: .normal, model: "Mac14,2", ecid: "0xABC")
    let discovery = AppSequencedDiscovery([[dfu], [dfu], [restarted]])
    let engine = RestoreEngine(discovery: discovery, runner: ProcessRunner(), cfgutil: executable)
    let app = AppModel(ipswService: AppMockService(), discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: engine, dfuController: AppMockDFU(), operationLogger: AppMockLogger(), requiresPrivilegedHelperSetup: false)
    await app.refreshDiagnosticsAndTarget()
    #expect(app.canRevive)
    app.revive()

    #expect(await waitForRestoreState(app) { if case .running(_, "Preparing", _, _, nil) = $0 { true } else { false } })
    #expect(await waitForRestoreState(app) { OperationProgressPresentation(state: $0).stage == "Waiting for the device" })
    #expect(await waitForRestoreState(app) { OperationProgressPresentation(state: $0).stage == "Unzipping System — Step 3 of 4" })
    #expect(await waitForRestoreState(app) { OperationProgressPresentation(state: $0).fraction == 0.34 })
    // The fixture process is still sleeping here; seeing the next indeterminate
    // stage proves state was not delivered as one batch after process exit.
    #expect(await waitForRestoreState(app) {
        let value = OperationProgressPresentation(state: $0)
        return value.stage == "Installing System — Step 4 of 4" && value.fraction == nil
    })
    #expect(await waitForRestoreState(app) { OperationProgressPresentation(state: $0).fraction == 0.66 })
    #expect(await waitForRestoreState(app, timeout: 3) { if case .completed = $0 { true } else { false } })
}
