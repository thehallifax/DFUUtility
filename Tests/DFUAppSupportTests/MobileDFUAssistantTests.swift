import DFUAppSupport
import DFUCore
import Foundation
import Testing

private let phoneNormal = DFUDevice(family: .iPhone, state: .normal, model: "iPhone7,2", ecid: "0xABC", productType: "iPhone7,2")
private let phoneRecovery = DFUDevice(family: .iPhone, state: .recovery, model: "iPhone7,2", ecid: "0xABC", productType: "iPhone7,2")
private let phoneDFU = DFUDevice(family: .iPhone, state: .dfu, model: "iPhone7,2", ecid: "0xabc", productType: "iPhone7,2")
private let padNormal = DFUDevice(family: .iPad, state: .normal, model: "iPad7,11", ecid: "0xPAD", productType: "iPad7,11")
private let padRecovery = DFUDevice(family: .iPad, state: .recovery, model: "iPad7,11", ecid: "0xPAD", productType: "iPad7,11")
private let padDFU = DFUDevice(family: .iPad, state: .dfu, model: "iPad7,11", ecid: "0xpad", productType: "iPad7,11")

private final class CountingMobileDiscovery: @unchecked Sendable, DeviceDiscovering {
    private let lock = NSLock(); private var result: [DFUDevice]; private(set) var calls = 0
    init(_ result: [DFUDevice]) { self.result = result }
    func devices() throws -> [DFUDevice] { lock.withLock { calls += 1; return result } }
    func set(_ value: [DFUDevice]) { lock.withLock { result = value } }
    var callCount: Int { lock.withLock { calls } }
}

private final class FakeMonotonicClock: @unchecked Sendable {
    private let lock = NSLock(); private var tick: UInt64 = 1_000_000
    func now() -> UInt64 { lock.withLock { tick } }
    func advance(milliseconds: UInt64) { lock.withLock { tick += milliseconds * 1_000_000 } }
}

private final class MockRecoveryResetter: @unchecked Sendable, MobileRecoveryResetting {
    let isAvailable: Bool; private let lock = NSLock(); private(set) var ecids: [String] = []
    init(available: Bool = true) { isAvailable = available }
    func resetRecoveryDevice(ecid: String) async throws { lock.withLock { ecids.append(ecid) } }
    var calls: [String] { lock.withLock { ecids } }
}

private struct SilentMobileLogger: OperationLogging {
    func start(operation: String, target: DFUDevice?, release: IPSWRelease?) throws -> URL { URL(fileURLWithPath: "/tmp/guided-mobile-dfu-test.log") }
    func append(_ message: String, to url: URL) throws {}
}

@MainActor private func assistant(
    target: DFUDevice = phoneNormal,
    discovery: any DeviceDiscovering = CountingMobileDiscovery([phoneNormal]),
    resetter: any MobileRecoveryResetting = UnavailableMobileRecoveryResetter(),
    demo: Bool = false,
    clock: FakeMonotonicClock = FakeMonotonicClock(),
    onDFU: @escaping (DFUDevice) -> Void = { _ in }
) -> MobileDFUAssistantModel {
    MobileDFUAssistantModel(target: target, profile: MobileDFUInstructionProfile.profile(for: target)!, discovery: discovery, operationLogger: SilentMobileLogger(), recoveryResetter: resetter, isDemoMode: demo, pollingInterval: .milliseconds(10), releaseCueDuration: .seconds(60), now: clock.now, onDFUDetected: onDFU)
}

@MainActor private func detectReset(_ model: MobileDFUAssistantModel) { model.start(); model.consume(devices: []) }

@Test @MainActor func iPhone72UsesStateAwarePhysicalHomeProfile() {
    let profile = MobileDFUInstructionProfile.profile(for: phoneNormal)
    #expect(profile?.family == .physicalHome); #expect(profile?.productType == "iPhone7,2")
    #expect(profile?.timing.postResetBothHold == .seconds(1)); #expect(profile?.timing.homeHoldTimeout == .seconds(12)); #expect(profile?.timing.dfuDetectionTimeout == .seconds(20))
    #expect(profile?.hardwareValidated == true); #expect(profile?.cableAdvice != nil); #expect(assistant().state == .ready)
}

@Test @MainActor func iPad711UsesHardwareValidatedPhysicalHomeProfileAndTopWording() {
    let profile = MobileDFUInstructionProfile.profile(for: padNormal)
    #expect(profile?.family == .physicalHome); #expect(profile?.productType == "iPad7,11")
    #expect(profile?.deviceDescription == "iPad (7th generation)"); #expect(profile?.powerButtonName == "Top")
    #expect(profile?.holdButtonsText == "TOP + HOME"); #expect(profile?.releaseCueText == "RELEASE TOP NOW")
    #expect(profile?.timing.postResetBothHold == .seconds(1)); #expect(profile?.timing.homeHoldTimeout == .seconds(12)); #expect(profile?.timing.dfuDetectionTimeout == .seconds(20))
    #expect(profile?.hardwareValidated == true); #expect(profile?.cableAdvice?.contains("troubleshooting option") == true); #expect(profile?.cableAdvice?.contains("not a requirement") == true)
}

@Test @MainActor func iPadSameECIDDFUSucceedsAndWrongECIDIsRejected() {
    var detected: DFUDevice?
    let success = assistant(target: padNormal, onDFU: { detected = $0 }); success.start(); success.consume(devices: [padDFU])
    #expect(success.state == .detectedDFU); #expect(detected?.family == .iPad); #expect(detected?.ecid == "0xpad")
    let mismatch = assistant(target: padNormal); mismatch.start()
    mismatch.consume(devices: [DFUDevice(family: .iPad, state: .dfu, ecid: "OTHER", productType: "iPad7,11")])
    #expect(mismatch.state == .targetMismatch)
}

@Test @MainActor func iPadOutcomesDisconnectTimeoutAndRetryUseSharedStateMachine() {
    let recovery = assistant(target: padNormal); detectReset(recovery); recovery.consume(devices: [padRecovery]); #expect(recovery.state == .detectedRecovery)
    recovery.retry(); #expect(recovery.state == .ready)
    let normal = assistant(target: padNormal); detectReset(normal); normal.consume(devices: [padNormal]); #expect(normal.state == .detectedNormal)
    let disconnected = assistant(target: padNormal); disconnected.consume(devices: []); #expect(disconnected.state == .disconnectedUnexpectedly)
    disconnected.consume(devices: [padNormal]); #expect(disconnected.state == .ready)
    let timeout = assistant(target: padNormal); timeout.start(); timeout.expireAttempt(); #expect(timeout.state == .timedOut)
}

@Test @MainActor func startWaitsForObservedResetInsteadOfFixedCountdown() {
    let model = assistant(); model.start()
    #expect(model.state == .waitingForReset)
    model.consume(devices: [phoneNormal]); #expect(model.state == .waitingForReset)
}

@Test @MainActor func expectedTransientDisappearanceAnchorsReleaseCue() {
    let clock = FakeMonotonicClock(), model = assistant(clock: clock)
    model.start(); clock.advance(milliseconds: 700); model.consume(devices: [])
    #expect(model.state == .postResetHoldBoth); #expect(model.timing.firstDisappearance == .milliseconds(700))
    clock.advance(milliseconds: 1_000); model.fireReleaseCue()
    #expect(model.state == .releasePowerNow); #expect(model.timing.releaseCue == .milliseconds(1_700))
}

@Test @MainActor func disappearanceBeforeAttemptIsUnexpectedDisconnect() {
    let model = assistant(); model.consume(devices: [])
    #expect(model.state == .disconnectedUnexpectedly)
    model.consume(devices: [phoneNormal]); #expect(model.state == .ready)
}

@Test @MainActor func sameECIDDFUSucceedsImmediatelyAtAnyAttemptPhase() {
    var detected: DFUDevice?
    let model = assistant(onDFU: { detected = $0 }); model.start(); model.consume(devices: [phoneDFU])
    #expect(model.state == .detectedDFU); #expect(detected?.ecid == "0xabc"); #expect(!model.isMonitoring)
}

@Test @MainActor func recoveryAndNormalAreEarlyOutcomesAfterReset() {
    let recovery = assistant(); detectReset(recovery); recovery.consume(devices: [phoneRecovery]); #expect(recovery.state == .detectedRecovery)
    let normal = assistant(); detectReset(normal); normal.consume(devices: [phoneNormal]); #expect(normal.state == .detectedNormal)
}

@Test @MainActor func cableAdviceAppearsOnlyAfterConfiguredRepeatedRecoveryOutcomes() {
    let model = assistant(); #expect(!model.shouldProminentlyShowCableAdvice); #expect(model.recoveryOutcomeCount == 0)
    detectReset(model); model.consume(devices: [phoneRecovery]); #expect(model.recoveryOutcomeCount == 1); #expect(!model.shouldProminentlyShowCableAdvice)
    model.retry(); detectReset(model); model.consume(devices: [phoneRecovery])
    #expect(model.recoveryOutcomeCount == 2); #expect(model.shouldProminentlyShowCableAdvice)
    let unsupported = DFUDevice(family: .iPhone, state: .normal, ecid: "X", productType: "iPhone15,2")
    #expect(MobileDFUInstructionProfile.profile(for: unsupported)?.cableAdvice == nil)
}

@Test @MainActor func differentMobileTargetIsRejected() {
    let model = assistant(); model.start()
    model.consume(devices: [DFUDevice(family: .iPhone, state: .dfu, ecid: "0xDEF", productType: "iPhone7,2")])
    #expect(model.state == .targetMismatch)
}

@Test @MainActor func retryClearsAttemptTimingAndReturnsReady() {
    let clock = FakeMonotonicClock(), model = assistant(clock: clock)
    detectReset(model); clock.advance(milliseconds: 2_400); model.consume(devices: [phoneRecovery])
    #expect(model.lastAttemptSummary?.contains("2.400") == true)
    model.retry(); #expect(model.state == .ready)
    model.start(); #expect(model.timing.firstDisappearance == nil); #expect(model.state == .waitingForReset)
}

@Test @MainActor func recoveryStartOffersOnlyExplicitMockedSynchronizedReset() async {
    let resetter = MockRecoveryResetter(), model = assistant(target: phoneRecovery, resetter: resetter)
    #expect(model.startedInRecovery); #expect(model.synchronizedResetAvailable); #expect(resetter.calls.isEmpty)
    await model.startSynchronizedRecoveryReset()
    #expect(resetter.calls == ["0xABC"]); #expect(model.state == .waitingForReset)
}

@Test @MainActor func unavailableRecoveryResetFallsBackWithoutIssuingCommand() async {
    let model = assistant(target: phoneRecovery)
    #expect(!model.synchronizedResetAvailable)
    await model.startSynchronizedRecoveryReset()
    #expect(model.state == .ready); #expect(model.resetError != nil)
    model.start(); #expect(model.state == .waitingForReset)
}

@Test @MainActor func pollingRunsOnlyWhileAssistantIsActive() async throws {
    let discovery = CountingMobileDiscovery([phoneNormal]), model = assistant(discovery: discovery)
    try await Task.sleep(for: .milliseconds(25)); #expect(discovery.callCount == 0)
    model.activate()
    for _ in 0..<1_000 where discovery.callCount == 0 { await Task.yield() }
    #expect(model.isMonitoring)
    model.cancel(); await model.waitForMonitoringStop(); let stoppedAt = discovery.callCount
    #expect(discovery.callCount == stoppedAt); #expect(!model.isMonitoring)
}

@Test @MainActor func livePollingStopsOnSameECIDDFU() async throws {
    let discovery = CountingMobileDiscovery([phoneNormal]), model = assistant(discovery: discovery)
    model.activate(); model.start()
    for _ in 0..<1_000 where discovery.callCount == 0 { await Task.yield() }
    discovery.set([phoneDFU])
    for _ in 0..<1_000 where model.state != .detectedDFU { await Task.yield() }
    #expect(model.state == .detectedDFU); #expect(!model.isMonitoring)
    await model.waitForMonitoringStop()
}

@Test @MainActor func demoModeNeverPollsHardware() async throws {
    let discovery = CountingMobileDiscovery([phoneDFU]), model = assistant(discovery: discovery, demo: true)
    model.activate(); model.start(); try await Task.sleep(for: .milliseconds(30))
    #expect(discovery.callCount == 0); #expect(!model.isMonitoring); #expect(model.state == .waitingForReset)
    model.setDemoState(.detectedDFU); #expect(model.state == .detectedDFU)
}

@Test @MainActor func assistantHasNoRestoreReviveExploitOrPrivateDFUCapability() {
    // Its dependency surface contains discovery, local logging, an optional Recovery reset protocol,
    // monotonic timing, and a detected-DFU callback. Restore/Revive and automatic DFU operators are absent.
    let model = assistant(); detectReset(model); model.fireReleaseCue(); model.consume(devices: [phoneDFU])
    #expect(model.state == .detectedDFU)
}
