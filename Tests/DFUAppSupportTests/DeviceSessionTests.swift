import DFUAppSupport
import DFUCore
import Foundation
import Testing

private func sessionDevice(_ family: AppleDeviceFamily, _ state: DeviceState, _ ecid: String?, product: String, udid: String? = nil) -> DFUDevice {
    DFUDevice(family: family, state: state, identifier: udid, ecid: ecid, productType: product, serialNumber: ecid.map { "SERIAL-\($0)" })
}

@Test @MainActor func sessionsSurviveDiscoveryReorderingAndStateTransitions() {
    let manager = DeviceSessionManager()
    let phone = sessionDevice(.iPhone, .recovery, "PHONE", product: "iPhone15,2")
    let pad = sessionDevice(.iPad, .recovery, "PAD", product: "iPad13,18")
    manager.reconcile([phone, pad])
    let phoneID = manager.sessions.first { $0.ecid == "PHONE" }!.id
    manager.select(phoneID, selected: true)
    manager.setFirmware(for: phoneID, release: nil, url: URL(fileURLWithPath: "/shared.ipsw"), validation: .validated)
    manager.reconcile([sessionDevice(.iPad, .dfu, "PAD", product: "iPad13,18"), sessionDevice(.iPhone, .dfu, "phone", product: "iPhone15,2")])
    let retained = manager.sessions.first { $0.id == phoneID }!
    #expect(retained.device.state == .dfu); #expect(retained.isSelected); #expect(retained.selectedImageURL?.path == "/shared.ipsw")
}

@Test @MainActor func reconnectAndDifferentIdentityNeverShareSessionState() {
    let manager = DeviceSessionManager(), original = sessionDevice(.iPhone, .recovery, "ONE", product: "iPhone15,2")
    manager.reconcile([original]); let originalID = manager.sessions[0].id
    manager.select(originalID, selected: true); _ = manager.freezeSelectedBatch()
    manager.reconcile([])
    #expect(manager.sessions[0].id == originalID); #expect(!manager.sessions[0].isConnected)
    manager.reconcile([sessionDevice(.iPhone, .normal, "ONE", product: "iPhone15,2")])
    #expect(manager.sessions[0].id == originalID); #expect(manager.sessions[0].isConnected)
    manager.finishBatch()
    manager.reconcile([sessionDevice(.iPhone, .recovery, "TWO", product: "iPhone15,2")])
    #expect(manager.sessions[0].id != originalID); #expect(!manager.sessions[0].isSelected); #expect(manager.sessions[0].firmwareState == .unselected)
}

@Test @MainActor func completedBenchSetCanBeReplacedWithoutStateInheritance() {
    let manager = DeviceSessionManager()
    manager.reconcile((1...4).map { sessionDevice(.iPad, .recovery, "OLD-\($0)", product: "iPad12,1") })
    for session in manager.sessions {
        manager.select(session.id, selected: true)
        manager.update(session.id) { $0.operationState = .completed("Restore complete") }
    }
    manager.reconcile((1...4).map { sessionDevice(.iPad, .recovery, "NEW-\($0)", product: "iPad12,1") })
    #expect(manager.sessions.count == 4)
    #expect(manager.sessions.allSatisfy { $0.ecid?.hasPrefix("NEW-") == true && !$0.isSelected && $0.operationState == .idle })
}

@Test @MainActor func replacementBesideCompletedDeviceRemainsDistinct() {
    let manager = DeviceSessionManager()
    manager.reconcile([sessionDevice(.iPhone, .recovery, "OLD", product: "iPhone15,2")])
    let oldID = manager.sessions[0].id
    manager.update(oldID) { $0.operationState = .completed("Done"); $0.isSelected = true }
    manager.reconcile([
        sessionDevice(.iPhone, .recovery, "OLD", product: "iPhone15,2"),
        sessionDevice(.iPhone, .recovery, "NEW", product: "iPhone15,2")
    ])
    #expect(manager.sessions.count == 2)
    #expect(manager.sessions.first { $0.id == oldID }?.operationState == .completed("Done"))
    #expect(manager.sessions.first { $0.ecid == "NEW" }?.isSelected == false)
    #expect(manager.sessions.first { $0.ecid == "NEW" }?.operationState == .idle)
}

@Test @MainActor func rowPresentationIsExactPrivateAndBatchDerived() {
    let manager = DeviceSessionManager()
    let release = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://example.invalid/pad")!, supportedDevices: ["iPad12,1"])
    let device = DFUDevice(family: .iPad, state: .recovery, ecid: "0x12345678ABCD", productType: "iPad12,1", serialNumber: "SERIAL-1234WXYZ")
    manager.reconcile([device])
    let id = manager.sessions[0].id
    manager.setFirmware(for: id, release: release, url: URL(fileURLWithPath: "/private/cache/image.ipsw"), validation: .validated)
    manager.select(id, selected: true)
    _ = manager.freezeSelectedBatch()
    manager.update(id) { $0.operationState = .queued(position: 1, total: 1) }
    let queued = DeviceSessionPresentation(session: manager.sessions[0], activeBatchIDs: manager.activeBatchIDs, currentBatchID: nil, batchIsRunning: true)
    #expect(queued.firmware == "iPadOS 26.6.1 (23G83)")
    #expect(queued.firmwareReadiness == "Validated")
    #expect(queued.identity == "ECID …ABCD · Serial …WXYZ")
    #expect(queued.identity?.contains("12345678") == false)
    #expect(queued.batchMembership == .queued)
    let excludedDevice = sessionDevice(.iPhone, .recovery, "UNRELATED-9999", product: "iPhone15,2")
    manager.reconcile([device, excludedDevice])
    let excluded = manager.sessions.first { $0.ecid == "UNRELATED-9999" }!
    let presentation = DeviceSessionPresentation(session: excluded, activeBatchIDs: manager.activeBatchIDs, currentBatchID: id, batchIsRunning: true)
    #expect(!excluded.isSelected); #expect(presentation.batchMembership == .notInCurrentBatch)
    #expect(manager.activeBatchIDs == [id])
}

@Test @MainActor func capabilitySummaryAndRestorePreflightAreOperationAware() {
    let manager = DeviceSessionManager()
    manager.reconcile([
        sessionDevice(.mac, .recovery, "MAC-1234", product: "Mac17,6"),
        sessionDevice(.iPhone, .recovery, "PHONE-5678", product: "iPhone15,2"),
        sessionDevice(.iPad, .normal, "PAD-9999", product: "iPad13,18")
    ])
    let mac = manager.sessions.first { $0.ecid == "MAC-1234" }!
    let macPresentation = DeviceSessionPresentation(session: mac, activeBatchIDs: [], currentBatchID: nil, batchIsRunning: false)
    #expect(macPresentation.capability == "Revive available · Restore requires DFU mode.")
    for session in manager.sessions where session.ecid != "PAD-9999" {
        manager.setFirmware(for: session.id, release: IPSWRelease(platform: session.device.family.restorePlatform, version: "1", build: session.device.family == .mac ? "MAC" : "PHONE", downloadURL: URL(string: "https://example.invalid/\(session.id.value)")!, supportedDevices: [session.device.restoreProductType!]), url: URL(fileURLWithPath: "/validated.ipsw"), validation: .validated)
        manager.select(session.id, selected: true)
    }
    let summary = SessionWorkspaceSummary(sessions: manager.sessions)
    #expect(summary == SessionWorkspaceSummary(sessions: manager.sessions))
    #expect(summary.connected == 3); #expect(summary.restoreReady == 1); #expect(summary.selected == 2)
    let preflight = RestorePreflightPresentation(sessions: manager.sessions)
    #expect(preflight.selected == 2); #expect(preflight.connected == 3); #expect(preflight.excluded == 1); #expect(preflight.hasMixedFamilies)
}

@Test @MainActor func failedAndNotStartedHelpersOnlySelectEligibleConnectedCandidates() {
    let manager = readyBatchManager(["FAILED", "SUCCESS", "CANCELLED", "DISCONNECTED"])
    for session in manager.sessions {
        manager.update(session.id) {
            $0.operationState = switch session.ecid {
            case "FAILED", "DISCONNECTED": .failed("Failed")
            case "SUCCESS": .completed("Done")
            default: .cancelled
            }
        }
    }
    manager.select(manager.sessions.first { $0.ecid == "FAILED" }!.id, selected: true)
    _ = manager.freezeSelectedBatch()
    manager.reconcile(manager.sessions.filter { $0.ecid != "DISCONNECTED" }.map(\.device))
    manager.selectFailed(for: .restore)
    #expect(manager.selectedSessions.map(\.ecid) == ["FAILED"])
    manager.selectNotStarted(for: .restore)
    #expect(manager.selectedSessions.map(\.ecid) == ["CANCELLED"])
    #expect(manager.sessions.first { $0.ecid == "SUCCESS" }?.isSelected == false)
    #expect(manager.sessions.first { $0.ecid == "DISCONNECTED" }?.isSelected == false)
}

@Test @MainActor func protectedPollingSnapshotCannotOverwriteOperationOwnedReconnectState() {
    let manager = DeviceSessionManager()
    manager.reconcile([sessionDevice(.iPhone, .recovery, "SAME", product: "iPhone15,2")])
    let id = manager.sessions[0].id
    manager.update(id) { $0.operationState = .reconnecting; $0.device = sessionDevice(.iPhone, .normal, "SAME", product: "iPhone15,2") }
    manager.reconcile([sessionDevice(.iPhone, .recovery, "SAME", product: "iPhone15,2")], preservingDeviceStateFor: [id])
    #expect(manager.sessions[0].device.state == .normal)
    #expect(manager.sessions[0].operationState == .reconnecting)
}

@Test @MainActor func identityFallbackIsExplicitAndUnaddressableDevicesDoNotInheritState() {
    let manager = DeviceSessionManager()
    manager.reconcile([sessionDevice(.iPhone, .normal, nil, product: "iPhone15,2", udid: "UDID-1")])
    let udidID = manager.sessions[0].id
    manager.reconcile([sessionDevice(.iPhone, .recovery, nil, product: "iPhone15,2", udid: "udid-1")])
    #expect(manager.sessions[0].id == udidID); #expect(!manager.sessions[0].hasSafeBatchIdentity)
    manager.reconcile([DFUDevice(family: .iPhone, state: .recovery, productType: "iPhone15,2")])
    let firstEphemeral = manager.sessions[0].id
    manager.select(firstEphemeral, selected: true)
    manager.reconcile([DFUDevice(family: .iPhone, state: .recovery, productType: "iPhone15,2")])
    #expect(manager.sessions[0].id != firstEphemeral); #expect(!manager.sessions[0].isSelected)
}

@Test @MainActor func selectionAndFirmwareRemainPerTargetAndBatchSetIsFrozen() {
    let manager = DeviceSessionManager()
    manager.reconcile([sessionDevice(.iPhone, .recovery, "PHONE", product: "iPhone15,2"), sessionDevice(.iPad, .recovery, "PAD", product: "iPad13,18")])
    let phone = manager.sessions.first { $0.ecid == "PHONE" }!, pad = manager.sessions.first { $0.ecid == "PAD" }!
    let phoneRelease = IPSWRelease(platform: .iOS, version: "1", build: "A", downloadURL: URL(string: "https://example.invalid/a")!, supportedDevices: ["iPhone15,2"])
    manager.select(phone.id, selected: true); manager.select(pad.id, selected: true)
    manager.applySharedFirmware(release: phoneRelease, url: URL(fileURLWithPath: "/same.ipsw"), to: Set([phone.id, pad.id]))
    #expect(manager.sessions.first { $0.id == phone.id }?.firmwareState == .validated)
    if case .incompatible = manager.sessions.first(where: { $0.id == pad.id })?.firmwareState {} else { Issue.record("Expected per-target incompatibility") }
    manager.setFirmware(for: pad.id, release: IPSWRelease(platform: .iPadOS, version: "1", build: "B", downloadURL: URL(string: "https://example.invalid/b")!, supportedDevices: ["iPad13,18"]), url: URL(fileURLWithPath: "/pad.ipsw"), validation: .validated)
    let frozen = manager.freezeSelectedBatch(); #expect(Set(frozen.map(\.id)) == Set([phone.id, pad.id]))
    manager.reconcile([sessionDevice(.iPhone, .recovery, "PHONE", product: "iPhone15,2"), sessionDevice(.iPad, .recovery, "PAD", product: "iPad13,18"), sessionDevice(.mac, .dfu, "NEW", product: "Mac14,2")])
    #expect(!manager.sessions.first { $0.ecid == "NEW" }!.isSelected); #expect(Set(manager.activeBatchIDs) == Set([phone.id, pad.id]))
}

@Test @MainActor func identicalProductsShareOneValidatedCacheURL() {
    let manager = DeviceSessionManager()
    manager.reconcile([sessionDevice(.iPhone, .recovery, "ONE", product: "iPhone15,2"), sessionDevice(.iPhone, .dfu, "TWO", product: "iPhone15,2")])
    let release = IPSWRelease(platform: .iOS, version: "1", build: "A", downloadURL: URL(string: "https://example.invalid/shared")!, supportedDevices: ["iPhone15,2"])
    let shared = URL(fileURLWithPath: "/managed-cache/A/shared.ipsw")
    manager.applySharedFirmware(release: release, url: shared, to: Set(manager.sessions.map(\.id)))
    #expect(manager.sessions.allSatisfy { $0.selectedImageURL == shared && $0.firmwareState == .validated })
}

@Test @MainActor func twoRecoveryIPad121SessionsAcceptOneValidatedCompatibleFirmware() {
    let manager = DeviceSessionManager()
    manager.reconcile([
        sessionDevice(.iPad, .recovery, "PAD-ONE", product: "iPad12,1"),
        sessionDevice(.iPad, .recovery, "PAD-TWO", product: "iPad12,1")
    ])
    let release = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad12.ipsw")!, supportedDevices: ["iPad12,1", "iPad12,2"])
    let shared = URL(fileURLWithPath: "/managed-cache/iPadOS/23G83/iPad12.ipsw")
    manager.select(manager.sessions[0].id, selected: true)
    manager.select(manager.sessions[1].id, selected: true)
    manager.applySharedFirmware(release: release, url: shared, to: Set(manager.selectedSessions.map(\.id)))
    let coordinator = BatchCoordinator(sessions: manager, operatorService: BatchOperatorFixture(plans: [:]), logger: BatchLoggerFixture())
    #expect(manager.sessions.allSatisfy { $0.canRestore && $0.selectedImageURL == shared && $0.firmwareState == .validated })
    #expect(coordinator.canStartRestore)

    manager.reconcile([
        sessionDevice(.iPad, .recovery, "PAD-TWO", product: "iPad12,1"),
        sessionDevice(.iPad, .recovery, "PAD-ONE", product: "iPad12,1")
    ])
    #expect(manager.sessions.allSatisfy { $0.canRestore && $0.selectedImageURL == shared })
}

@Test @MainActor func sharedFirmwareAssignmentRemainsSelectedStateAndProductSpecific() {
    let manager = DeviceSessionManager()
    manager.reconcile([
        sessionDevice(.iPad, .recovery, "SELECTED", product: "iPad12,1"),
        sessionDevice(.iPad, .recovery, "UNSELECTED", product: "iPad12,1"),
        sessionDevice(.iPad, .recovery, "WRONG", product: "iPad16,10"),
        sessionDevice(.iPad, .normal, "NORMAL", product: "iPad12,1")
    ])
    for ecid in ["SELECTED", "WRONG", "NORMAL"] {
        manager.select(manager.sessions.first { $0.ecid == ecid }!.id, selected: true)
    }
    let release = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad12.ipsw")!, supportedDevices: ["iPad12,1"])
    manager.applySharedFirmware(release: release, url: URL(fileURLWithPath: "/validated.ipsw"), to: Set(manager.selectedSessions.map(\.id)))
    #expect(manager.sessions.first { $0.ecid == "SELECTED" }?.canRestore == true)
    #expect(manager.sessions.first { $0.ecid == "UNSELECTED" }?.firmwareState == .unselected)
    #expect(manager.sessions.first { $0.ecid == "WRONG" }?.restoreEligibilityFailure?.contains("not compatible") == true)
    #expect(manager.sessions.first { $0.ecid == "NORMAL" }?.restoreEligibilityFailure == "Restore requires Recovery or DFU mode.")
}

@Test @MainActor func frozenBatchFirmwareDependenciesAreReferenceCountedUntilWorkEnds() {
    let manager = DeviceSessionManager()
    manager.reconcile([
        sessionDevice(.iPhone, .recovery, "ACTIVE", product: "iPhone15,2"),
        sessionDevice(.iPhone, .recovery, "QUEUED-SHARED", product: "iPhone15,2"),
        sessionDevice(.iPhone, .recovery, "QUEUED-UNIQUE", product: "iPhone15,2")
    ])
    let shared = URL(fileURLWithPath: "/managed/shared.ipsw")
    let unique = URL(fileURLWithPath: "/managed/unique.ipsw")
    let unrelated = URL(fileURLWithPath: "/managed/unrelated.ipsw")
    for session in manager.sessions {
        let url = session.ecid == "QUEUED-UNIQUE" ? unique : shared
        manager.setFirmware(for: session.id, release: nil, url: url, validation: .validated)
        manager.select(session.id, selected: true)
    }

    let frozen = manager.freezeSelectedBatch()
    let active = frozen.first { $0.ecid == "ACTIVE" }!
    let queuedShared = frozen.first { $0.ecid == "QUEUED-SHARED" }!
    let queuedUnique = frozen.first { $0.ecid == "QUEUED-UNIQUE" }!
    #expect(manager.isFirmwareInUseByBatch(shared))
    #expect(manager.isFirmwareInUseByBatch(unique))
    #expect(!manager.isFirmwareInUseByBatch(unrelated))

    manager.finishBatchWork(for: active.id)
    #expect(manager.isFirmwareInUseByBatch(shared))
    manager.finishBatchWork(for: queuedShared.id)
    #expect(!manager.isFirmwareInUseByBatch(shared))
    #expect(manager.isFirmwareInUseByBatch(unique))
    manager.finishBatchWork(for: queuedUnique.id)
    #expect(!manager.isFirmwareInUseByBatch(unique))
    manager.finishBatch()
}

@Test @MainActor func mixedFamilyEligibilityIsExplicit() {
    let manager = DeviceSessionManager()
    let devices = [sessionDevice(.mac, .dfu, "MAC-DFU", product: "Mac14,2"), sessionDevice(.mac, .recovery, "MAC-REC", product: "Mac14,2"), sessionDevice(.iPhone, .recovery, "PHONE", product: "iPhone15,2"), sessionDevice(.iPad, .normal, "PAD", product: "iPad13,18")]
    manager.reconcile(devices)
    for session in manager.sessions { manager.setFirmware(for: session.id, release: nil, url: URL(fileURLWithPath: "/image.ipsw"), validation: .validated) }
    #expect(manager.sessions.first { $0.ecid == "MAC-DFU" }!.canRestore)
    #expect(!manager.sessions.first { $0.ecid == "MAC-REC" }!.canRestore)
    #expect(manager.sessions.first { $0.ecid == "PHONE" }!.canRestore)
    #expect(!manager.sessions.first { $0.ecid == "PAD" }!.canRestore)
    manager.selectAllRestoreEligible(); #expect(Set(manager.selectedSessions.compactMap(\.ecid)) == Set(["MAC-DFU", "PHONE"]))
    manager.clearSelection(); #expect(manager.selectedSessions.isEmpty)
}

@Test @MainActor func progressReconnectAndStaleGenerationsAreSessionIsolated() {
    let manager = DeviceSessionManager()
    manager.reconcile([sessionDevice(.iPhone, .recovery, "A", product: "iPhone15,2"), sessionDevice(.iPad, .recovery, "B", product: "iPad13,18")])
    let a = manager.sessions.first { $0.ecid == "A" }!, b = manager.sessions.first { $0.ecid == "B" }!
    manager.update(a.id) { $0.generation = 2; $0.operationState = .running(stage: "Installing", fraction: 0.4) }
    manager.update(b.id) { $0.generation = 7; $0.operationState = .reconnecting }
    #expect(!manager.update(a.id, generation: 1) { $0.operationState = .completed("stale") })
    #expect(manager.update(a.id, generation: 2) { $0.operationState = .completed("A complete") })
    #expect(manager.sessions.first { $0.id == a.id }?.operationState == .completed("A complete"))
    #expect(manager.sessions.first { $0.id == b.id }?.operationState == .reconnecting)
}

private final class BatchOperatorFixture: @unchecked Sendable, BatchTargetOperating {
    struct Plan { let events: [RestoreEvent]; let error: Error?; let delay: Duration }
    private let lock = NSLock(); private var plans: [String: Plan]; private var recorded: [RestoreAction] = []
    init(plans: [String: Plan]) { self.plans = plans }
    func events(for action: RestoreAction) -> AsyncThrowingStream<RestoreEvent, Error> {
        let ecid: String = if case .targetedRestore(_, let value) = action { value } else { "UNTARGETED" }
        let plan = lock.withLock { recorded.append(action); return plans[ecid] ?? Plan(events: [.completed], error: nil, delay: .zero) }
        return AsyncThrowingStream { continuation in Task {
            if plan.delay != .zero { try? await Task.sleep(for: plan.delay) }
            for event in plan.events { continuation.yield(event) }
            if let error = plan.error { continuation.finish(throwing: error) } else { continuation.finish() }
        } }
    }
    func reconnect(expectedECID: String?) async -> ReconnectResult { .restarted(sessionDevice(.iPhone, .normal, expectedECID, product: "iPhone15,2")) }
    var actions: [RestoreAction] { lock.withLock { recorded } }
}

private struct BatchLoggerFixture: OperationLogging {
    func start(operation: String, target: DFUDevice?, release: IPSWRelease?) throws -> URL { URL(fileURLWithPath: "/tmp/\(target?.ecid ?? "unknown").log") }
    func append(_ message: String, to url: URL) throws {}
}

@MainActor private func readyBatchManager(_ ecids: [String]) -> DeviceSessionManager {
    let manager = DeviceSessionManager()
    manager.reconcile(ecids.map { sessionDevice(.iPhone, .recovery, $0, product: "iPhone15,2") })
    for session in manager.sessions {
        manager.setFirmware(for: session.id, release: nil, url: URL(fileURLWithPath: "/shared.ipsw"), validation: .validated)
        manager.select(session.id, selected: true)
    }
    return manager
}

@Test @MainActor func batchRunsSequentiallyTargetsEveryCommandAndContinuesAfterFailure() async {
    let manager = readyBatchManager(["A", "B", "C"])
    let fixture = BatchOperatorFixture(plans: [
        "A": .init(events: [.stageStarted(name: "Installing", index: 1, total: 1), .progress(stage: "Installing", fraction: 0.5), .completed], error: nil, delay: .milliseconds(10)),
        "B": .init(events: [.stageStarted(name: "Installing", index: 1, total: 1)], error: DFUError.commandFailed(command: "fixture", status: 1, output: "failed B"), delay: .milliseconds(10)),
        "C": .init(events: [.completed], error: nil, delay: .milliseconds(10))
    ])
    let coordinator = BatchCoordinator(sessions: manager, operatorService: fixture, logger: BatchLoggerFixture())
    #expect(coordinator.canStartRestore); coordinator.startRestore()
    while coordinator.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(coordinator.summary == BatchSummary(total: 3, succeeded: 2, failed: 1, cancelled: 0))
    #expect(fixture.actions.count == 3)
    #expect(fixture.actions.allSatisfy { if case .targetedRestore(_, let ecid) = $0 { return ["A", "B", "C"].contains(ecid) }; return false })
    #expect(manager.sessions.first { $0.ecid == "A" }?.operationState == .completed("Restore complete; target restarted."))
    if case .failed = manager.sessions.first(where: { $0.ecid == "B" })?.operationState {} else { Issue.record("Expected isolated B failure") }
    #expect(manager.sessions.first { $0.ecid == "C" }?.operationState == .completed("Restore complete; target restarted."))
}

@Test @MainActor func stoppingBatchAllowsActiveTargetToFinishAndCancelsQueuedTargets() async {
    let manager = readyBatchManager(["A", "B", "C"])
    let fixture = BatchOperatorFixture(plans: ["A": .init(events: [.progress(stage: "Installing", fraction: 0.4), .completed], error: nil, delay: .milliseconds(100))])
    let coordinator = BatchCoordinator(sessions: manager, operatorService: fixture, logger: BatchLoggerFixture())
    coordinator.startRestore(); try? await Task.sleep(for: .milliseconds(20)); coordinator.stopAfterCurrentTarget()
    while coordinator.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(coordinator.summary == BatchSummary(total: 3, succeeded: 1, failed: 0, cancelled: 2))
    #expect(fixture.actions.count == 1)
    #expect(manager.sessions.filter { $0.operationState == .cancelled }.count == 2)
    #expect(!manager.isFirmwareInUseByBatch(URL(fileURLWithPath: "/shared.ipsw")))
}

@Test @MainActor func queuedDisconnectFailsOnlyThatSessionAndBatchContinues() async {
    let manager = readyBatchManager(["A", "B", "C"])
    let fixture = BatchOperatorFixture(plans: ["A": .init(events: [.completed], error: nil, delay: .milliseconds(80)), "C": .init(events: [.completed], error: nil, delay: .zero)])
    let coordinator = BatchCoordinator(sessions: manager, operatorService: fixture, logger: BatchLoggerFixture())
    coordinator.startRestore(); try? await Task.sleep(for: .milliseconds(20))
    manager.reconcile([sessionDevice(.iPhone, .recovery, "A", product: "iPhone15,2"), sessionDevice(.iPhone, .recovery, "C", product: "iPhone15,2")])
    while coordinator.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(coordinator.summary == BatchSummary(total: 3, succeeded: 2, failed: 1, cancelled: 0))
    #expect(fixture.actions.count == 2)
    if case .failed(let message) = manager.sessions.first(where: { $0.ecid == "B" })?.operationState { #expect(message.contains("disconnected")) }
    else { Issue.record("Expected disconnected queued target failure") }
}
