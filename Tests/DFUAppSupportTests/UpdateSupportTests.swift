import Foundation
import Testing
@testable import DFUAppSupport
@testable import DFUCore

private final class UpdateServiceBox: @unchecked Sendable {
    private let lock = NSLock()
    var result: AppUpdateState = .current
    var error: Error?
    var launchError: Error?
    private(set) var checks = 0
    private(set) var launches = 0
    private(set) var launchedSource: URL?
    func checked() throws -> AppUpdateState { lock.lock(); defer { lock.unlock() }; checks += 1; if let error { throw error }; return result }
    private(set) var events: [String] = []
    func launched(_ source: URL) throws { lock.lock(); defer { lock.unlock() }; launches += 1; launchedSource = source; events.append("launch"); if let launchError { throw launchError } }
    func terminated() { lock.lock(); defer { lock.unlock() }; events.append("terminate") }
    var recordedEvents: [String] { lock.withLock { events } }
}

private struct MockUpdateService: UpdateServicing {
    let box: UpdateServiceBox
    func check(sourceRoot: URL) async throws -> AppUpdateState { try box.checked() }
    func launch(sourceRoot: URL, oldPID: Int32, appURL: URL, resultURL: URL) throws { try box.launched(sourceRoot) }
}

@MainActor private final class MockApplicationTerminator: ApplicationTerminationRequesting {
    private(set) var calls = 0
    let box: UpdateServiceBox
    init(_ box: UpdateServiceBox) { self.box = box }
    func requestTermination() { calls += 1; box.terminated() }
}

private func updateFixture(_ name: String = UUID().uuidString) throws -> (URL, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DFU Update Tests").appendingPathComponent(name)
    let source = root.appendingPathComponent("source clone with spaces")
    let record = root.appendingPathComponent("update-source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: source.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try source.path.write(to: record, atomically: true, encoding: .utf8)
    return (root, source, record)
}

private struct BinaryHTTPFixture: HTTPDataFetching {
    let payload: Data
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor @Test func binaryInstallationModeChecksStableReleaseWithoutDownloading() async throws {
    let root = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: FileManager.default.temporaryDirectory, create: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = #"[{"tag_name":"v0.10.0","draft":false,"prerelease":false,"html_url":"https://github.com/thehallifax/DFUUtility/releases/tag/v0.10.0","assets":[{"name":"DFUUtility-0.10.0.zip","browser_download_url":"https://github.com/thehallifax/DFUUtility/releases/download/v0.10.0/DFUUtility-0.10.0.zip","size":10,"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}]"#.data(using: .utf8)!
    let coordinator = UpdateCoordinator(service: MockUpdateService(box: UpdateServiceBox()), sourceRecordURL: root.appendingPathComponent("missing-source"), resultURL: root.appendingPathComponent("result"), logURL: root.appendingPathComponent("log"), appURL: root.appendingPathComponent("DFUUtility.app"), binaryClient: GitHubReleaseClient(client: BinaryHTTPFixture(payload: payload)), runningVersion: SemanticVersion(tag: "v0.9.0"))
    #expect(coordinator.installationMode == .binary)
    await coordinator.check(manual: true)
    guard case .binaryAvailable(let release) = coordinator.state else { Issue.record("Expected binary release availability"); return }
    #expect(release.version == SemanticVersion(tag: "v0.10.0")!)
    #expect(coordinator.verifiedBinaryArtifact == nil)
}

@MainActor @Test func existingNonGitSourceRecordIsNotSilentlyTreatedAsBinary() async throws {
    let root = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: FileManager.default.temporaryDirectory, create: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("not-a-repository"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let record = root.appendingPathComponent("update-source"); try source.path.write(to: record, atomically: true, encoding: .utf8)
    let coordinator = UpdateCoordinator(service: MockUpdateService(box: UpdateServiceBox()), sourceRecordURL: record, resultURL: root.appendingPathComponent("result"), logURL: root.appendingPathComponent("log"), appURL: root.appendingPathComponent("DFUUtility.app"))
    guard case .invalidSourceRecord = coordinator.installationMode else { Issue.record("Expected invalid source record"); return }
    await coordinator.check(manual: true)
    #expect(coordinator.sourceCheckoutUnavailable)
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
    #expect(coordinator.shareableSourceHealth == "Source not recorded")
    await coordinator.check(manual: true)
    guard case .failed(let missing) = coordinator.state else { Issue.record("Expected missing-record failure"); return }
    #expect(missing == UpdateCoordinator.sourceGuidance); #expect(coordinator.sourceCheckoutUnavailable)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "/deleted/source".write(to: record, atomically: true, encoding: .utf8)
    #expect(coordinator.shareableSourceHealth == "Recorded source unavailable")
    await coordinator.check(manual: true)
    guard case .failed(let deleted) = coordinator.state else { Issue.record("Expected deleted-source failure"); return }
    #expect(deleted == UpdateCoordinator.sourceGuidance); #expect(box.checks == 0)
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

@MainActor @Test func invalidSourceGuidanceRetainsTechnicalLogAndOtherSafetyFailures() async throws {
    let (root, _, record) = try updateFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let box = UpdateServiceBox(), log = root.appendingPathComponent("update.log")
    let coordinator = UpdateCoordinator(service: MockUpdateService(box: box), sourceRecordURL: record, resultURL: root.appendingPathComponent("result"), logURL: log)
    box.error = UpdateServiceError.sourceInvalid("this folder is not a Git worktree")
    await coordinator.check(manual: true)
    #expect(coordinator.sourceCheckoutUnavailable)
    #expect(coordinator.state == .failed(UpdateCoordinator.sourceGuidance))
    #expect(try String(contentsOf: log, encoding: .utf8).contains("not a Git worktree"))
    box.error = nil; box.result = .unavailable("Source has local changes")
    await coordinator.check(manual: true)
    #expect(!coordinator.sourceCheckoutUnavailable); #expect(coordinator.state == box.result)
    #expect(box.launches == 0)
}

@Test func shellUpdaterClassifiesInvalidSourceWithoutLaunchingUpdate() async throws {
    let (root, source, _) = try updateFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let scripts = source.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    let updater = scripts.appendingPathComponent("update.sh")
    try "#!/bin/sh\nprintf 'status=invalid_source\\nmessage=This folder is not a Git worktree.\\n'\nexit 1\n".write(to: updater, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: updater.path)
    do {
        _ = try await ShellUpdateService(launcherURL: root.appendingPathComponent("absent-launcher")).check(sourceRoot: source)
        Issue.record("Expected invalid source classification")
    } catch UpdateServiceError.sourceInvalid(let detail) {
        #expect(detail.contains("not a Git worktree"))
    }
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

@MainActor @Test func successfulSpawnDismissesSheetAndRequestsTerminationExactlyOnce() async throws {
    let (root, _, record) = try updateFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let box = UpdateServiceBox(), terminator = MockApplicationTerminator(box)
    let available = AppUpdateState.available(.init(currentVersion: "0.6.1", latestVersion: "0.7.0", currentCommit: "a", latestCommit: "b"))
    box.result = available
    let coordinator = UpdateCoordinator(service: MockUpdateService(box: box), sourceRecordURL: record, resultURL: root.appendingPathComponent("result"), logURL: root.appendingPathComponent("log"))
    let app = AppModel(updateCoordinator: coordinator, applicationTerminator: terminator, requiresPrivilegedHelperSetup: false)
    await coordinator.check(manual: true)
    app.isUpdatePresentationRequested = true
    #expect(app.prepareUpdate())
    #expect(box.recordedEvents == ["launch", "terminate"])
    #expect(terminator.calls == 1); #expect(!app.isUpdatePresentationRequested)
    #expect(coordinator.state == .preparing)
}

@MainActor @Test func spawnFailureKeepsAppOpenAndUpdateAvailable() async throws {
    let (root, _, record) = try updateFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let box = UpdateServiceBox(), terminator = MockApplicationTerminator(box)
    let available = AppUpdateState.available(.init(currentVersion: "0.6.1", latestVersion: "0.7.0", currentCommit: "a", latestCommit: "b"))
    box.result = available; box.launchError = UpdateServiceError.launchFailed("fixture")
    let coordinator = UpdateCoordinator(service: MockUpdateService(box: box), sourceRecordURL: record, resultURL: root.appendingPathComponent("result"), logURL: root.appendingPathComponent("log"))
    let app = AppModel(updateCoordinator: coordinator, applicationTerminator: terminator, requiresPrivilegedHelperSetup: false)
    await coordinator.check(manual: true); app.isUpdatePresentationRequested = true
    #expect(!app.prepareUpdate())
    #expect(terminator.calls == 0); #expect(app.isUpdatePresentationRequested)
    #expect(coordinator.state == available); #expect(app.presentedError?.contains("fixture") == true)
}

@MainActor @Test func updateTestSimulationNeverRequestsTermination() async {
    let box = UpdateServiceBox(), terminator = MockApplicationTerminator(box), coordinator = UpdateCoordinator.simulated()
    let app = AppModel(updateCoordinator: coordinator, applicationTerminator: terminator, requiresPrivilegedHelperSetup: false, isUpdateTestMode: true)
    await app.load()
    #expect(app.prepareUpdate())
    #expect(terminator.calls == 0); #expect(coordinator.pendingResult?.isSimulation == true)
}
