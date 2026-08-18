import Foundation
import Testing
@testable import DFUCore

private let sampleURL = URL(string: "https://updates.cdn-apple.com/test/UniversalMac.ipsw")!
private func release(version: String = "26.6.2", build: String = "25G83", size: Int64? = nil) -> IPSWRelease { IPSWRelease(version: version, build: build, downloadURL: sampleURL, fileSize: size, checksum: nil, supportedDevices: ["Mac14,2"]) }
private func temporaryDirectory() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url }

private struct AcceptValidator: IPSWValidating { func validate(_ url: URL, release: IPSWRelease?, verifyChecksum: Bool) throws { guard FileManager.default.fileExists(atPath: url.path) else { throw DFUError.invalidIPSW("missing") } } }
private struct RejectValidator: IPSWValidating { func validate(_ url: URL, release: IPSWRelease?, verifyChecksum: Bool) throws { throw DFUError.invalidIPSW("test rejection") } }
private struct MockCatalogue: IPSWCatalogueFetching { let values: [IPSWRelease]; let error: Error?; init(_ values: [IPSWRelease] = [], error: Error? = nil) { self.values = values; self.error = error }; func releases() async throws -> [IPSWRelease] { if let error { throw error }; return values } }
private actor MockDownloader: IPSWDownloading {
    enum Behavior: Sendable { case success, interrupted, failure }
    let behavior: Behavior; private(set) var calls = 0
    init(_ behavior: Behavior = .success) { self.behavior = behavior }
    func download(_ release: IPSWRelease, to partial: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        calls += 1; try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("partial".utf8).write(to: partial)
        if behavior == .interrupted { throw CancellationError() }; if behavior == .failure { throw URLError(.cannotConnectToHost) }
    }
}

@Test func parsesAppleCatalogueAndAggregatesModels() throws {
    let plist: [String: Any] = ["MobileDeviceSoftwareVersionsByVersion": ["1": ["MobileDeviceSoftwareVersions": [
        "Mac14,2": ["25G83": ["Restore": ["FirmwareURL": sampleURL.absoluteString, "FirmwareSHA1": "abc", "ProductVersion": "26.6.2", "BuildVersion": "25G83"]]],
        "Mac15,3": ["25G83": ["Restore": ["FirmwareURL": sampleURL.absoluteString, "FirmwareSHA1": "abc", "ProductVersion": "26.6.2", "BuildVersion": "25G83"]]]
    ]]]]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), parsed = try AppleIPSWCatalogue.parse(data)
    #expect(parsed.count == 1); #expect(parsed[0].version == "26.6.2"); #expect(parsed[0].checksum == "abc"); #expect(parsed[0].supportedDevices == ["Mac14,2", "Mac15,3"])
}

@Test func sortsVersionsNumericallyAndSelectsLatest() async throws {
    let old = release(version: "15.10", build: "24Z1"), latest = release(version: "26.6.2", build: "25G83"), middle = release(version: "26.6", build: "25G70")
    #expect(AppleIPSWService.sortNewestFirst([old, latest, middle]).map(\.version) == ["26.6.2", "26.6", "15.10"])
    let service = AppleIPSWService(catalogue: MockCatalogue([old, middle, latest]), downloader: MockDownloader(), cache: IPSWCache(directory: try temporaryDirectory()), validator: AcceptValidator())
    #expect(try await service.recommendedImage(for: nil).build == "25G83")
}

@Test func cachePathsAndPartialAreDistinct() throws {
    let cache = IPSWCache(directory: URL(fileURLWithPath: "/tmp/cache")), value = release()
    #expect(cache.destination(for: value).path.contains("/25G83/")); #expect(cache.destination(for: value).pathExtension == "ipsw"); #expect(cache.partialURL(for: value).pathExtension == "partial")
}

@Test func cacheHitAvoidsDownload() async throws {
    let root = try temporaryDirectory(), cache = IPSWCache(directory: root), value = release(), partial = cache.partialURL(for: value)
    try cache.prepare(); try Data("valid".utf8).write(to: partial); _ = try cache.commit(partial: partial, release: value)
    let downloader = MockDownloader(), service = AppleIPSWService(catalogue: MockCatalogue(), downloader: downloader, cache: cache, validator: AcceptValidator())
    #expect(try await service.download(value).path == cache.destination(for: value).path); #expect(await downloader.calls == 0)
}

@Test func cacheMissDownloadsAndCommits() async throws {
    let cache = IPSWCache(directory: try temporaryDirectory()), downloader = MockDownloader(), value = release()
    let service = AppleIPSWService(catalogue: MockCatalogue(), downloader: downloader, cache: cache, validator: AcceptValidator())
    let result = try await service.download(value); #expect(FileManager.default.fileExists(atPath: result.path)); #expect(await downloader.calls == 1); #expect(!FileManager.default.fileExists(atPath: cache.partialURL(for: value).path))
}

@Test func invalidCachedIPSWIsNotAHit() async throws {
    let cache = IPSWCache(directory: try temporaryDirectory()), value = release(), downloader = MockDownloader(); try FileManager.default.createDirectory(at: cache.destination(for: value).deletingLastPathComponent(), withIntermediateDirectories: true); try Data().write(to: cache.destination(for: value))
    let service = AppleIPSWService(catalogue: MockCatalogue(), downloader: downloader, cache: cache, validator: RejectValidator())
    await #expect(throws: DFUError.self) { try await service.download(value) }; #expect(await downloader.calls == 1)
}

@Test func partialDownloadIsIgnoredAsCompleteAndRetainedOnInterruption() async throws {
    let cache = IPSWCache(directory: try temporaryDirectory()), value = release(), downloader = MockDownloader(.interrupted); try cache.prepare(); try Data("old".utf8).write(to: cache.partialURL(for: value))
    #expect(cache.cachedURL(for: value) == nil)
    let service = AppleIPSWService(catalogue: MockCatalogue(), downloader: downloader, cache: cache, validator: AcceptValidator())
    await #expect(throws: CancellationError.self) { try await service.download(value) }; #expect(FileManager.default.fileExists(atPath: cache.partialURL(for: value).path)); #expect(cache.cachedURL(for: value) == nil)
}

@Test func networkFailuresPropagate() async throws {
    let expected = URLError(.notConnectedToInternet), service = AppleIPSWService(catalogue: MockCatalogue(error: expected), downloader: MockDownloader(), cache: IPSWCache(directory: try temporaryDirectory()), validator: AcceptValidator())
    await #expect(throws: URLError.self) { _ = try await service.availableImages(for: nil) }
}

@Test func incorrectSizeIsRejectedBeforeZipInspection() throws {
    let root = try temporaryDirectory(), file = root.appendingPathComponent("image.partial"); try Data(repeating: 0, count: 1_100_000).write(to: file)
    #expect(throws: IPSWServiceError.incorrectSize(expected: 2_000_000, actual: 1_100_000)) { try IPSWValidator().validate(file, release: release(size: 2_000_000), verifyChecksum: false) }
}

@Test func cleanupOnlyRemovesRequestedItems() throws {
    let cache = IPSWCache(directory: try temporaryDirectory()), value = release(); try cache.prepare(); try Data("partial".utf8).write(to: cache.partialURL(for: value))
    let completed = cache.downloadsDirectory.appendingPathComponent("completed.txt"); try Data("keep".utf8).write(to: completed)
    #expect(try cache.clean(partials: true, invalid: false, validator: AcceptValidator()) == 1); #expect(!FileManager.default.fileExists(atPath: cache.partialURL(for: value).path)); #expect(FileManager.default.fileExists(atPath: completed.path))
}

@Test func doctorNoTargetAndMissingVDMRemainFundamentallyUsable() {
    let status = UtilityStatus(host: HostStatus(isAppleSilicon: true, macOSVersion: "26.6.1", macVDMToolPath: nil, cfgutilPath: URL(fileURLWithPath: "/cfgutil")), targets: [])
    let report = DoctorReport(status: status, configuratorPresent: true, cacheDirectory: URL(fileURLWithPath: "/cache"), cacheWritable: true, restoreSupported: true)
    #expect(report.isFundamentallyUsable); #expect(!report.setupComplete); #expect(report.status.targets.isEmpty)
}

@Test func liveAppleCatalogueOptIn() async throws {
    guard ProcessInfo.processInfo.environment["DFU_LIVE_TESTS"] == "1" else { return }
    let releases = try await AppleIPSWCatalogue().releases(); #expect(!releases.isEmpty); #expect(releases.allSatisfy { $0.downloadURL.host == "updates.cdn-apple.com" })
}

@Test func existingErrorsRemainUseful() { #expect(DFUError.targetNotInDFU.localizedDescription.contains("not in DFU")); #expect(DFUError.multipleTargets(2).localizedDescription.contains("2")) }

private func executableFile(in directory: URL, name: String = "macvdmtool", executable: Bool = true) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name); try Data("tool".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path); return url
}

@Test func bundledHelperIsPreferred() throws {
    let root = try temporaryDirectory(), resources = root.appendingPathComponent("Resources"), bin = root.appendingPathComponent("bin")
    let bundled = try executableFile(in: resources), override = try executableFile(in: bin, name: "override")
    let result = ToolLocator.macVDMTool(environment: ["DFUCTL_MACVDMTOOL_PATH": override.path], bundleURL: root.appendingPathComponent("DFUUtility.app"), bundleResourceURL: resources, executableURL: nil, externalCandidates: [])
    #expect(result == ToolResolution(url: bundled, source: .bundled))
}

@Test func projectHelperIsDiscoveredBesideSwiftPMExecutable() throws {
    let root = try temporaryDirectory(), helper = try executableFile(in: root), executable = root.appendingPathComponent("dfuctl")
    let result = ToolLocator.macVDMTool(environment: [:], bundleURL: nil, bundleResourceURL: nil, executableURL: executable, externalCandidates: [])
    #expect(result == ToolResolution(url: helper, source: .projectBuild))
}

@Test func developmentOverridePrecedesProjectHelper() throws {
    let root = try temporaryDirectory(), project = root.appendingPathComponent("project"), custom = root.appendingPathComponent("custom")
    _ = try executableFile(in: project); let override = try executableFile(in: custom)
    let result = ToolLocator.macVDMTool(environment: ["DFUCTL_MACVDMTOOL_PATH": override.path], bundleURL: nil, bundleResourceURL: nil, executableURL: project.appendingPathComponent("dfuctl"), externalCandidates: [])
    #expect(result == ToolResolution(url: override, source: .developmentOverride))
}

@Test func homebrewFallbackIsDiscovered() throws {
    let root = try temporaryDirectory(), homebrew = try executableFile(in: root.appendingPathComponent("opt/homebrew/bin"))
    #expect(ToolLocator.macVDMTool(environment: [:], bundleURL: nil, bundleResourceURL: nil, executableURL: nil, externalCandidates: [homebrew.path, "/missing"]) == ToolResolution(url: homebrew, source: .external(homebrew.deletingLastPathComponent().path)))
}

@Test func usrLocalFallbackIsDiscoveredAfterMissingHomebrew() throws {
    let root = try temporaryDirectory(), local = try executableFile(in: root.appendingPathComponent("usr/local/bin"))
    #expect(ToolLocator.macVDMTool(environment: [:], bundleURL: nil, bundleResourceURL: nil, executableURL: nil, externalCandidates: ["/missing", local.path])?.url == local)
}

@Test func unavailableAndNonExecutableHelpersAreRejected() throws {
    let root = try temporaryDirectory(), invalid = try executableFile(in: root, executable: false)
    #expect(ToolLocator.macVDMTool(environment: ["DFUCTL_MACVDMTOOL_PATH": invalid.path], bundleURL: nil, bundleResourceURL: nil, executableURL: nil, externalCandidates: []) == nil)
}

@Test func diagnosticsPreserveHelperSource() {
    let host = HostStatus(isAppleSilicon: true, macOSVersion: "26", macVDMToolPath: URL(fileURLWithPath: "/tool"), cfgutilPath: nil, macVDMToolSource: .bundled)
    #expect(host.macVDMToolSource?.category == "Bundled")
}

@Test func dfuCommandConstructionUsesSudoOnlyWhenNeeded() {
    let tool = URL(fileURLWithPath: "/bundle/macvdmtool")
    let root = DFUController.command(tool: tool, isRoot: true), user = DFUController.command(tool: tool, isRoot: false)
    #expect(root.executable == tool); #expect(root.arguments == ["dfu"])
    #expect(user.executable.path == "/usr/bin/sudo"); #expect(user.arguments == [tool.path, "dfu"])
    #expect(!user.arguments.contains("-S")); #expect(!user.arguments.contains(where: { $0.localizedCaseInsensitiveContains("password") }))
}

private struct PrivilegeFailureRunner: CommandRunning {
    func run(_ executable: URL, arguments: [String]) throws -> CommandResult { CommandResult(status: 1, stdout: Data(), stderr: Data("sudo: authentication failed\n".utf8)) }
    func runInteractive(_ executable: URL, arguments: [String]) throws -> CommandResult { try run(executable, arguments: arguments) }
}
private struct NormalDiscovery: DeviceDiscovering { func devices() throws -> [DFUDevice] { [DFUDevice(state: .normal, ecid: "TEST")] } }

@Test func privilegeFailureIsPropagatedClearly() {
    let controller = DFUController(discovery: NormalDiscovery(), runner: PrivilegeFailureRunner(), tool: URL(fileURLWithPath: "/tool"))
    #expect(throws: DFUError.privilegeRequired("sudo: authentication failed\n")) { try controller.enterDFU(timeout: 0) }
}

private final class InteractiveRunnerSpy: @unchecked Sendable, CommandRunning {
    private let lock = NSLock(); private(set) var interactiveCalls = 0
    func run(_ executable: URL, arguments: [String]) throws -> CommandResult { CommandResult(status: 0, stdout: Data(), stderr: Data()) }
    func runInteractive(_ executable: URL, arguments: [String]) throws -> CommandResult { lock.withLock { interactiveCalls += 1 }; return CommandResult(status: 0, stdout: Data(), stderr: Data()) }
}

private final class SequencedDiscovery: @unchecked Sendable, DeviceDiscovering {
    private let lock = NSLock(); private var sequence: [[DFUDevice]]
    init(_ sequence: [[DFUDevice]]) { self.sequence = sequence }
    func devices() throws -> [DFUDevice] { lock.withLock { if sequence.count > 1 { return sequence.removeFirst() }; return sequence.first ?? [] } }
}

@Test func successfulHelperStillRequiresVerifiedSameTargetTransition() throws {
    let normal = DFUDevice(state: .normal, model: "Mac14,2", ecid: "0xABC"), dfu = DFUDevice(state: .dfu, model: "Mac14,2", ecid: "0xabc")
    let discovery = SequencedDiscovery([[normal], [dfu]]), runner = InteractiveRunnerSpy()
    try DFUController(discovery: discovery, runner: runner, tool: URL(fileURLWithPath: "/tool")).enterDFU(timeout: 1)
    #expect(runner.interactiveCalls == 1)
}

@Test func helperExitZeroDoesNotHideFailedTransition() {
    let normal = DFUDevice(state: .normal, model: "Mac14,2", ecid: "0xABC")
    let discovery = SequencedDiscovery([[normal], [normal]]), runner = InteractiveRunnerSpy()
    #expect(throws: DFUError.transitionTimedOut) { try DFUController(discovery: discovery, runner: runner, tool: URL(fileURLWithPath: "/tool")).enterDFU(timeout: 0) }
    #expect(runner.interactiveCalls == 1)
}
