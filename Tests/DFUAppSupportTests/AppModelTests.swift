import DFUAppSupport
import DFUCore
import Foundation
import Testing

private let testURL = URL(fileURLWithPath: "/tmp/test.ipsw")
private func makeRelease(_ version: String = "26.6.2", _ build: String = "25G83") -> IPSWRelease { IPSWRelease(version: version, build: build, downloadURL: URL(string: "https://updates.cdn-apple.com/test.ipsw")!, fileSize: 100) }
private func browsingReleases() -> [IPSWRelease] {
    [
        IPSWRelease(platform: .macOS, version: "26.6.2", build: "MAC", downloadURL: URL(string: "https://updates.cdn-apple.com/mac.ipsw")!, supportedDevices: ["Mac14,2"]),
        IPSWRelease(platform: .iOS, version: "26.6.1", build: "PHONE", downloadURL: URL(string: "https://updates.cdn-apple.com/phone.ipsw")!, supportedDevices: ["iPhone15,2"]),
        IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "PAD", downloadURL: URL(string: "https://updates.cdn-apple.com/pad.ipsw")!, supportedDevices: ["iPad13,18"])
    ]
}

@MainActor @Test func updateTestModeIsHardwareInertAndExposesFictionalUpdate() async {
    let discovery = CountingAppDiscovery([DFUDevice(state: .dfu, model: "Mac14,2", ecid: "SHOULD-NOT-APPEAR")])
    let restore = CountingRestore(), coordinator = UpdateCoordinator.simulated()
    let app = AppModel(ipswService: AppMockService(), discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: restore, dfuController: AppMockDFU(), operationLogger: noOpLogger, updateCoordinator: coordinator, requiresPrivilegedHelperSetup: false, isUpdateTestMode: true)
    await app.load()
    #expect(discovery.callCount == 0); #expect(restore.callCount == 0); #expect(app.targetDevices.isEmpty)
    #expect(!app.canEnterDFU); #expect(!app.canRestore); #expect(!app.canRevive)
    #expect(app.isUpdatePresentationRequested)
    #expect(coordinator.state == .available(SimulatedUpdateService.availability))
}
private func tempCache() -> IPSWCache { IPSWCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) }
private func addValidatedCacheFixture(_ release: IPSWRelease, to cache: IPSWCache, bytes: Int = 17) throws -> URL {
    let partial = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipsw")
    try Data(repeating: 0x5a, count: bytes).write(to: partial)
    return try cache.commit(partial: partial, release: release)
}

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
    init(macVDM: Bool = true, cfgutil: Bool = true) { reportValue = DoctorReport(status: UtilityStatus(host: HostStatus(isAppleSilicon: true, macOSVersion: "26.6.1", macVDMToolPath: macVDM ? URL(fileURLWithPath: "/macvdmtool") : nil, cfgutilPath: cfgutil ? URL(fileURLWithPath: "/cfgutil") : nil, macVDMToolSource: macVDM ? .bundled : nil), targets: []), configuratorPresent: cfgutil, cacheDirectory: URL(fileURLWithPath: "/Users/fixture/Library/Caches/DFUUtility"), cacheWritable: true, restoreSupported: cfgutil) }
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
private final class RepeatingCompletedRestore: @unchecked Sendable, RestoreOperating {
    private let lock = NSLock(); private var actions: [RestoreAction] = []
    func events(for action: RestoreAction) -> AsyncThrowingStream<RestoreEvent, Error> {
        lock.withLock { actions.append(action) }
        return AsyncThrowingStream { $0.yield(.completed); $0.finish() }
    }
    var callCount: Int { lock.withLock { actions.count } }
}
private final class FailingRestore: @unchecked Sendable, RestoreOperating {
    private let lock = NSLock(); private(set) var calls = 0
    func events(for action: RestoreAction) -> AsyncThrowingStream<RestoreEvent, Error> {
        lock.withLock { calls += 1 }
        return AsyncThrowingStream { $0.finish(throwing: DFUError.commandFailed(command: "cfgutil revive", status: 1, output: "fixture failure")) }
    }
    var callCount: Int { lock.withLock { calls } }
}
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
    private let lock = NSLock(); private(set) var starts = 0; private(set) var lastECID: String?; private var appended: [String] = []
    func start(operation: String, target: DFUDevice?, release: IPSWRelease?) throws -> URL { lock.withLock { starts += 1; lastECID = target?.ecid }; return URL(fileURLWithPath: "/tmp/mock-operation.log") }
    func append(_ message: String, to url: URL) throws { lock.withLock { appended.append(message) } }
    var messages: [String] { lock.withLock { appended } }
}
private final class SequencedDFUFailure: @unchecked Sendable, DFUOperating {
    private let lock = NSLock(); private var errors: [Error?]; private(set) var calls = 0
    init(_ errors: [Error?]) { self.errors = errors }
    func enterDFU(timeout: TimeInterval) throws {
        let error = lock.withLock { () -> Error? in calls += 1; return errors.isEmpty ? nil : errors.removeFirst() }
        if let error { throw error }
    }
    var callCount: Int { lock.withLock { calls } }
}
private let noOpLogger = AppMockLogger()

@MainActor private func model(service: AppMockService = AppMockService(), devices: [DFUDevice] = [], validator: AppMockValidator = AppMockValidator(valid: true), cache: IPSWCache = tempCache(), demo: Bool = false) -> AppModel {
    AppModel(ipswService: service, discovery: AppMockDiscovery(values: devices), cache: cache, validator: validator, diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, isDemoMode: demo)
}

@Test @MainActor func catalogueLoadsAndSelectsLatest() async {
    let app = model(service: AppMockService(releases: [makeRelease("15.7", "24A"), makeRelease("26.6.2", "25G83")]))
    await app.load(); #expect(app.catalogueState == .loaded); #expect(app.selectedRelease?.build == "25G83"); #expect(app.availableReleases.count == 2)
}

@Test @MainActor func firmwareCompatibilityPresentationIsPlatformConservative() async {
    let mac = IPSWRelease(platform: .macOS, version: "1", build: "MAC", downloadURL: URL(string: "https://updates.cdn-apple.com/mac.ipsw")!, supportedDevices: [])
    let unknownPhone = IPSWRelease(platform: .iOS, version: "1", build: "PHONE-UNKNOWN", downloadURL: URL(string: "https://updates.cdn-apple.com/phone-unknown.ipsw")!, supportedDevices: [])
    let knownPhone = IPSWRelease(platform: .iOS, version: "1", build: "PHONE", downloadURL: URL(string: "https://updates.cdn-apple.com/phone.ipsw")!, supportedDevices: ["iPhone15,2"])
    let unknownPad = IPSWRelease(platform: .iPadOS, version: "1", build: "PAD-UNKNOWN", downloadURL: URL(string: "https://updates.cdn-apple.com/pad-unknown.ipsw")!, supportedDevices: [])
    let knownPad = IPSWRelease(platform: .iPadOS, version: "1", build: "PAD", downloadURL: URL(string: "https://updates.cdn-apple.com/pad.ipsw")!, supportedDevices: ["iPad13,18"])
    let app = model(service: AppMockService(releases: [mac, unknownPhone, knownPhone, unknownPad, knownPad]))
    await app.load()
    #expect(app.choice(for: mac)?.compatibility == .universalAppleSilicon)
    await app.selectBrowsePlatform(.iOS)
    #expect(app.choice(for: unknownPhone)?.compatibility == .uncertain)
    #expect(app.choice(for: knownPhone)?.compatibility == .uncertain)
    await app.selectBrowsePlatform(.iPadOS)
    #expect(app.choice(for: unknownPad)?.compatibility == .uncertain)
    #expect(app.choice(for: knownPad)?.compatibility == .uncertain)

    let phoneApp = model(service: AppMockService(releases: [knownPhone]), devices: [DFUDevice(family: .iPhone, state: .recovery, ecid: "PHONE", productType: "iPhone15,2")])
    await phoneApp.load()
    #expect(phoneApp.choice(for: knownPhone)?.compatibility == .compatible(model: "iPhone15,2"))
    let padApp = model(service: AppMockService(releases: [knownPad]), devices: [DFUDevice(family: .iPad, state: .recovery, ecid: "PAD", productType: "iPad13,18")])
    await padApp.load()
    #expect(padApp.choice(for: knownPad)?.compatibility == .compatible(model: "iPad13,18"))
}

@Test @MainActor func sanitizedDiagnosticsRetainSupportFactsWithoutIdentifiersOrPaths() async {
    let target = DFUDevice(family: .iPhone, state: .recovery, model: "iPhone 14 Pro", identifier: "SENSITIVE-UDID", ecid: "0xSENSITIVE-ECID", productType: "iPhone15,2", serialNumber: "SENSITIVE-SERIAL")
    let host = HostStatus(isAppleSilicon: true, macOSVersion: "26.6", macVDMToolPath: URL(fileURLWithPath: "/Users/private/bin/macvdmtool"), cfgutilPath: URL(fileURLWithPath: "/Users/private/bin/cfgutil"), macVDMToolSource: .bundled)
    let report = DoctorReport(status: UtilityStatus(host: host, targets: [target]), configuratorPresent: true, cacheDirectory: URL(fileURLWithPath: "/Users/private/Library/Caches/DFUUtility"), cacheWritable: true, restoreSupported: true)
    let text = ShareableDiagnostics.render(report: report, privilegeMode: .community, cacheEntries: [], updateState: .current, updateSourceHealth: "Recorded source available", operationState: .completed("Sensitive operation output"), operationLogAvailable: true)
    for secret in ["0xSENSITIVE-ECID", "SENSITIVE-SERIAL", "SENSITIVE-UDID", "private", "/Users/"] { #expect(!text.contains(secret)) }
    #expect(text.contains("Privilege mode: Community")); #expect(text.contains("cfgutil: Available")); #expect(text.contains("macvdmtool: Available (Bundled)"))
    #expect(text.contains("family iPhone, state Recovery, product iPhone15,2, stable identity Yes"))
    #expect(text.contains("Firmware cache: 0 item(s)")); #expect(text.contains("Update source: Recorded source available; Healthy; current")); #expect(text.contains("Most recent operation: Completed")); #expect(text.contains("Operation log available: Yes"))
}

@Test @MainActor func missingCfgutilShowsSetupRequirementOnlyWhenActuallyUnavailable() async {
    let missing = AppModel(ipswService: AppMockService(), discovery: AppMockDiscovery(values: []), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(cfgutil: false), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    await missing.load(); #expect(missing.cfgutilSetupRequired)
    let available = model(); await available.load(); #expect(!available.cfgutilSetupRequired)
    let demo = AppModel(ipswService: DemoIPSWService(), discovery: DemoDiscovery(), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(cfgutil: false), restoreEngine: DemoRestoreEngine(), dfuController: DemoDFUController(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, isDemoMode: true)
    await demo.load(); #expect(!demo.cfgutilSetupRequired)
}

@Test @MainActor func noTargetFirmwareLibraryBrowsesEveryPlatform() async {
    let app = model(service: AppMockService(releases: browsingReleases()))
    await app.load()
    #expect(app.isFirmwareLibraryMode); #expect(app.restoreSectionTitle == "Firmware Library")
    #expect(app.browsePlatform == .macOS); #expect(app.availableReleases.map(\.platform) == [.macOS])
    await app.selectBrowsePlatform(.iOS)
    #expect(app.browsePlatform == .iOS); #expect(app.availableReleases.map(\.platform) == [.iOS]); #expect(app.selectedRelease?.build == "PHONE")
    await app.selectBrowsePlatform(.iPadOS)
    #expect(app.browsePlatform == .iPadOS); #expect(app.availableReleases.map(\.platform) == [.iPadOS]); #expect(app.selectedRelease?.build == "PAD")
    #expect(app.manageDownloadsAvailable)
}

@Test @MainActor func detailedTargetOverridesBrowsePlatformAndDisconnectReturnsToLibrary() async {
    let phone = DFUDevice(family: .iPhone, state: .recovery, ecid: "PHONE", productType: "iPhone15,2")
    let discovery = AppSequencedDiscovery([[phone], []])
    let app = AppModel(ipswService: AppMockService(releases: browsingReleases()), discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, targetDiscoveryAttempts: 1)
    await app.selectBrowsePlatform(.iPadOS)
    await app.refreshDiagnosticsAndTarget()
    #expect(!app.isFirmwareLibraryMode); #expect(app.targetRestorePlatform == .iOS); #expect(app.restoreSectionTitle == "iOS Restore")
    #expect(app.availableReleases.map(\.platform) == [.iOS]); #expect(app.browsePlatform == .iPadOS)
    await app.refreshDiagnosticsAndTarget()
    #expect(app.isFirmwareLibraryMode); #expect(app.targetRestorePlatform == .iPadOS); #expect(app.restoreSectionTitle == "Firmware Library")
    #expect(app.availableReleases.map(\.platform) == [.iPadOS])
}

@Test @MainActor func browsingPlatformCannotBypassConnectedTargetCompatibility() async {
    let incompatiblePhone = DFUDevice(family: .iPhone, state: .recovery, ecid: "PHONE", productType: "iPhone16,1")
    let discovery = AppSequencedDiscovery([[incompatiblePhone]])
    let app = AppModel(ipswService: AppMockService(releases: browsingReleases()), discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, targetDiscoveryAttempts: 1)
    await app.selectBrowsePlatform(.iOS); #expect(app.selectedRelease?.build == "PHONE")
    await app.refreshDiagnosticsAndTarget()
    #expect(app.targetRestorePlatform == .iOS); #expect(app.availableReleases.isEmpty); #expect(app.selectedRelease == nil); #expect(!app.canRestore)
}

@Test @MainActor func firmwareChooserMergesCatalogueAndValidatedCacheNewestFirst() async throws {
    let cache = tempCache()
    let catalogueOnly = IPSWRelease(platform: .iOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/current.ipsw")!, fileSize: 100, supportedDevices: ["iPhone7,2"])
    let cachedOnly = IPSWRelease(platform: .iOS, version: "16.7.16", build: "20H392", downloadURL: URL(string: "https://updates.cdn-apple.com/historical.ipsw")!, supportedDevices: ["iPhone7,2"])
    let olderCached = IPSWRelease(platform: .iOS, version: "12.5.8", build: "16H88", downloadURL: URL(string: "https://updates.cdn-apple.com/older.ipsw")!, supportedDevices: ["iPhone7,2"])
    _ = try addValidatedCacheFixture(cachedOnly, to: cache, bytes: 23)
    _ = try addValidatedCacheFixture(olderCached, to: cache, bytes: 19)
    let app = model(service: AppMockService(releases: [catalogueOnly]), cache: cache)
    await app.selectBrowsePlatform(.iOS)

    #expect(app.availableReleases.map(\.build) == ["23G83", "20H392", "16H88"])
    #expect(app.choice(for: catalogueOnly)?.cacheState == .downloadRequired)
    #expect(app.choice(for: cachedOnly)?.cacheState == .downloaded(cache.destination(for: cachedOnly)))
    #expect(app.displaySize(for: cachedOnly) == 23)
    #expect(app.choice(for: catalogueOnly)?.isRecommended == true)
    #expect(app.choice(for: cachedOnly)?.isRecommended == false)
}

@Test @MainActor func catalogueAndCacheDuplicateUsesCatalogueMetadataAndLocalValidation() async throws {
    let cache = tempCache()
    let cached = IPSWRelease(platform: .iOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/old-url.ipsw")!, fileSize: 17, supportedDevices: ["iPhone7,2"])
    let catalogue = IPSWRelease(platform: .iOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/catalogue-url.ipsw")!, fileSize: 99, supportedDevices: ["iPhone7,2"], signingStatus: .appleCatalogue)
    let localURL = try addValidatedCacheFixture(cached, to: cache)
    let app = model(service: AppMockService(releases: [catalogue]), cache: cache)
    await app.selectBrowsePlatform(.iOS)

    #expect(app.availableReleases.count == 1)
    #expect(app.availableReleases[0].downloadURL == catalogue.downloadURL)
    #expect(app.choice(for: catalogue)?.cacheState == .downloaded(localURL))
    #expect(app.displaySize(for: catalogue) == 99)
}

@Test @MainActor func selectingCachedOnlyReleaseUsesLocalFileWithoutDownload() async throws {
    let cache = tempCache()
    let cached = IPSWRelease(platform: .iOS, version: "16.7.16", build: "20H392", downloadURL: URL(string: "https://updates.cdn-apple.com/historical.ipsw")!, supportedDevices: ["iPhone7,2"])
    let localURL = try addValidatedCacheFixture(cached, to: cache)
    let service = TrackingIPSWService(releases: [])
    let app = AppModel(ipswService: service, discovery: AppMockDiscovery(values: []), cache: cache, validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    await app.selectBrowsePlatform(.iOS)
    app.selectRelease(cached)

    #expect(app.imageURL == localURL)
    #expect(service.eventRequests == 0)
}

@Test @MainActor func cachedFirmwareIsPlatformAndConnectedProductFiltered() async throws {
    let cache = tempCache()
    let compatible = IPSWRelease(platform: .iOS, version: "16.7.16", build: "PHONE-OK", downloadURL: URL(string: "https://updates.cdn-apple.com/phone-ok.ipsw")!, supportedDevices: ["iPhone7,2"])
    let incompatible = IPSWRelease(platform: .iOS, version: "16.7.15", build: "PHONE-NO", downloadURL: URL(string: "https://updates.cdn-apple.com/phone-no.ipsw")!, supportedDevices: ["iPhone10,1"])
    let unknown = IPSWRelease(platform: .iOS, version: "15.0", build: "PHONE-UNKNOWN", downloadURL: URL(string: "https://updates.cdn-apple.com/phone-unknown.ipsw")!)
    let pad = IPSWRelease(platform: .iPadOS, version: "17.7", build: "PAD", downloadURL: URL(string: "https://updates.cdn-apple.com/pad.ipsw")!, supportedDevices: ["iPad7,11"])
    for release in [compatible, incompatible, unknown, pad] { _ = try addValidatedCacheFixture(release, to: cache) }

    let browsing = model(service: AppMockService(releases: []), cache: cache)
    await browsing.selectBrowsePlatform(.iOS)
    #expect(Set(browsing.availableReleases.map(\.build)) == ["PHONE-OK", "PHONE-NO", "PHONE-UNKNOWN"])
    await browsing.selectBrowsePlatform(.iPadOS)
    #expect(browsing.availableReleases.map(\.build) == ["PAD"])

    let phone = DFUDevice(family: .iPhone, state: .recovery, ecid: "SYNTHETIC", productType: "iPhone7,2")
    let connected = model(service: AppMockService(releases: []), devices: [phone], cache: cache)
    await connected.load()
    #expect(connected.availableReleases.map(\.build) == ["PHONE-OK"])
    #expect(connected.choice(for: unknown) == nil)
}

@Test @MainActor func removingCachedOnlyReleaseRemovesItFromChooserAfterRefresh() async throws {
    let cache = tempCache()
    let cached = IPSWRelease(platform: .iOS, version: "16.7.16", build: "20H392", downloadURL: URL(string: "https://updates.cdn-apple.com/historical.ipsw")!, supportedDevices: ["iPhone7,2"])
    _ = try addValidatedCacheFixture(cached, to: cache)
    let app = model(service: AppMockService(releases: []), cache: cache)
    await app.selectBrowsePlatform(.iOS)
    let entry = try #require(app.managedCacheEntries.first { $0.release.build == cached.build })
    await app.removeManagedCacheEntry(entry)
    #expect(app.availableReleases.isEmpty)
    #expect(app.selectedRelease == nil)
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

@Test @MainActor func appCacheMutationGateProtectsFrozenBatchFirmwareOnlyWhileReferenced() {
    let app = model()
    let protectedURL = URL(fileURLWithPath: "/managed/protected.ipsw")
    let unrelatedURL = URL(fileURLWithPath: "/managed/unrelated.ipsw")
    let release = makeRelease()
    let protectedEntry = ManagedIPSWEntry(release: release, state: .completeValidated, sizeBytes: 10, url: protectedURL)
    let unrelatedEntry = ManagedIPSWEntry(release: makeRelease("26.6.1", "OTHER"), state: .completeValidated, sizeBytes: 10, url: unrelatedURL)
    app.deviceSessions.reconcile([
        DFUDevice(family: .mac, state: .dfu, ecid: "ACTIVE", productType: "Mac14,2"),
        DFUDevice(family: .mac, state: .dfu, ecid: "QUEUED", productType: "Mac14,2")
    ])
    for session in app.deviceSessions.sessions {
        app.deviceSessions.setFirmware(for: session.id, release: release, url: protectedURL, validation: .validated)
        app.deviceSessions.select(session.id, selected: true)
    }
    let frozen = app.deviceSessions.freezeSelectedBatch()

    #expect(app.cacheRemovalDisabledReason(for: protectedEntry) == "This firmware is being used by the current batch.")
    #expect(app.cacheRemovalDisabledReason(for: unrelatedEntry) == nil)
    app.deviceSessions.finishBatchWork(for: frozen[0].id)
    #expect(app.cacheRemovalDisabledReason(for: protectedEntry) != nil)
    app.deviceSessions.finishBatchWork(for: frozen[1].id)
    #expect(app.cacheRemovalDisabledReason(for: protectedEntry) == nil)
    app.deviceSessions.finishBatch()
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
    let cache = tempCache()
    let app = AppModel(ipswService: DemoIPSWService(), discovery: AppMockDiscovery(values: []), cache: cache, validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, isDemoMode: true)
    await app.load(); app.beginDownload(); try await Task.sleep(for: .milliseconds(180)); app.cancelDownload(); try await Task.sleep(for: .milliseconds(180))
    #expect(app.downloadState == .cancelled); #expect(app.imageURL == nil)
    #expect(!FileManager.default.fileExists(atPath: cache.directory.path))
}

@Test func demoCatalogueCoversEveryPlatformAndFiltersCompatibleProducts() async throws {
    let service = DemoIPSWService()
    for platform in RestorePlatform.allCases {
        let releases = try await service.availableImages(for: platform)
        #expect(!releases.isEmpty)
        #expect(releases.allSatisfy { $0.platform == platform })
        #expect(releases.allSatisfy { $0.build.contains("DEMO") && $0.downloadURL.host == "firmware.demo.invalid" })
    }
    let phone = DFUDevice(family: .iPhone, state: .recovery, productType: "iPhone15,2")
    let pad = DFUDevice(family: .iPad, state: .recovery, productType: "iPad13,18")
    let mac = DFUDevice(family: .mac, state: .dfu, productType: "Mac14,2")
    #expect(try await service.availableImages(for: phone).allSatisfy { $0.supportedDevices.contains("iPhone15,2") })
    #expect(try await service.availableImages(for: pad).allSatisfy { $0.supportedDevices.contains("iPad13,18") })
    #expect(try await service.availableImages(for: mac).allSatisfy { $0.supportedDevices.contains("Mac14,2") })
    let incompatible = DFUDevice(family: .iPhone, state: .recovery, productType: "iPhone-DEMO-OTHER")
    #expect(try await service.availableImages(for: incompatible).isEmpty)
}

@Test @MainActor func demoFirmwareLibraryMergesCatalogueAndInMemoryCacheAcrossPlatforms() async {
    let cache = tempCache()
    let app = AppModel(ipswService: DemoIPSWService(), discovery: AppMockDiscovery(values: []), cache: cache, validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, isDemoMode: true)
    await app.load()

    #expect(app.availableReleases.count == 2)
    #expect(app.choice(for: app.availableReleases.first { $0.build == "25G83-DEMO" }!)?.isRecommended == true)
    #expect(app.choice(for: app.availableReleases.first { $0.build == "25G83-DEMO" }!)?.cacheState == .downloadRequired)
    #expect(app.choice(for: app.availableReleases.first { $0.build == "25F74-DEMO" }!)?.cacheState == .downloaded(URL(fileURLWithPath: "/demo/cache/macOS/25F74-DEMO/Restore.ipsw")))

    await app.selectBrowsePlatform(.iOS)
    #expect(app.availableReleases.map(\.build) == ["23G83-DEMO", "22H374-DEMO", "20H392-DEMO", "16H88-DEMO"])
    #expect(app.availableReleases.filter { $0.build == "22H374-DEMO" }.count == 1)
    #expect(app.choice(for: app.availableReleases[0])?.isRecommended == true)
    #expect(app.choice(for: app.availableReleases[0])?.cacheState == .downloadRequired)
    for build in ["22H374-DEMO", "20H392-DEMO", "16H88-DEMO"] {
        let release = app.availableReleases.first { $0.build == build }!
        if case .downloaded = app.choice(for: release)?.cacheState {} else { Issue.record("Expected \(build) to be a validated demo cache entry") }
    }
    let historical = app.availableReleases.first { $0.build == "16H88-DEMO" }!
    app.selectRelease(historical)
    #expect(app.imageURL == URL(fileURLWithPath: "/demo/cache/iOS/16H88-DEMO/Restore.ipsw"))

    await app.selectBrowsePlatform(.iPadOS)
    #expect(app.availableReleases.count == 2)
    #expect(Set(app.managedCacheEntries.map(\.release.platform)) == Set(RestorePlatform.allCases))
    #expect(!FileManager.default.fileExists(atPath: cache.directory.path))
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

@Test @MainActor func restoreDisabledWithoutValidImage() async {
    let app = model(service: AppMockService(releases: []), devices: [DFUDevice(state: .dfu)]); await app.refreshDiagnosticsAndTarget()
    #expect(!app.canRestore); #expect(app.restoreUnavailableMessage == "Select firmware before restoring.")
}

@Test @MainActor func contextualErrorTitlesPreserveKnownOperationContext() {
    let app = model()
    app.presentedError = "Restore failed.\nfixture"; #expect(app.presentedErrorTitle == "Restore Failed")
    app.presentedError = "Revive failed.\nfixture"; #expect(app.presentedErrorTitle == "Revive Failed")
    app.presentedError = "Administrator authorization was cancelled while entering DFU."; #expect(app.presentedErrorTitle == "DFU Entry Failed")
    app.presentedError = "Image download failed.\nfixture"; #expect(app.presentedErrorTitle == "Download Failed")
    app.presentedError = "Unable to load Apple restore images."; #expect(app.presentedErrorTitle == "Firmware Unavailable")
    app.presentedError = "DFUUtility is preparing to update."; #expect(app.presentedErrorTitle == "Update Failed")
    app.presentedError = "fixture"; #expect(app.presentedErrorTitle == "DFUUtility")
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
    let wrongOnly = model(service: AppMockService(releases: [wrong]), devices: [target], cache: tempCache()); await wrongOnly.load()
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
    let app = AppModel(ipswService: AppMockService(), discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(macVDM: false), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, isDemoMode: true)
    await app.load(); await app.refreshDiagnosticsAndTarget()
    #expect(discovery.callCount == 0); #expect(app.targetDevices.isEmpty); #expect(app.deviceSessions.sessions.count == 4); #expect(!app.shouldShowMissingDFUHelperWarning)
    app.startBatchRestore(); #expect(app.presentedError?.contains("Demo mode") == true)
}

@Test @MainActor func normalModeStillReportsMissingDFUHelper() async {
    let app = AppModel(ipswService: AppMockService(), discovery: AppMockDiscovery(values: []), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(macVDM: false), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    await app.load()
    #expect(app.shouldShowMissingDFUHelperWarning)
}

@Test @MainActor func automaticMacDFURemainsSingleTargetOnly() async {
    let devices = [DFUDevice(family: .mac, state: .normal, ecid: "MAC-A", productType: "Mac14,2"), DFUDevice(family: .mac, state: .normal, ecid: "MAC-B", productType: "Mac15,3")]
    let app = model(devices: devices); await app.refreshDiagnosticsAndTarget(); app.selectTarget(ecid: "MAC-A")
    #expect(app.target?.ecid == "MAC-A"); #expect(!app.canEnterDFU); #expect(app.macDFUMultiTargetUnavailable)
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

@Test @MainActor func mobileRestoreCapabilityAllowsRecoveryAndDFUButNotNormal() async throws {
    func loadedModel(family: AppleDeviceFamily, state: DeviceState) async throws -> AppModel {
        let product = family == .iPhone ? "iPhone15,2" : "iPad13,18"
        let platform: RestorePlatform = family == .iPhone ? .iOS : .iPadOS
        let value = IPSWRelease(platform: platform, version: "26.6.1", build: family == .iPhone ? "23G83" : "23G84", downloadURL: URL(string: "https://updates.cdn-apple.com/mobile.ipsw")!, supportedDevices: [product])
        let cache = tempCache(); try cache.prepare(for: value); try Data("valid".utf8).write(to: cache.partialURL(for: value)); _ = try cache.commit(partial: cache.partialURL(for: value), release: value)
        let app = model(service: AppMockService(releases: [value]), devices: [DFUDevice(family: family, state: state, ecid: "SYNTHETIC-ECID", productType: product)], cache: cache)
        await app.load()
        return app
    }

    for family in [AppleDeviceFamily.iPhone, .iPad] {
        let recovery = try await loadedModel(family: family, state: .recovery)
        #expect(recovery.canRestore)
        let dfu = try await loadedModel(family: family, state: .dfu)
        #expect(dfu.canRestore)
        let normal = try await loadedModel(family: family, state: .normal)
        #expect(!normal.canRestore)
        #expect(normal.restoreUnavailableMessage == "Restore requires the \(family.displayName) to be in Recovery or DFU mode.")
        normal.restoreConfirmed()
        #expect(normal.presentedError == normal.restoreUnavailableMessage)
    }
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
    #expect(app.presentedError?.contains("Administrator authorization was cancelled.") == true)
    #expect(app.presentedError?.contains("try Enter DFU again") == true); #expect(app.canEnterDFU)
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

@Test @MainActor func completedRevivePreservesResultRefreshesAndAllowsSecondOperation() async {
    let dfu = DFUDevice(state: .dfu, model: "Mac14,2", ecid: "0xABC")
    let normal = DFUDevice(state: .normal, model: "Mac14,2", ecid: "0xABC")
    let recovery = DFUDevice(state: .recovery, model: "Mac14,2", ecid: "0xABC")
    let engine = RepeatingCompletedRestore()
    let discovery = AppSequencedDiscovery([[dfu], [normal], [recovery], [normal]])
    let app = AppModel(ipswService: AppMockService(), discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: engine, dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, reconnectAttempts: 1, reconnectInterval: .zero)

    await app.refreshDiagnosticsAndTarget(); app.revive()
    #expect(await waitForRestoreState(app) { if case .completed = $0 { true } else { false } })
    #expect(!app.operationInProgress); #expect(!app.reconnectInProgress); #expect(app.target?.state == .normal)
    if case .completed(let message) = app.restoreState { #expect(message.contains("Revive completed successfully")) } else { Issue.record("Expected preserved Revive result") }

    await app.refreshDiagnosticsAndTarget()
    #expect(app.target?.state == .recovery); #expect(app.selectedTargetECID == "0xABC"); #expect(app.canRevive)
    app.revive()
    #expect(await waitForRestoreState(app) { _ in engine.callCount == 2 && !app.operationInProgress })
}

@Test @MainActor func completedRestorePreservesResultRefreshesAndAllowsSecondOperation() async {
    let dfu = DFUDevice(state: .dfu, model: "Mac14,2", ecid: "0xABC")
    let normal = DFUDevice(state: .normal, model: "Mac14,2", ecid: "0xABC")
    let engine = RepeatingCompletedRestore()
    let discovery = AppSequencedDiscovery([[dfu], [normal], [dfu], [normal]])
    let app = AppModel(ipswService: AppMockService(), discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: engine, dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, reconnectAttempts: 1, reconnectInterval: .zero)

    await app.refreshDiagnosticsAndTarget(); await app.validateManualIPSW(testURL); #expect(app.canRestore)
    app.restoreConfirmed()
    #expect(await waitForRestoreState(app) { if case .completed = $0 { true } else { false } })
    #expect(!app.operationInProgress); #expect(app.target?.state == .normal)

    await app.refreshDiagnosticsAndTarget()
    #expect(app.target?.state == .dfu); #expect(app.canRestore)
    app.restoreConfirmed()
    #expect(await waitForRestoreState(app) { _ in engine.callCount == 2 && !app.operationInProgress })
}

@Test @MainActor func reconnectTimeoutClearsBlockerAndLaterRefreshRecoversTarget() async {
    let dfu = DFUDevice(state: .dfu, model: "Mac14,2", ecid: "0xABC")
    let normal = DFUDevice(state: .normal, model: "Mac14,2", ecid: "0xABC")
    let discovery = AppSequencedDiscovery([[dfu], [], [normal]])
    let app = AppModel(ipswService: AppMockService(), discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, reconnectAttempts: 1, reconnectInterval: .zero)

    await app.refreshDiagnosticsAndTarget(); app.revive()
    #expect(await waitForRestoreState(app) { if case .completed(let message) = $0 { message.contains("could not be verified") } else { false } })
    #expect(!app.operationInProgress); #expect(app.target?.state == .dfu)
    await app.refreshDiagnosticsAndTarget()
    #expect(app.target?.state == .normal); #expect(app.canEnterDFU)
}

@Test @MainActor func failureClearsBlockerAndRefreshAllowsRetry() async {
    let recovery = DFUDevice(state: .recovery, model: "Mac14,2", ecid: "0xABC")
    let engine = FailingRestore(), discovery = AppSequencedDiscovery([[recovery], [recovery]])
    let app = AppModel(ipswService: AppMockService(), discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: engine, dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)

    await app.refreshDiagnosticsAndTarget(); app.revive()
    #expect(await waitForRestoreState(app) { if case .failed = $0 { true } else { false } })
    #expect(!app.operationInProgress); #expect(app.targetWorkflowState == .recovery)
    #expect(app.presentedError?.contains("fixture failure") == true)
    #expect(app.presentedError?.contains("Refresh and verify the device is still connected") == true)
    #expect(app.presentedError?.contains("View the operation log") == true)
    await app.refreshDiagnosticsAndTarget(); #expect(app.target?.state == .recovery); #expect(app.canRevive)
    app.revive(); #expect(await waitForRestoreState(app) { _ in engine.callCount == 2 && !app.operationInProgress })
}

@Test @MainActor func observedVDMFailureIsConciseLoggedAndRetryableAfterRefresh() async {
    let raw = "Mac type: J414sAP\nLooking for HPM devices...\nFound: IOService:/fixture\nConnection: Source\nStatus: APP\nUnlocking... OK\nEntering DBMa mode... Status: DBMa\nRebooting target into DFU mode... VDM failed (reply: 0x05ac8092)\nExiting DBMa mode... OK\nVDM failed"
    let transition = MacVDMToolFailure.classify(status: 255, output: raw)
    let controller = SequencedDFUFailure([transition, transition])
    let logger = AppMockLogger()
    let normal = DFUDevice(state: .normal, model: "MacBookAir10,1", ecid: "0xABC")
    let app = AppModel(ipswService: AppMockService(), discovery: AppMockDiscovery(values: [normal]), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: controller, operationLogger: logger, requiresPrivilegedHelperSetup: false)

    await app.refreshDiagnosticsAndTarget(); #expect(app.canEnterDFU)
    await app.enterDFU()
    #expect(!app.operationInProgress); #expect(app.targetWorkflowState == .normal); #expect(app.canEnterDFU)
    if case .failed(let message) = app.restoreState {
        #expect(message.contains("did not accept the DFU transition")); #expect(message.contains("try Enter DFU again"))
        #expect(!message.contains("Mac type:")); #expect(!message.contains("0x05ac8092")); #expect(!message.contains("DBMa"))
    } else { Issue.record("Expected concise DFU failure") }
    #expect(app.presentedError?.contains("did not accept the DFU transition") == true)
    #expect(app.presentedError?.contains("Mac type:") == false)
    #expect(logger.messages.joined(separator: "\n").contains(raw)); #expect(logger.messages.joined(separator: "\n").contains("Exit status: 255"))

    await app.refreshDiagnosticsAndTarget(); #expect(app.target?.state == .normal); #expect(app.canEnterDFU)
    await app.enterDFU(); #expect(controller.callCount == 2); #expect(!app.operationInProgress)
}

@Test func dfuFailurePresentationKeepsAuthorizationToolAndLaunchFailuresDistinct() {
    let authorization = DFUFailurePresentation(error: CommunityDFUError.authorizationFailed("fixture authorization detail"))
    #expect(authorization.summary.contains("authorize DFU mode")); #expect(authorization.diagnosticDetails.contains("fixture authorization detail"))
    let unavailable = DFUFailurePresentation(error: DFUError.toolUnavailable("bundled/project macvdmtool"))
    #expect(unavailable.summary.contains("bundled DFU component is unavailable"))
    let launch = DFUFailurePresentation(error: MacVDMToolFailure(kind: .processLaunch, exitStatus: -1, output: "fixture launch failure"))
    #expect(launch.summary.contains("Couldn’t start")); #expect(launch.diagnosticDetails.contains("fixture launch failure"))
    #expect(authorization.summary != unavailable.summary && unavailable.summary != launch.summary)
}

@Test @MainActor func explicitRefreshDuringReconnectPreventsStaleVerifierOverwrite() async {
    let dfu = DFUDevice(state: .dfu, model: "Mac14,2", ecid: "0xABC")
    let refreshed = DFUDevice(state: .recovery, model: "Mac14,2", ecid: "0xABC")
    let stale = DFUDevice(state: .normal, model: "Mac14,2", ecid: "0xABC")
    let discovery = AppSequencedDiscovery([[dfu], [], [refreshed], [stale]])
    let app = AppModel(ipswService: AppMockService(), discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, reconnectAttempts: 3, reconnectInterval: .seconds(1))

    await app.refreshDiagnosticsAndTarget(); app.revive()
    #expect(await waitForRestoreState(app) { if case .reconnecting = $0 { true } else { false } })
    await app.refreshDiagnosticsAndTarget()
    #expect(app.target?.state == .recovery); #expect(!app.operationInProgress)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(app.target?.state == .recovery)
    if case .completed(let message) = app.restoreState { #expect(message.contains("could not be verified")) } else { Issue.record("Expected preserved completion result") }
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
