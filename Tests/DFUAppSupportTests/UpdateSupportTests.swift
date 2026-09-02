import Foundation
import Testing
@testable import DFUAppSupport

private final class UpdateServiceBox: @unchecked Sendable {
    private let lock = NSLock()
    var result: AppUpdateState = .current
    var error: Error?
    private(set) var checks = 0
    private(set) var launches = 0
    private(set) var launchedSource: URL?
    func checked() throws -> AppUpdateState { lock.lock(); defer { lock.unlock() }; checks += 1; if let error { throw error }; return result }
    func launched(_ source: URL) { lock.lock(); defer { lock.unlock() }; launches += 1; launchedSource = source }
}

private struct MockUpdateService: UpdateServicing {
    let box: UpdateServiceBox
    func check(sourceRoot: URL) async throws -> AppUpdateState { try box.checked() }
    func launch(sourceRoot: URL, oldPID: Int32, appURL: URL, resultURL: URL) throws { box.launched(sourceRoot) }
}

private func updateFixture(_ name: String = UUID().uuidString) throws -> (URL, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DFU Update Tests").appendingPathComponent(name)
    let source = root.appendingPathComponent("source clone with spaces")
    let record = root.appendingPathComponent("update-source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try source.path.write(to: record, atomically: true, encoding: .utf8)
    return (root, source, record)
}

@MainActor @Test func recordedSourceWithSpacesSupportsCheckAndLaunch() async throws {
    let (root, source, record) = try updateFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let box = UpdateServiceBox(), defaults = UserDefaults(suiteName: UUID().uuidString)!
    box.result = .available(.init(currentVersion: "0.6.1", latestVersion: "0.7.0", currentCommit: "a", latestCommit: "b"))
    let coordinator = UpdateCoordinator(service: MockUpdateService(box: box), sourceRecordURL: record, resultURL: root.appendingPathComponent("result"), logURL: root.appendingPathComponent("log"), defaults: defaults)
    await coordinator.check(manual: true)
    #expect(coordinator.state == box.result)
    try coordinator.launchUpdate()
    #expect(box.launches == 1); #expect(box.launchedSource?.standardizedFileURL == source.standardizedFileURL); #expect(coordinator.launchSucceeded)
}

@MainActor @Test func missingAndDeletedSourceAreReported() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), box = UpdateServiceBox()
    let record = root.appendingPathComponent("update-source")
    let coordinator = UpdateCoordinator(service: MockUpdateService(box: box), sourceRecordURL: record, resultURL: root.appendingPathComponent("result"), logURL: root.appendingPathComponent("log"))
    await coordinator.check(manual: true)
    guard case .failed(let missing) = coordinator.state else { Issue.record("Expected missing-record failure"); return }
    #expect(missing.contains("has not been recorded"))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "/deleted/source".write(to: record, atomically: true, encoding: .utf8)
    await coordinator.check(manual: true)
    guard case .failed(let deleted) = coordinator.state else { Issue.record("Expected deleted-source failure"); return }
    #expect(deleted.contains("could not be found")); #expect(box.checks == 0)
}

@MainActor @Test func automaticCheckThrottleAndDisabledModesStayOffline() async throws {
    let (root, _, record) = try updateFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let box = UpdateServiceBox(), suite = "UpdateThrottle-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
    let coordinator = UpdateCoordinator(service: MockUpdateService(box: box), sourceRecordURL: record, resultURL: root.appendingPathComponent("result"), logURL: root.appendingPathComponent("log"), defaults: defaults, now: { Date(timeIntervalSince1970: 100_000) })
    await coordinator.automaticCheckIfDue(disabled: true)
    #expect(box.checks == 0)
    await coordinator.automaticCheckIfDue(disabled: false)
    await coordinator.automaticCheckIfDue(disabled: false)
    #expect(box.checks == 1)
}

@MainActor @Test func automaticNetworkFailureIsQuietAndDoesNotThrottleRetry() async throws {
    let (root, _, record) = try updateFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let box = UpdateServiceBox(); box.error = UpdateServiceError.checkFailed("offline")
    let coordinator = UpdateCoordinator(service: MockUpdateService(box: box), sourceRecordURL: record, resultURL: root.appendingPathComponent("result"), logURL: root.appendingPathComponent("log"), defaults: UserDefaults(suiteName: UUID().uuidString)!)
    await coordinator.automaticCheckIfDue(disabled: false)
    await coordinator.automaticCheckIfDue(disabled: false)
    #expect(coordinator.state == .idle); #expect(box.checks == 2)
    await coordinator.check(manual: true)
    #expect(coordinator.state == .failed("offline"))
}

@MainActor @Test func updateResultIsConsumedExactlyOnce() throws {
    let (root, _, record) = try updateFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let result = root.appendingPathComponent("result")
    try "status=success\nold_version=0.6.1\nnew_version=0.6.1\n".write(to: result, atomically: true, encoding: .utf8)
    let coordinator = UpdateCoordinator(service: MockUpdateService(box: UpdateServiceBox()), sourceRecordURL: record, resultURL: result, logURL: root.appendingPathComponent("log"))
    coordinator.consumeResult(); #expect(coordinator.pendingResult?.outcome == .success); #expect(!FileManager.default.fileExists(atPath: result.path))
    coordinator.clearResult(); coordinator.consumeResult(); #expect(coordinator.pendingResult == nil)
}

@Test func updateSafetyGateCoversEveryActiveOperation() {
    #expect(UpdateOperationSnapshot().permitsUpdate)
    #expect(!UpdateOperationSnapshot(restoreOrReconnect: true).permitsUpdate)
    #expect(!UpdateOperationSnapshot(download: true).permitsUpdate)
    #expect(!UpdateOperationSnapshot(validation: true).permitsUpdate)
    #expect(!UpdateOperationSnapshot(guidedDFU: true).permitsUpdate)
    #expect(!UpdateOperationSnapshot(batch: true).permitsUpdate)
}

@MainActor @Test func simulatedAcceptanceTraversesAvailabilityHandoffAndResult() async throws {
    let coordinator = UpdateCoordinator.simulated()
    await coordinator.check(manual: true)
    #expect(coordinator.state == .available(SimulatedUpdateService.availability))
    try coordinator.launchUpdate()
    #expect(coordinator.state == .preparing); #expect(coordinator.launchSucceeded)
    coordinator.completeSimulation()
    #expect(coordinator.state == .current)
    #expect(coordinator.pendingResult == .init(outcome: .success, oldVersion: "0.6.1", newVersion: "0.7.0-test", isSimulation: true))
}

@Test func updateAcceptanceArgumentIsRejectedForPackagedApplication() {
    #expect(DevelopmentUpdateAcceptance.isEnabled(arguments: ["DFUUtility", "--update-test"], bundleURL: URL(fileURLWithPath: "/tmp/.build/debug")))
    #expect(!DevelopmentUpdateAcceptance.isEnabled(arguments: ["DFUUtility", "--update-test"], bundleURL: URL(fileURLWithPath: "/Applications/DFUUtility.app")))
    #expect(!DevelopmentUpdateAcceptance.isEnabled(arguments: ["DFUUtility"], bundleURL: URL(fileURLWithPath: "/tmp/.build/debug")))
}
