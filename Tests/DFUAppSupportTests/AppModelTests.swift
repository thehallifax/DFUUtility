@testable import DFUAppSupport
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
private final class CountingHoldingRestore: @unchecked Sendable, RestoreOperating {
    private let lock = NSLock(); private var actions: [RestoreAction] = []
    func events(for action: RestoreAction) -> AsyncThrowingStream<RestoreEvent, Error> {
        lock.withLock { actions.append(action) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.preparing)
                try? await Task.sleep(for: .milliseconds(300))
                continuation.yield(.completed); continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    var callCount: Int { lock.withLock { actions.count } }
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
    await phoneApp.load(); await phoneApp.selectBrowsePlatform(.iOS)
    #expect(phoneApp.choice(for: knownPhone)?.compatibility == .compatible(model: "iPhone15,2"))
    let padApp = model(service: AppMockService(releases: [knownPad]), devices: [DFUDevice(family: .iPad, state: .recovery, ecid: "PAD", productType: "iPad13,18")])
    await padApp.load(); await padApp.selectBrowsePlatform(.iPadOS)
    #expect(padApp.choice(for: knownPad)?.compatibility == .compatible(model: "iPad13,18"))
}

@Test @MainActor func sanitizedDiagnosticsRetainSupportFactsWithoutIdentifiersOrPaths() async {
    let target = DFUDevice(family: .iPhone, state: .recovery, model: "iPhone 14 Pro", identifier: "SENSITIVE-UDID", ecid: "0xSENSITIVE-ECID", productType: "iPhone15,2", serialNumber: "SENSITIVE-SERIAL")
    let host = HostStatus(isAppleSilicon: true, macOSVersion: "26.6", macVDMToolPath: URL(fileURLWithPath: "/Users/private/bin/macvdmtool"), cfgutilPath: URL(fileURLWithPath: "/Users/private/bin/cfgutil"), macVDMToolSource: .bundled)
    let report = DoctorReport(status: UtilityStatus(host: host, targets: [target]), configuratorPresent: true, cacheDirectory: URL(fileURLWithPath: "/Users/private/Library/Caches/DFUUtility"), cacheWritable: true, restoreSupported: true)
    let text = ShareableDiagnostics.render(report: report, privilegeMode: .community, cacheEntries: [], updateState: .current, updateSourceHealth: "Recorded source available", operationState: .completed("Sensitive operation output"), operationLogAvailable: true)
    for secret in ["0xSENSITIVE-ECID", "SENSITIVE-SERIAL", "SENSITIVE-UDID", "private", "/Users/"] { #expect(!text.contains(secret)) }
    #expect(text.contains("Privilege mode: Community")); #expect(text.contains("cfgutil: Available")); #expect(text.contains("macvdmtool: Available (Bundled)"))
    #expect(text.contains("Accessory Connections: Not available")); #expect(text.contains("Privacy & Security → Accessories"))
    #expect(!text.contains("Accessory Connections: Ready"))
    #expect(text.contains("family iPhone, state Recovery, product iPhone15,2, stable identity Yes"))
    #expect(text.contains("Firmware cache: 0 item(s)")); #expect(text.contains("Update source: Recorded source available; Healthy; current")); #expect(text.contains("Most recent operation: Completed")); #expect(text.contains("Operation log available: Yes"))
}

@Test func diagnosticsViewPresentsAccessoryReadinessWithoutSettingsAutomation() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let content = try String(contentsOf: root.appendingPathComponent("Sources/DFUUtilityApp/DiagnosticsView.swift"), encoding: .utf8)
    #expect(content.contains("Host Readiness")); #expect(content.contains("Accessory Connections"))
    #expect(content.contains("Automatically allow when unlocked")); #expect(content.contains("Always allow"))
    #expect(!content.contains("NSWorkspace")); #expect(!content.contains("osascript")); #expect(!content.contains("Process("))
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

@Test @MainActor func firmwareLibraryPlatformsRemainIndependentWithEveryTargetShape() async {
    let shapes: [[DFUDevice]] = [
        [DFUDevice(family: .mac, state: .dfu, ecid: "MAC", productType: "Mac14,2")],
        [DFUDevice(family: .iPhone, state: .recovery, ecid: "PHONE", productType: "iPhone15,2")],
        [DFUDevice(family: .iPad, state: .recovery, ecid: "PAD", productType: "iPad13,18")],
        [DFUDevice(family: .mac, state: .dfu, ecid: "MAC", productType: "Mac14,2"), DFUDevice(family: .iPad, state: .recovery, ecid: "PAD", productType: "iPad13,18")]
    ]
    for devices in shapes {
        let app = model(service: AppMockService(releases: browsingReleases()), devices: devices)
        await app.load()
        #expect(app.isFirmwareLibraryMode); #expect(app.restoreSectionTitle == "Firmware Library")
        for platform in RestorePlatform.allCases {
            await app.selectBrowsePlatform(platform)
            #expect(app.browsePlatform == platform); #expect(app.availableReleases.allSatisfy { $0.platform == platform })
        }
    }
}

@Test @MainActor func libraryBrowsingNeverMutatesAssignedOrFrozenIPadFirmware() async throws {
    let assigned = IPSWRelease(platform: .iPadOS, version: "18.7.10", build: "22H374", downloadURL: URL(string: "https://example.invalid/assigned.ipsw")!, checksum: "assigned", supportedDevices: ["iPad7,11"])
    let otherPad = IPSWRelease(platform: .iPadOS, version: "18.7.9", build: "22H370", downloadURL: URL(string: "https://example.invalid/other.ipsw")!, checksum: "other", supportedDevices: ["iPad7,11"])
    let releases = browsingReleases() + [assigned, otherPad]
    let cache = tempCache(), assignedURL = try addValidatedCacheFixture(assigned, to: cache)
    let pad = DFUDevice(family: .iPad, state: .recovery, ecid: "PAD", productType: "iPad7,11")
    let app = model(service: AppMockService(releases: releases), devices: [pad], cache: cache)
    await app.load()
    let id = try #require(app.deviceSessions.sessions.first?.id)
    app.deviceSessions.setFirmware(for: id, release: assigned, url: assignedURL, validation: .validated)
    app.setSessionSelected(id, selected: true)
    _ = app.deviceSessions.freezeSelectedBatch()
    for platform in [RestorePlatform.macOS, .iOS, .iPadOS] {
        await app.selectBrowsePlatform(platform)
        if platform == .iPadOS { app.selectRelease(otherPad) }
        let session = try #require(app.deviceSessions.sessions.first)
        #expect(session.selectedRelease == assigned); #expect(session.selectedImageURL == assignedURL); #expect(session.firmwareState == .validated)
        #expect(app.deviceSessions.activeBatchIDs == [id]); #expect(app.deviceSessions.isFirmwareInUseByBatch(assignedURL))
    }
}

@Test @MainActor func currentLibraryFirmwareChangesSessionOnlyAfterExplicitCompatibleAssignment() async throws {
    let release = browsingReleases().first { $0.platform == .iPadOS }!
    let cache = tempCache(), url = try addValidatedCacheFixture(release, to: cache)
    let pad = DFUDevice(family: .iPad, state: .recovery, ecid: "PAD", productType: "iPad13,18")
    let app = model(service: AppMockService(releases: browsingReleases()), devices: [pad], cache: cache)
    await app.load(); await app.selectBrowsePlatform(.iPadOS)
    let id = try #require(app.detailedSession?.id)
    app.deviceSessions.setFirmware(for: id, release: nil, url: nil, validation: .unselected)
    #expect(app.detailedSession?.selectedRelease == nil)
    await app.prepareFirmwareChooser(for: id)
    app.choosePendingRelease(release)
    app.confirmPendingRelease(for: id)
    #expect(app.detailedSession?.selectedRelease == release); #expect(app.detailedSession?.selectedImageURL == url); #expect(app.detailedSession?.firmwareState == .validated)
}

@Test @MainActor func libraryFirmwareBatchActionRequiresCompatibilityWithEverySelectedTarget() async {
    let shared = IPSWRelease(platform: .iPadOS, version: "18.7.10", build: "SHARED", downloadURL: URL(string: "https://example.invalid/shared.ipsw")!, supportedDevices: ["iPad7,11", "iPad12,1"])
    let narrow = IPSWRelease(platform: .iPadOS, version: "18.7.9", build: "NARROW", downloadURL: URL(string: "https://example.invalid/narrow.ipsw")!, supportedDevices: ["iPad7,11"])
    let devices = [
        DFUDevice(family: .iPad, state: .recovery, ecid: "PAD-A", productType: "iPad7,11"),
        DFUDevice(family: .iPad, state: .recovery, ecid: "PAD-B", productType: "iPad12,1")
    ]
    let app = model(service: AppMockService(releases: [shared, narrow]), devices: devices)
    await app.load(); await app.selectBrowsePlatform(.iPadOS)
    for session in app.deviceSessions.sessions { app.setSessionSelected(session.id, selected: true) }
    app.selectRelease(narrow)
    #expect(!app.canApplyCurrentLibraryFirmwareToSelectedSessions)
    app.selectRelease(shared)
    #expect(app.canApplyCurrentLibraryFirmwareToSelectedSessions)
    app.clearSessionSelection()
    #expect(!app.canApplyCurrentLibraryFirmwareToSelectedSessions)
}

@Test @MainActor func connectedTargetNeverOverridesIndependentFirmwareLibraryPlatform() async {
    let phone = DFUDevice(family: .iPhone, state: .recovery, ecid: "PHONE", productType: "iPhone15,2")
    let discovery = AppSequencedDiscovery([[phone], []])
    let app = AppModel(ipswService: AppMockService(releases: browsingReleases()), discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, targetDiscoveryAttempts: 1)
    await app.selectBrowsePlatform(.iPadOS)
    await app.refreshDiagnosticsAndTarget()
    #expect(app.isFirmwareLibraryMode); #expect(app.targetRestorePlatform == .iOS); #expect(app.restoreSectionTitle == "Firmware Library")
    #expect(app.availableReleases.map(\.platform) == [.iPadOS]); #expect(app.browsePlatform == .iPadOS)
    await app.refreshDiagnosticsAndTarget()
    #expect(app.isFirmwareLibraryMode); #expect(app.targetRestorePlatform == .iPadOS); #expect(app.restoreSectionTitle == "Firmware Library")
    #expect(app.availableReleases.map(\.platform) == [.iPadOS])
}

@Test @MainActor func browsingPlatformCannotBypassExplicitDeviceAssignmentCompatibility() async {
    let incompatiblePhone = DFUDevice(family: .iPhone, state: .recovery, ecid: "PHONE", productType: "iPhone16,1")
    let discovery = AppSequencedDiscovery([[incompatiblePhone]])
    let app = AppModel(ipswService: AppMockService(releases: browsingReleases()), discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, targetDiscoveryAttempts: 1)
    await app.selectBrowsePlatform(.iOS); #expect(app.selectedRelease?.build == "PHONE")
    await app.refreshDiagnosticsAndTarget()
    #expect(app.targetRestorePlatform == .iOS); #expect(app.availableReleases.map(\.platform) == [.iOS]); #expect(app.selectedRelease?.build == "PHONE"); #expect(!app.canRestore)
    let id = try! #require(app.detailedSession?.id)
    await app.prepareFirmwareChooser(for: id)
    #expect(app.firmwareChoices(for: id).isEmpty)
    #expect(app.detailedSession?.firmwareState != .validated); #expect(!app.canRestore)
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
    let assetURL = URL(string: "https://updates.cdn-apple.com/catalogue-url.ipsw")!
    let cached = IPSWRelease(platform: .iOS, version: "26.6.1", build: "23G83", downloadURL: assetURL, fileSize: 17, checksum: "same-asset", supportedDevices: ["iPhone7,2"])
    let catalogue = IPSWRelease(platform: .iOS, version: "26.6.1", build: "23G83", downloadURL: assetURL, fileSize: 99, checksum: "same-asset", supportedDevices: ["iPhone7,2"], signingStatus: .appleCatalogue)
    let localURL = try addValidatedCacheFixture(cached, to: cache)
    let app = model(service: AppMockService(releases: [catalogue]), cache: cache)
    await app.selectBrowsePlatform(.iOS)

    #expect(app.availableReleases.count == 1)
    #expect(app.availableReleases[0].downloadURL == catalogue.downloadURL)
    #expect(app.choice(for: catalogue)?.cacheState == .downloaded(localURL))
    #expect(app.displaySize(for: catalogue) == 99)
}

@Test @MainActor func latestCompatibleUsesExactValidatedManagedMobileAsset() async throws {
    let cache = tempCache()
    let compatible = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad12.ipsw")!, checksum: "ipad12-checksum", supportedDevices: ["iPad12,1", "iPad12,2"])
    let ipad11 = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad11.ipsw")!, checksum: "ipad11-checksum", supportedDevices: ["iPad11,1", "iPad11,2", "iPad11,3", "iPad11,4"])
    let ipad13 = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad13.ipsw")!, checksum: "ipad13-checksum", supportedDevices: ["iPad13,1", "iPad13,2"])
    let compatibleURL = try addValidatedCacheFixture(compatible, to: cache)
    _ = try addValidatedCacheFixture(ipad11, to: cache)
    let devices = [
        DFUDevice(family: .iPad, state: .recovery, ecid: "SYNTHETIC-PAD-A", productType: "iPad12,1"),
        DFUDevice(family: .iPad, state: .recovery, ecid: "SYNTHETIC-PAD-B", productType: "iPad12,1")
    ]
    let app = model(service: AppMockService(releases: [ipad13, ipad11, compatible]), devices: devices, cache: cache)
    await app.load(); await app.selectBrowsePlatform(.iPadOS)
    app.selectRelease(ipad13)
    for session in app.deviceSessions.sessions { app.setSessionSelected(session.id, selected: true) }
    await app.useLatestCompatibleFirmwareForSelectedSessions()

    #expect(app.selectedRelease == ipad13)
    #expect(app.imageURL == nil)
    #expect(app.deviceSessions.sessions.allSatisfy {
        $0.selectedRelease == compatible
            && $0.selectedImageURL?.resolvingSymlinksInPath() == compatibleURL.resolvingSymlinksInPath()
            && $0.firmwareState == .validated && $0.canRestore
    })
    #expect(app.batchCoordinator.canStartRestore)
    await app.refreshDiagnosticsAndTarget()
    #expect(app.deviceSessions.sessions.allSatisfy { $0.selectedRelease == compatible && $0.canRestore })
}

@Test @MainActor func latestCompatibleFailsSafelyWhenExactMobileProductIsAbsent() async {
    let ipad11 = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad11.ipsw")!, checksum: "ipad11-checksum", supportedDevices: ["iPad11,1", "iPad11,2", "iPad11,3", "iPad11,4"])
    let ipad13 = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad13.ipsw")!, checksum: "ipad13-checksum", supportedDevices: ["iPad13,1", "iPad13,2"])
    let devices = [
        DFUDevice(family: .iPad, state: .recovery, ecid: "SYNTHETIC-PAD-A", productType: "iPad12,1"),
        DFUDevice(family: .iPad, state: .recovery, ecid: "SYNTHETIC-PAD-B", productType: "iPad12,1")
    ]
    let app = model(service: AppMockService(releases: [ipad13, ipad11]), devices: devices)
    await app.load(); await app.selectBrowsePlatform(.iPadOS)
    app.selectRelease(ipad13)
    for session in app.deviceSessions.sessions { app.setSessionSelected(session.id, selected: true) }

    await app.useLatestCompatibleFirmwareForSelectedSessions()

    #expect(app.selectedRelease == ipad13)
    #expect(app.presentedError == "No compatible Apple restore image was found for iPad12,1.")
    #expect(app.deviceSessions.sessions.allSatisfy {
        $0.selectedRelease == nil && $0.selectedImageURL == nil && !$0.canRestore
            && $0.restoreEligibilityFailure == "No compatible Apple restore image was found for iPad12,1."
    })
    #expect(!app.batchCoordinator.canStartRestore)
}

@Test @MainActor func newlyDiscoveredRecoveryMobileSessionAutoAssignsExactValidatedLatestWithoutSelection() async throws {
    let cache = tempCache()
    let older = IPSWRelease(platform: .iPadOS, version: "26.6", build: "23G70", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad12-older.ipsw")!, checksum: "ipad12-older", supportedDevices: ["iPad12,1", "iPad12,2"])
    let latest = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad12-latest.ipsw")!, checksum: "ipad12-latest", supportedDevices: ["iPad12,1", "iPad12,2"])
    let wrong11 = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad11.ipsw")!, checksum: "ipad11", supportedDevices: ["iPad11,1", "iPad11,2", "iPad11,3", "iPad11,4"])
    let wrong13 = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad13.ipsw")!, checksum: "ipad13", supportedDevices: ["iPad13,1", "iPad13,2"])
    _ = try addValidatedCacheFixture(older, to: cache)
    let latestURL = try addValidatedCacheFixture(latest, to: cache)
    _ = try addValidatedCacheFixture(wrong11, to: cache)
    _ = try addValidatedCacheFixture(wrong13, to: cache)
    let device = DFUDevice(family: .iPad, state: .recovery, ecid: "SYNTHETIC-PAD", productType: "iPad12,1")
    let service = TrackingIPSWService(releases: [wrong13, wrong11, older, latest])
    let app = AppModel(ipswService: service, discovery: AppMockDiscovery(values: [device]), cache: cache, validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)

    await app.load()

    let session = try #require(app.deviceSessions.sessions.first)
    #expect(session.selectedRelease == latest)
    #expect(session.selectedImageURL?.resolvingSymlinksInPath() == latestURL.resolvingSymlinksInPath())
    #expect(session.firmwareState == .validated && session.canRestore)
    #expect(!session.isSelected)
    #expect(service.eventRequests == 0)
}

@Test @MainActor func newlyDiscoveredNormalMobileMayAutoAssignButCannotRestore() async throws {
    let cache = tempCache()
    let release = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad12.ipsw")!, checksum: "ipad12", supportedDevices: ["iPad12,1", "iPad12,2"])
    let cachedURL = try addValidatedCacheFixture(release, to: cache)
    let device = DFUDevice(family: .iPad, state: .normal, ecid: "SYNTHETIC-PAD", productType: "iPad12,1")
    let app = model(service: AppMockService(releases: [release]), devices: [device], cache: cache)

    await app.load()

    let session = try #require(app.deviceSessions.sessions.first)
    #expect(session.selectedRelease == release && session.selectedImageURL == cachedURL)
    #expect(session.firmwareState == .validated)
    #expect(!session.isSelected && !session.canRestore)
    #expect(session.restoreEligibilityFailure == "Restore requires Recovery or DFU mode.")
}

@Test @MainActor func mobileAutoAssignmentLeavesNoCacheWrongProductAndAmbiguousLatestUnassigned() async throws {
    let exactA = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad12-a.ipsw")!, checksum: "ipad12-a", supportedDevices: ["iPad12,1", "iPad12,2"])
    let exactB = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad12-b.ipsw")!, checksum: "ipad12-b", supportedDevices: ["iPad12,1", "iPad12,2"])
    let wrong = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad13.ipsw")!, checksum: "ipad13", supportedDevices: ["iPad13,1", "iPad13,2"])
    let device = DFUDevice(family: .iPad, state: .recovery, ecid: "SYNTHETIC-PAD", productType: "iPad12,1")

    for releases in [[wrong], [exactA], [exactA, exactB]] {
        let cache = tempCache()
        if releases.count == 2 {
            _ = try addValidatedCacheFixture(exactA, to: cache)
            _ = try addValidatedCacheFixture(exactB, to: cache)
        }
        let service = TrackingIPSWService(releases: releases)
        let app = AppModel(ipswService: service, discovery: AppMockDiscovery(values: [device]), cache: cache, validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
        await app.load()
        let session = try #require(app.deviceSessions.sessions.first)
        #expect(session.selectedRelease == nil && session.selectedImageURL == nil)
        #expect(session.firmwareState == .unselected && !session.canRestore && !session.isSelected)
        #expect(service.eventRequests == 0)
    }
}

@Test @MainActor func automaticResolverPreservesManualAssignmentAndLeavesReplacementDeviceUnselected() async throws {
    let cache = tempCache()
    let latest = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad12-latest.ipsw")!, checksum: "ipad12-latest", supportedDevices: ["iPad12,1", "iPad12,2"])
    let manual = IPSWRelease(platform: .iPadOS, version: "26.5", build: "23F79", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad12-manual.ipsw")!, checksum: "ipad12-manual", supportedDevices: ["iPad12,1", "iPad12,2"])
    _ = try addValidatedCacheFixture(latest, to: cache)
    let manualURL = try addValidatedCacheFixture(manual, to: cache)
    let first = DFUDevice(family: .iPad, state: .recovery, ecid: "PAD-ONE", productType: "iPad12,1")
    let second = DFUDevice(family: .iPad, state: .recovery, ecid: "PAD-TWO", productType: "iPad12,1")
    let discovery = AppSequencedDiscovery([[first], [first, second], [first, second]])
    let app = AppModel(ipswService: AppMockService(releases: [manual, latest]), discovery: discovery, cache: cache, validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)

    await app.load()
    let firstID = try #require(app.deviceSessions.sessions.first).id
    app.deviceSessions.setFirmware(for: firstID, release: manual, url: manualURL, validation: .validated)
    app.setSessionSelected(firstID, selected: true)
    await app.refreshDiagnosticsAndTarget()

    let retained = try #require(app.deviceSessions.sessions.first { $0.id == firstID })
    let added = try #require(app.deviceSessions.sessions.first { $0.ecid == "PAD-TWO" })
    #expect(retained.selectedRelease == manual && retained.selectedImageURL == manualURL && retained.isSelected)
    #expect(added.selectedRelease == latest && added.selectedImageURL != nil)
    #expect(!added.isSelected && added.canRestore)

    await app.refreshDiagnosticsAndTarget()
    #expect(app.deviceSessions.sessions.first { $0.id == firstID }?.selectedRelease == manual)
    #expect(app.deviceSessions.sessions.first { $0.ecid == "PAD-TWO" }?.selectedRelease == latest)
}

@Test @MainActor func mobileCachedFirmwareAutoAssignmentDoesNotApplyToMacSessions() async throws {
    let cache = tempCache()
    let release = IPSWRelease(platform: .macOS, version: "26.6.2", build: "25G83", downloadURL: URL(string: "https://updates.cdn-apple.com/mac.ipsw")!, checksum: "mac", supportedDevices: ["Mac14,2"])
    _ = try addValidatedCacheFixture(release, to: cache)
    let mac = DFUDevice(family: .mac, state: .dfu, ecid: "SYNTHETIC-MAC", productType: "Mac14,2")
    let app = model(service: AppMockService(releases: [release]), devices: [mac], cache: cache)

    await app.load()

    let session = try #require(app.deviceSessions.sessions.first)
    #expect(session.selectedRelease == nil && session.selectedImageURL == nil)
    #expect(session.firmwareState == .unselected && !session.isSelected)
}

@Test @MainActor func sameProductsAndBuildWithDifferentAssetsDoNotMerge() async throws {
    let cache = tempCache()
    let cached = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/old.ipsw")!, checksum: "old-checksum", supportedDevices: ["iPad12,1"])
    let catalogue = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/new.ipsw")!, checksum: "new-checksum", supportedDevices: ["iPad12,1"])
    _ = try addValidatedCacheFixture(cached, to: cache)
    let app = model(service: AppMockService(releases: [catalogue]), cache: cache)
    await app.selectBrowsePlatform(.iPadOS)
    #expect(app.availableReleases.count == 2)
    #expect(app.choice(for: cached)?.cacheState != .downloadRequired)
    #expect(app.choice(for: catalogue)?.cacheState == .downloadRequired)
    #expect(FirmwareReleaseKey(cached) != FirmwareReleaseKey(catalogue))
}

@Test @MainActor func mobileBuildVariantsWithDifferentProductsDoNotCollapse() async {
    let ipad12 = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad12.ipsw")!, supportedDevices: ["iPad12,1", "iPad12,2"])
    let ipad16 = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad16.ipsw")!, supportedDevices: ["iPad16,8", "iPad16,9", "iPad16,10", "iPad16,11"])
    let app = model(service: AppMockService(releases: [ipad16, ipad12]))
    await app.selectBrowsePlatform(.iPadOS)
    #expect(app.availableReleases.count == 2)
    #expect(Set(app.availableReleases.map { Set($0.supportedDevices) }) == Set([Set(ipad12.supportedDevices), Set(ipad16.supportedDevices)]))
    #expect(FirmwareReleaseKey(ipad12) != FirmwareReleaseKey(ipad16))
}

@Test @MainActor func appModelAssignsCurrentValidatedIPad121FirmwareOnlyToSelectedRecoverySessions() async throws {
    let cache = tempCache()
    let release = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad12.ipsw")!, supportedDevices: ["iPad12,1", "iPad12,2"])
    let cachedURL = try addValidatedCacheFixture(release, to: cache)
    let devices = [
        DFUDevice(family: .iPad, state: .recovery, ecid: "SYNTHETIC-PAD-ONE", productType: "iPad12,1"),
        DFUDevice(family: .iPad, state: .recovery, ecid: "SYNTHETIC-PAD-TWO", productType: "iPad12,1")
    ]
    let app = model(service: AppMockService(releases: [release]), devices: devices, cache: cache)
    await app.load()
    await app.selectBrowsePlatform(.iPadOS)
    let first = app.deviceSessions.sessions[0].id, second = app.deviceSessions.sessions[1].id
    app.setSessionSelected(first, selected: true)
    app.applyCurrentFirmwareToSelectedSessions()
    #expect(app.deviceSessions.sessions.first { $0.id == first }?.selectedImageURL?.resolvingSymlinksInPath() == cachedURL.resolvingSymlinksInPath())
    #expect(app.deviceSessions.sessions.first { $0.id == first }?.canRestore == true)
    #expect(app.deviceSessions.sessions.first { $0.id == second }?.firmwareState == .validated)
    #expect(app.deviceSessions.sessions.first { $0.id == second }?.isSelected == false)

    app.setSessionSelected(second, selected: true)
    app.applyCurrentFirmwareToSelectedSessions()
    #expect(app.deviceSessions.sessions.allSatisfy { $0.canRestore && $0.selectedImageURL?.resolvingSymlinksInPath() == cachedURL.resolvingSymlinksInPath() })
    #expect(app.batchCoordinator.canStartRestore)
    await app.refreshDiagnosticsAndTarget()
    #expect(app.deviceSessions.sessions.allSatisfy { $0.canRestore && $0.selectedImageURL?.resolvingSymlinksInPath() == cachedURL.resolvingSymlinksInPath() })
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
    await connected.load(); await connected.selectBrowsePlatform(.iOS)
    #expect(Set(connected.availableReleases.map(\.build)) == ["PHONE-OK", "PHONE-NO", "PHONE-UNKNOWN"])
    #expect(connected.choice(for: unknown) != nil)
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
    #expect(app.imageChoices.map(\.release.build) == ["MATCH", "OTHER"])
    #expect(app.imageChoices.first?.compatibility == .compatible(model: "Mac14,2"))
    #expect(app.choice(for: other)?.compatibility == .uncertain)
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
    #expect(value.minimumWidth == 760); #expect(value.minimumHeight == 500)
    #expect(value.maximumWorkspaceWidth == 1160)
    #expect(value.sidebarMinimumWidth == 240); #expect(value.sidebarIdealWidth == 260); #expect(value.sidebarMaximumWidth == 320)
    #expect(value.defaultWidth > value.minimumWidth); #expect(value.defaultHeight > value.minimumHeight)
    #expect(value.maximumWorkspaceWidth > value.defaultWidth)
    #expect(value.defaultWidth >= value.sidebarIdealWidth + value.minimumWidth)
}

@Test func mainLayoutKeepsHeaderOutsideScrollableBoundedWorkspace() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let content = try String(contentsOf: root.appendingPathComponent("Sources/DFUUtilityApp/ContentView.swift"), encoding: .utf8)
    let diagnostics = try String(contentsOf: root.appendingPathComponent("Sources/DFUUtilityApp/DiagnosticsView.swift"), encoding: .utf8)
    let about = try String(contentsOf: root.appendingPathComponent("Sources/DFUUtilityApp/AboutView.swift"), encoding: .utf8)
    #expect(content.contains("NavigationSplitView")); #expect(content.contains("Section(\"Devices\")"))
    #expect(content.contains("navigationSplitViewColumnWidth")); #expect(content.contains("sidebarIdealWidth"))
    #expect(content.contains("Section(\"Workflows\")")); #expect(content.contains("Section(\"Library\")"))
    #expect(content.contains("workspaceScroll")); #expect(content.contains("Text(\"Restore & Revive\")"))
    #expect(content.contains("firmwareLibraryContent(includeBatch: false)"))
    #expect(about.contains("View License"))
    #expect(diagnostics.contains("Show Technical Details"))
    #expect(!content.contains("workspaceHeader"))
    #expect(!content.contains("scaleEffect")); #expect(!content.contains("MagnificationGesture"))
    #expect(content.contains("NSApplication.didBecomeActiveNotification"))
    #expect(content.contains("NSApplication.willResignActiveNotification"))
    #expect(!content.contains("task(id: scenePhase)"))
    #expect(content.contains("Firmware for this device"))
    #expect(content.contains("Choose Firmware…")); #expect(content.contains("Choose Different Firmware…"))
    #expect(content.contains("Use Library Firmware for Selected"))
    #expect(!content.contains("Assigned Firmware")); #expect(!content.contains("Assign Current Library Firmware")); #expect(!content.contains("Use Current Firmware for Selected"))
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

@Test @MainActor func deviceCaptureIsReadOnlyStableAndOptIn() {
    let capture = DeviceCaptureSession()
    let device = DFUDevice(family: .iPad, state: .recovery, model: "iPad12,1", ecid: "0xABC", serialNumber: "SERIAL-1")
    capture.observe([device])
    #expect(capture.records.isEmpty)
    capture.isAutomaticCaptureEnabled = true
    capture.observe([device])
    capture.observe([device])
    #expect(capture.records.count == 1)
    #expect(capture.records[0].ecid == "0xABC")
}

@Test @MainActor func deviceCaptureEnrichesWithoutChangingIdentityOrBatchState() {
    let capture = DeviceCaptureSession()
    let first = DFUDevice(family: .mac, state: .normal, model: "Mac14,2", ecid: "ECID-1")
    let enriched = DFUDevice(family: .mac, state: .dfu, model: "Mac14,2", identifier: "UDID-1", ecid: "ECID-1", serialNumber: "SERIAL-1")
    let record = capture.capture(first, assetTag: "  BENCH-1 ")
    capture.capture(enriched)
    #expect(capture.records.count == 1)
    #expect(capture.records[0].id == record.id)
    #expect(capture.records[0].serialNumber == "SERIAL-1")
    #expect(capture.records[0].state == .dfu)
    #expect(capture.records[0].assetTag == "BENCH-1")
}

@Test @MainActor func deviceCaptureSeparatesDifferentAndUnaddressableDevices() {
    let capture = DeviceCaptureSession()
    capture.capture(DFUDevice(family: .iPhone, state: .normal, model: "iPhone7,2", ecid: "ECID-A"))
    capture.capture(DFUDevice(family: .iPhone, state: .normal, model: "iPhone7,2", ecid: "ECID-B"))
    capture.capture(DFUDevice(family: .iPad, state: .recovery, model: "iPad12,1"))
    capture.capture(DFUDevice(family: .iPad, state: .recovery, model: "iPad12,1"))
    #expect(capture.records.count == 4)
}

@Test @MainActor func deviceCaptureCSVIsOrderedEscapedAndClearsOnlyCaptureRecords() {
    let capture = DeviceCaptureSession()
    let record = DeviceCaptureRecord(capturedAt: Date(timeIntervalSince1970: 0), device: DFUDevice(family: .mac, state: .dfu, model: "Mac14,2", ecid: "ECID,1", serialNumber: "SERIAL\"1"), assetTag: "Tag\n1")
    capture.capture(DFUDevice(family: .mac, state: .dfu, model: "Mac14,2", ecid: "ECID,1", serialNumber: "SERIAL\"1"), assetTag: "Tag\n1")
    let csv = capture.csvString()
    #expect(csv.hasPrefix("Captured At,Asset Tag,Family,Display Name,Product Identifier,Serial Number,ECID,UDID,State\r\n"))
    #expect(csv.contains("\"Tag\n1\"")); #expect(csv.contains("\"SERIAL\"\"1\"")); #expect(csv.contains("\"ECID,1\""))
    #expect(DeviceCaptureQRCode.payload(for: record) == "SERIAL\"1")
    let unavailable = DeviceCaptureRecord(device: DFUDevice(family: .mac, state: .dfu, model: "Mac14,2"))
    #expect(DeviceCaptureQRCode.payload(for: unavailable) == nil)
    #expect(!unavailable.copyAllText().contains("Serial:")); #expect(!unavailable.copyAllText().contains("ECID:")); #expect(!unavailable.copyAllText().contains("UDID:"))
    capture.clear(); #expect(capture.records.isEmpty)
}

@Test @MainActor func deviceCaptureDoesNotChangeBatchSelectionOrStartOperation() {
    let app = model(service: AppMockService())
    let device = DFUDevice(family: .iPhone, state: .recovery, model: "iPhone7,2", ecid: "ECID-CAPTURE")
    app.deviceSessions.reconcile([device])
    guard let session = app.deviceSessions.sessions.first else { Issue.record("Expected a session") ; return }
    app.setSessionSelected(session.id, selected: true)
    app.selectTarget(ecid: "ECID-CAPTURE")
    #expect(app.captureSession.capture(device).ecid == "ECID-CAPTURE")
    #expect(app.deviceSessions.sessions.first?.isSelected == true)
    #expect(app.restoreState == .idle)
}

@Test func deviceCaptureDetailMakesIdentifierAndQRAvailabilityExplicit() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let content = try String(contentsOf: root.appendingPathComponent("Sources/DFUUtilityApp/DeviceCaptureView.swift"), encoding: .utf8)
    #expect(content.contains("GroupBox(\"Identifiers\")"))
    #expect(content.contains("Not available"))
    #expect(content.contains("GroupBox(\"QR Code\")"))
    #expect(content.contains("Serial number unavailable for this device."))
    #expect(content.contains("DeviceCaptureQRCode.payload(for: record)"))
}

@Test func visualParityUsesSharedPanelsAndResponsiveActions() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let content = try String(contentsOf: root.appendingPathComponent("Sources/DFUUtilityApp/ContentView.swift"), encoding: .utf8)
    let styles = try String(contentsOf: root.appendingPathComponent("Sources/DFUUtilityApp/VisualComponents.swift"), encoding: .utf8)
    #expect(styles.contains("struct WorkspacePanel")); #expect(styles.contains("struct StatusBadge")); #expect(styles.contains("struct ActionTile"))
    #expect(content.contains("LazyVGrid(columns: [GridItem(.adaptive(minimum: 220)"))
    #expect(content.contains("DeviceStateBadge(state: session.device.state)"))
    #expect(content.contains("Restore using selected firmware.")); #expect(content.contains("Put this Mac into DFU mode."))
    #expect(!content.contains("Button(\"Done\")"))
    let capture = try String(contentsOf: root.appendingPathComponent("Sources/DFUUtilityApp/DeviceCaptureView.swift"), encoding: .utf8)
    #expect(capture.contains("tableHeight")); #expect(capture.contains("WorkspacePanel(\"Asset Tag\"")); #expect(capture.contains("WorkspacePanel(\"Copy Identifiers\""))
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
    await app.load(); await app.refreshManagedCache(); let entry = try #require(app.managedCacheEntries.first); let id = try #require(app.detailedSession?.id); await app.prepareFirmwareChooser(for: id); app.choosePendingRelease(release); app.confirmPendingRelease(for: id); app.restoreConfirmed()
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
    let app = model(service: AppMockService(releases: []), devices: [DFUDevice(state: .dfu, ecid: "MAC")]); await app.refreshDiagnosticsAndTarget()
    #expect(!app.canRestore); #expect(app.restoreUnavailableMessage == "No firmware has been chosen for this device.")
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
    let app = model(devices: [DFUDevice(state: .dfu, ecid: "MAC")]); await app.refreshDiagnosticsAndTarget(); let id = app.deviceSessions.sessions[0].id; app.deviceSessions.setFirmware(for: id, release: nil, url: testURL, validation: .validated); #expect(app.canRestore)
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
    #expect(app.restoreSectionTitle == "Firmware Library")
    #expect(app.selectedRelease == nil)
    #expect(app.prepareMobileDFUAssistant())
    #expect(app.mobileDFUAssistant?.profile.productType == "iPad7,11")
    #expect(app.mobileDFUAssistant?.profile.powerButtonName == "Top")
    #expect(app.mobileDFUAssistant?.profile.secondaryButtonName == "Home")
    app.dismissMobileDFUAssistant()
}

@Test @MainActor func switchingTargetsDoesNotReplaceIndependentLibraryState() async {
    let phoneRelease = IPSWRelease(platform: .iOS, version: "12.5.8", build: "16H81", downloadURL: URL(string: "https://updates.cdn-apple.com/iphone.ipsw")!, supportedDevices: ["iPhone7,2"])
    let padRelease = IPSWRelease(platform: .iPadOS, version: "18.7.10", build: "22H374", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad.ipsw")!, supportedDevices: ["iPad7,11"])
    let phone = DFUDevice(family: .iPhone, state: .normal, ecid: "0xPHONE", productType: "iPhone7,2")
    let pad = DFUDevice(family: .iPad, state: .normal, ecid: "0xPAD", productType: "iPad7,11")
    let service = TargetAwareIPSWService(phoneRelease: phoneRelease, padRelease: padRelease)
    let discovery = AppSequencedDiscovery([[phone], [pad], [phone]])
    let app = AppModel(ipswService: service, discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, privilegeMode: .community)

    await app.load()
    #expect(app.target?.family == .iPhone); #expect(app.selectedRelease == nil); #expect(app.restoreSectionTitle == "Firmware Library")
    await app.refreshDiagnosticsAndTarget()
    #expect(app.target?.family == .iPad); #expect(app.selectedRelease == nil); #expect(app.restoreSectionTitle == "Firmware Library")
    #expect(app.canUseMobileDFUAssistant); #expect(app.targetDFUGuidance == .guidedPhysicalButtons)
    await app.refreshDiagnosticsAndTarget()
    #expect(app.target?.family == .iPhone); #expect(app.selectedRelease == nil); #expect(app.restoreSectionTitle == "Firmware Library")
    #expect(service.families.filter { $0 == .mac }.count == 1)
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
    let app = model(service: AppMockService(releases: [wrong, compatible]), devices: [target], cache: cache); await app.load(); await app.selectBrowsePlatform(.iPadOS)
    #expect(Set(app.imageChoices.map(\.release.build)) == ["22H374", "WRONG"]); #expect(app.detailedSession?.selectedRelease == compatible); #expect(app.canRestore)
    let wrongOnly = model(service: AppMockService(releases: [wrong]), devices: [target], cache: tempCache()); await wrongOnly.load(); await wrongOnly.selectBrowsePlatform(.iPadOS)
    #expect(wrongOnly.imageChoices.map(\.release.build) == ["WRONG"]); let id = try #require(wrongOnly.detailedSession?.id); await wrongOnly.prepareFirmwareChooser(for: id); #expect(wrongOnly.firmwareChoices(for: id).isEmpty); #expect(!wrongOnly.canRestore)
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

@Test @MainActor func continuousDiscoveryAddsAnExcludedFifthDeviceWithoutExecutingWork() async {
    let firstFour = (1...4).map { DFUDevice(family: .iPhone, state: .recovery, ecid: "PHONE-\($0)", productType: "iPhone15,2") }
    let fifth = DFUDevice(family: .iPad, state: .recovery, ecid: "PAD-5", productType: "iPad13,18")
    let discovery = AppSequencedDiscovery([firstFour, firstFour + [fifth]])
    let restore = CountingRestore(), service = TrackingIPSWService(releases: [])
    let app = AppModel(ipswService: service, discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: restore, dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    await app.load()
    for session in app.deviceSessions.sessions { app.setSessionSelected(session.id, selected: true) }
    let frozen = app.deviceSessions.freezeSelectedBatch().map(\.id)
    await app.pollDeviceDiscovery()
    let added = try! #require(app.deviceSessions.sessions.first { $0.ecid == "PAD-5" })
    #expect(!added.isSelected)
    #expect(app.deviceSessions.activeBatchIDs == frozen)
    #expect(!app.deviceSessions.activeBatchIDs.contains(added.id))
    #expect(DeviceSessionPresentation(session: added, activeBatchIDs: frozen, currentBatchID: frozen.first, batchIsRunning: true).batchMembership == .notInCurrentBatch)
    #expect(restore.callCount == 0)
    #expect(service.eventRequests == 0)
}

@Test @MainActor func pollingDuringRealFrozenBatchCannotAddOrExecuteReplacement() async throws {
    let original = DFUDevice(family: .iPhone, state: .recovery, ecid: "ORIGINAL", productType: "iPhone15,2")
    let newcomer = DFUDevice(family: .iPhone, state: .recovery, ecid: "NEWCOMER", productType: "iPhone15,2")
    let discovery = AppSequencedDiscovery([[original], [original, newcomer]])
    let restore = CountingHoldingRestore()
    let app = AppModel(ipswService: AppMockService(releases: []), discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: restore, dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, reconnectAttempts: 1, reconnectInterval: .zero)
    await app.load()
    let originalID = try #require(app.deviceSessions.sessions.first?.id)
    app.deviceSessions.setFirmware(for: originalID, release: nil, url: URL(fileURLWithPath: "/validated.ipsw"), validation: .validated)
    app.setSessionSelected(originalID, selected: true)
    app.startBatchRestore()
    try await Task.sleep(for: .milliseconds(30))
    let frozen = app.batchCoordinator.frozenTargetIDs
    #expect(app.batchCoordinator.isRunning); #expect(restore.callCount == 1)
    await app.pollDeviceDiscovery()
    let added = try #require(app.deviceSessions.sessions.first { $0.ecid == "NEWCOMER" })
    #expect(!added.isSelected); #expect(app.batchCoordinator.frozenTargetIDs == frozen); #expect(!frozen.contains(added.id))
    #expect(restore.callCount == 1)
    app.stopBatchAfterCurrentTarget()
    while app.batchCoordinator.isRunning { try await Task.sleep(for: .milliseconds(10)) }
    #expect(restore.callCount == 1)
}

@Test @MainActor func continuousDiscoveryAutoAssignsOnlyExistingValidatedCompatibleMobileCache() async throws {
    let release = IPSWRelease(platform: .iOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://example.invalid/phone.ipsw")!, supportedDevices: ["iPhone15,2"])
    let cache = tempCache(); let cached = try addValidatedCacheFixture(release, to: cache)
    let phone = DFUDevice(family: .iPhone, state: .normal, ecid: "NEW-PHONE", productType: "iPhone15,2")
    let service = TrackingIPSWService(releases: [release])
    let app = AppModel(ipswService: service, discovery: AppSequencedDiscovery([[], [phone]]), cache: cache, validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: CountingRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    await app.load(); await app.pollDeviceDiscovery()
    let session = try #require(app.deviceSessions.sessions.first)
    #expect(session.selectedRelease == release); #expect(session.selectedImageURL?.resolvingSymlinksInPath() == cached.resolvingSymlinksInPath())
    #expect(session.firmwareState == .validated); #expect(!session.isSelected); #expect(!session.canRestore)
    #expect(service.eventRequests == 0)
}

@Test @MainActor func continuousDiscoveryLeavesNewDeviceUnassignedWithoutValidatedCompatibleCache() async throws {
    let incompatible = IPSWRelease(platform: .iOS, version: "26.6.1", build: "OTHER", downloadURL: URL(string: "https://example.invalid/other.ipsw")!, supportedDevices: ["iPhone16,1"])
    let phone = DFUDevice(family: .iPhone, state: .recovery, ecid: "NEW-PHONE", productType: "iPhone15,2")
    let service = TrackingIPSWService(releases: [incompatible])
    let app = AppModel(ipswService: service, discovery: AppSequencedDiscovery([[], [phone]]), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: CountingRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    await app.load(); await app.pollDeviceDiscovery()
    let session = try #require(app.deviceSessions.sessions.first)
    #expect(session.firmwareState == .unselected); #expect(session.selectedRelease == nil); #expect(!session.isSelected); #expect(!session.canRestore)
    #expect(service.eventRequests == 0)
}

@Test @MainActor func continuousDiscoveryPreservesSameIdentityAndOwnedSessionStateAcrossOrdering() async throws {
    let a = DFUDevice(family: .iPhone, state: .recovery, ecid: "A", productType: "iPhone15,2")
    let b = DFUDevice(family: .iPad, state: .recovery, ecid: "B", productType: "iPad13,18")
    let app = AppModel(ipswService: AppMockService(releases: []), discovery: AppSequencedDiscovery([[a, b], [b, a]]), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: CountingRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    await app.load()
    let original = try #require(app.deviceSessions.sessions.first { $0.ecid == "A" })
    app.setSessionSelected(original.id, selected: true)
    app.deviceSessions.update(original.id) { $0.operationState = .failed("Owned result"); $0.generation = 9 }
    await app.pollDeviceDiscovery()
    let retained = try #require(app.deviceSessions.sessions.first { $0.ecid == "A" })
    #expect(retained.id == original.id); #expect(retained.isSelected); #expect(retained.generation == 9); #expect(retained.operationState == .failed("Owned result"))
}

@Test @MainActor func benchDiscoveryLifecycleIsIdempotentAndStopsPolling() async {
    let discovery = CountingAppDiscovery([])
    let app = AppModel(ipswService: AppMockService(), discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: CountingRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    app.startBenchDiscovery(interval: .seconds(10))
    app.startBenchDiscovery(interval: .seconds(10))
    #expect(app.isBenchDiscoveryRunning)
    try? await Task.sleep(for: .milliseconds(30))
    let countAtStop = app.benchDiscoveryPollCount
    #expect(countAtStop == 1); #expect(discovery.callCount == 1)
    app.stopBenchDiscovery(); #expect(!app.isBenchDiscoveryRunning)
    try? await Task.sleep(for: .milliseconds(40))
    #expect(app.benchDiscoveryPollCount == countAtStop)
}

@Test @MainActor func benchDiscoveryContinuesAfterErrorAndPreservesLastValidSnapshot() async throws {
    let recovery = DFUDevice(family: .iPad, state: .recovery, ecid: "PAD", productType: "iPad13,18")
    let dfu = DFUDevice(family: .iPad, state: .dfu, ecid: "PAD", productType: "iPad13,18")
    let second = DFUDevice(family: .iPhone, state: .recovery, ecid: "PHONE", productType: "iPhone15,2")
    let discovery = ResultSequencedDiscovery([.success([recovery]), .failure(DFUError.commandFailed(command: "fixture", status: 1, output: "transient")), .success([dfu, second])])
    let restore = CountingRestore(), service = TrackingIPSWService(releases: [])
    let app = AppModel(ipswService: service, discovery: discovery, cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: restore, dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    await app.pollDeviceDiscovery()
    let id = try #require(app.deviceSessions.sessions.first?.id)
    app.startBenchDiscovery(interval: .milliseconds(30))
    try await Task.sleep(for: .milliseconds(10))
    #expect(app.deviceSessions.sessions.count == 1); #expect(app.deviceSessions.sessions[0].id == id); #expect(app.deviceSessions.sessions[0].device.state == .recovery)
    for _ in 0..<100 {
        if app.deviceSessions.sessions.count == 2 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    app.stopBenchDiscovery()
    #expect(app.deviceSessions.sessions.count == 2)
    #expect(app.deviceSessions.sessions.first { $0.id == id }?.device.state == .dfu)
    #expect(app.deviceSessions.sessions.first { $0.ecid == "PHONE" }?.isSelected == false)
    #expect(restore.callCount == 0); #expect(service.eventRequests == 0)
}

@Test @MainActor func benchDiscoveryIsDisabledInHardwareInertModes() {
    for app in [
        AppModel(ipswService: AppMockService(), discovery: CountingAppDiscovery([]), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: CountingRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, isDemoMode: true),
        AppModel(ipswService: AppMockService(), discovery: CountingAppDiscovery([]), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: CountingRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, isUpdateTestMode: true),
        AppModel(ipswService: AppMockService(), discovery: CountingAppDiscovery([]), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: CountingRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false, isDemoMode: true, screenshotScenario: "normal-mac")
    ] {
        app.startBenchDiscovery(interval: .milliseconds(1))
        #expect(!app.isBenchDiscoveryRunning); #expect(app.benchDiscoveryPollCount == 0)
    }
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

@Test @MainActor func sessionPresentationRemainsCanonicalAcrossDeviceCountChanges() async {
    let mac = DFUDevice(family: .mac, state: .dfu, ecid: "MAC-A", productType: "Mac14,2")
    let phone = DFUDevice(family: .iPhone, state: .recovery, ecid: "PHONE-B", productType: "iPhone15,2")
    let discovery = AppSequencedDiscovery([[mac], [mac, phone], [mac]])
    let release = IPSWRelease(platform: .macOS, version: "26.6.2", build: "25G83", downloadURL: URL(string: "https://updates.cdn-apple.com/mac.ipsw")!, supportedDevices: ["Mac14,2"])
    let cache = tempCache(), cachedURL = try! addValidatedCacheFixture(release, to: cache)
    let app = AppModel(ipswService: AppMockService(releases: [release]), discovery: discovery, cache: cache, validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: AppMockDFU(), operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)

    await app.load()
    #expect(app.showsSessionPresentation && app.deviceSessions.sessions.count == 1)
    let macID = app.deviceSessions.sessions[0].id
    app.setSessionSelected(macID, selected: true)
    app.applyCurrentFirmwareToSelectedSessions()
    #expect(app.deviceSessions.sessions[0].isSelected)
    #expect(app.deviceSessions.sessions[0].selectedImageURL?.resolvingSymlinksInPath() == cachedURL.resolvingSymlinksInPath())
    #expect(app.deviceSessions.sessions[0].canRestore)
    #expect(app.batchCoordinator.canStartRestore)

    await app.refreshDiagnosticsAndTarget()
    #expect(app.showsSessionPresentation && app.deviceSessions.sessions.count == 2)
    #expect(app.deviceSessions.sessions.first { $0.id == macID }?.isSelected == true)
    #expect(app.deviceSessions.sessions.first { $0.ecid == "PHONE-B" }?.isSelected == false)

    await app.refreshDiagnosticsAndTarget()
    #expect(app.showsSessionPresentation && app.deviceSessions.sessions.count == 1)
    #expect(app.deviceSessions.sessions[0].id == macID)
    #expect(app.deviceSessions.sessions[0].isSelected && app.deviceSessions.sessions[0].canRestore)
}

@Test func canonicalSessionUIHasNoDeviceCountLayoutFork() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let content = try String(contentsOf: root.appendingPathComponent("Sources/DFUUtilityApp/ContentView.swift"), encoding: .utf8)
    #expect(content.contains("if model.showsSessionPresentation"))
    #expect(content.contains("Connected target"))
    #expect(!content.contains("Multiple targets detected"))
    #expect(content.contains("Previous batch complete"))
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
    let app = model(service: AppMockService(releases: [wrong, compatible]), devices: [target], cache: cache); await app.load(); await app.selectBrowsePlatform(.iOS)
    #expect(Set(app.imageChoices.map(\.release.build)) == ["23G83", "23G84"]); #expect(app.canRestore)
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
private final class ResultSequencedDiscovery: @unchecked Sendable, DeviceDiscovering {
    private let lock = NSLock(); private var results: [Result<[DFUDevice], Error>]
    init(_ results: [Result<[DFUDevice], Error>]) { self.results = results }
    func devices() throws -> [DFUDevice] {
        try lock.withLock {
            let result = results.count > 1 ? results.removeFirst() : (results.first ?? .success([]))
            return try result.get()
        }
    }
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

    await app.refreshDiagnosticsAndTarget(); let id = app.deviceSessions.sessions[0].id; app.deviceSessions.setFirmware(for: id, release: nil, url: testURL, validation: .validated); #expect(app.canRestore)
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

@Test @MainActor func missingFinalVDMReplyIsActionableButNeverPresentedAsSuccess() async {
    let raw = "Looking for HPM devices...\nFound: IOService:/fixture\nUnlocking... OK\nEntering DBMa mode... Status: DBMa\nDid not get a reply to VDM"
    let transition = MacVDMToolFailure.classify(status: 255, output: raw)
    let logger = AppMockLogger()
    let target = DFUDevice(state: .normal, model: "MacBookPro21,6", ecid: "0xSYNTHETIC")
    let app = AppModel(ipswService: AppMockService(), discovery: AppMockDiscovery(values: [target]), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: AppMockRestore(), dfuController: SequencedDFUFailure([transition]), operationLogger: logger, requiresPrivilegedHelperSetup: false)
    app.dfuVerificationDuration = .milliseconds(30)
    app.dfuVerificationInterval = .milliseconds(5)

    await app.refreshDiagnosticsAndTarget()
    await app.enterDFU()

    if case .failed(let message) = app.restoreState {
        #expect(message.contains("may already be in DFU"))
        #expect(message.contains("click Refresh"))
        #expect(message.contains("reconnect the cable"))
        #expect(!message.contains("Transition result: success"))
    } else { Issue.record("A missing final VDM reply must remain a failure") }
    let log = logger.messages.joined(separator: "\n")
    #expect(log.contains("HPM unlock and DBMa transition completed"))
    #expect(log.contains("DFU state remains unverified until rediscovery"))
}

@Test @MainActor func missingReplyVerificationRequiresFreshSameECIDDFU() async {
    let raw = "Looking for HPM devices...\nFound: IOService:/fixture\nUnlocking... OK\nEntering DBMa mode... Status: DBMa\nDid not get a reply to VDM"
    let normal = DFUDevice(state: .normal, model: "Mac14,2", ecid: "0xABC")
    let outcomes: [[DFUDevice]] = [[], [normal], [DFUDevice(state: .recovery, ecid: "0xABC")], [DFUDevice(state: .dfu, ecid: "0xOTHER")], [DFUDevice(state: .dfu, ecid: "0xabc")]]
    for (index, outcome) in outcomes.enumerated() {
        let controller = SequencedDFUFailure([MacVDMToolFailure.classify(status: 255, output: raw)])
        let restore = CountingRestore(), service = TrackingIPSWService(releases: [])
        let app = AppModel(ipswService: service, discovery: AppSequencedDiscovery([[normal], [], outcome]), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: restore, dfuController: controller, operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
        #expect(app.dfuVerificationDuration == .seconds(30))
        app.dfuVerificationDuration = .milliseconds(100)
        app.dfuVerificationInterval = .milliseconds(10)
        await app.refreshDiagnosticsAndTarget()
        await app.enterDFU()
        if index == outcomes.count - 1 {
            guard case .completed(let message) = app.restoreState else { Issue.record("Same ECID DFU should verify"); continue }
            #expect(message.contains("subsequently detected this Mac")); #expect(app.presentedError == nil)
        } else {
            guard case .failed(let message) = app.restoreState else { Issue.record("Unverified outcome must fail"); continue }
            #expect(message.contains("Accessory authorization may delay detection"))
        }
        #expect(controller.callCount == 1); #expect(restore.callCount == 0); #expect(service.eventRequests == 0)
    }
}

@Test @MainActor func cancelledDFUVerificationCannotPublishLateSuccess() async {
    let raw = "Unlocking... OK\nEntering DBMa mode... Status: DBMa\nDid not get a reply to VDM"
    let normal = DFUDevice(state: .normal, model: "Mac14,2", ecid: "0xABC")
    let controller = SequencedDFUFailure([MacVDMToolFailure.classify(status: 255, output: raw)])
    let app = AppModel(ipswService: AppMockService(), discovery: AppSequencedDiscovery([[normal], [], [DFUDevice(state: .dfu, ecid: "0xABC")]]), cache: tempCache(), validator: AppMockValidator(valid: true), diagnostics: AppMockDiagnostics(), restoreEngine: CountingRestore(), dfuController: controller, operationLogger: noOpLogger, requiresPrivilegedHelperSetup: false)
    await app.refreshDiagnosticsAndTarget()
    let operation = Task { await app.enterDFU() }
    #expect(await waitForRestoreState(app) { if case .running(_, "Checking for DFU…", _, _, _) = $0 { true } else { false } })
    #expect(AppModel.accessoryDFUGuidance.contains("If macOS asks"))
    app.cancelMacDFUVerification()
    let cancelled = app.restoreState
    await operation.value
    #expect(app.restoreState == cancelled); #expect(controller.callCount == 1)
}

@Test func missingReplyEvidenceDoesNotIncludeGenericOrIncompleteFailures() {
    for output in ["exit 255", "Did not get a reply to VDM", "Unlocking... OK\nDid not get a reply to VDM", "Entering DBMa mode... Status: DBMa\nDid not get a reply to VDM"] {
        let failure = MacVDMToolFailure.classify(status: 255, output: output)
        #expect(!failure.reachedDBMaWithoutFinalReply)
        #expect(failure.recoverySuggestion?.contains("Accessory authorization") != true)
    }
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
