import Foundation
import CryptoKit
import Testing
@testable import DFUCore

private let sampleURL = URL(string: "https://updates.cdn-apple.com/test/UniversalMac.ipsw")!
private func release(version: String = "26.6.2", build: String = "25G83", size: Int64? = nil) -> IPSWRelease { IPSWRelease(version: version, build: build, downloadURL: sampleURL, fileSize: size, checksum: nil, supportedDevices: ["Mac14,2"]) }
private func temporaryDirectory() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url }
private func fixture(_ name: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")) }

private struct ReleaseHTTPFixture: HTTPDataFetching {
    let data: Data; let status: Int
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private final class ArchiveFixtureRunner: @unchecked Sendable, CommandRunning {
    func run(_ executable: URL, arguments: [String]) throws -> CommandResult {
        if arguments.first == "-Z1" { return result("DFUUtility.app/Contents/Info.plist\nDFUUtility.app/Contents/MacOS/DFUUtility\n") }
        if arguments.first == "-qq" {
            let root = URL(fileURLWithPath: arguments.last!)
            let app = root.appendingPathComponent("DFUUtility.app")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Library/LaunchServices"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources/ThirdPartyLicenses"), withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": "org.dfuutility.app", "CFBundleShortVersionString": "0.10.0", "CFBundleVersion": "1"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            for path in ["Contents/MacOS/DFUUtility", "Contents/Library/LaunchServices/DFUPrivilegedHelper", "Contents/Resources/macvdmtool", "Contents/Resources/DFUUtility-LICENSE.txt", "Contents/Resources/ThirdPartyLicenses/macvdmtool-Apache-2.0.txt", "Contents/Resources/ThirdPartyLicenses/macvdmtool-UPSTREAM_REVISION.txt"] {
                try Data().write(to: app.appendingPathComponent(path)); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appendingPathComponent(path).path)
            }
        }
        return result("")
    }
}

private final class ListingRunner: @unchecked Sendable, CommandRunning {
    let listing: String
    init(_ listing: String) { self.listing = listing }
    func run(_ executable: URL, arguments: [String]) throws -> CommandResult { result(listing) }
}

private struct BinaryNetworkFixture: BinaryUpdateNetworking {
    let bytes: Data
    func download(_ url: URL, expectedSize: Int64, maximumSize: Int64, to destination: URL) async throws -> Int64 {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: destination)
        guard Int64(bytes.count) == expectedSize else { throw BinaryUpdateError.sizeMismatch(expected: expectedSize, actual: Int64(bytes.count)) }
        return Int64(bytes.count)
    }
}

private struct AcceptValidator: IPSWValidating { func validate(_ url: URL, release: IPSWRelease?, verifyChecksum: Bool) throws { guard FileManager.default.fileExists(atPath: url.path) else { throw DFUError.invalidIPSW("missing") } } }
private struct RejectValidator: IPSWValidating { func validate(_ url: URL, release: IPSWRelease?, verifyChecksum: Bool) throws { throw DFUError.invalidIPSW("test rejection") } }
private struct MockCatalogue: IPSWCatalogueFetching { let values: [IPSWRelease]; let error: Error?; init(_ values: [IPSWRelease] = [], error: Error? = nil) { self.values = values; self.error = error }; func releases() async throws -> [IPSWRelease] { if let error { throw error }; return values } }
private final class SequenceCommandRunner: @unchecked Sendable, CommandRunning {
    private let lock = NSLock(); private var results: [CommandResult]
    init(_ results: [CommandResult]) { self.results = results }
    func run(_ executable: URL, arguments: [String]) throws -> CommandResult { lock.withLock { results.isEmpty ? CommandResult(status: 1, stdout: Data(), stderr: Data()) : results.removeFirst() } }
}
private final class MacManifestRunner: @unchecked Sendable, CommandRunning {
    private let lock = NSLock(); private(set) var extractedPaths: [String] = []
    func run(_ executable: URL, arguments: [String]) throws -> CommandResult {
        if arguments.first == "-Z1" { return result("BootabilityBundle/Restore/BuildManifest.plist\nBootabilityBundle/Restore/Restore.plist\nBuildManifest.plist\nRestore.plist\n") }
        if arguments.first == "-p" {
            let path = arguments.last ?? ""; lock.withLock { extractedPaths.append(path) }
            let products = path == "BuildManifest.plist" ? ["Mac14,2", "Mac15,3"] : ["iSim1,1"]
            return CommandResult(status: 0, stdout: try PropertyListSerialization.data(fromPropertyList: ["SupportedProductTypes": products], format: .xml, options: 0), stderr: Data())
        }
        return result("4833c12d9d8d330d47216edbcaaf8cb4b926c99a  image.ipsw\n")
    }
    var manifests: [String] { lock.withLock { extractedPaths } }
}
private func result(_ string: String, status: Int32 = 0) -> CommandResult { CommandResult(status: status, stdout: Data(string.utf8), stderr: Data()) }
private actor MockDownloader: IPSWDownloading {
    enum Behavior: Sendable { case success, interrupted, failure }
    let behavior: Behavior; private(set) var calls = 0; private(set) var requested: [IPSWRelease] = []
    init(_ behavior: Behavior = .success) { self.behavior = behavior }
    func download(_ release: IPSWRelease, to partial: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        calls += 1; requested.append(release); try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("partial".utf8).write(to: partial)
        if behavior == .interrupted { throw CancellationError() }; if behavior == .failure { throw URLError(.cannotConnectToHost) }
    }
}

private final class CapturingValidator: @unchecked Sendable, IPSWValidating {
    private let lock = NSLock(); private var values: [IPSWRelease] = []
    func validate(_ url: URL, release: IPSWRelease?, verifyChecksum: Bool) throws { if let release { lock.withLock { values.append(release) } } }
    var releases: [IPSWRelease] { lock.withLock { values } }
}

@Test func parsesAppleCatalogueAndAggregatesModels() throws {
    let plist: [String: Any] = ["MobileDeviceSoftwareVersionsByVersion": ["1": ["MobileDeviceSoftwareVersions": [
        "Mac14,2": ["25G83": ["Restore": ["FirmwareURL": sampleURL.absoluteString, "FirmwareSHA1": "abc", "ProductVersion": "26.6.2", "BuildVersion": "25G83"]]],
        "Mac15,3": ["25G83": ["Restore": ["FirmwareURL": sampleURL.absoluteString, "FirmwareSHA1": "abc", "ProductVersion": "26.6.2", "BuildVersion": "25G83"]]]
    ]]]]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), parsed = try AppleIPSWCatalogue.parse(data)
    #expect(parsed.count == 1); #expect(parsed[0].version == "26.6.2"); #expect(parsed[0].checksum == "abc"); #expect(parsed[0].supportedDevices == ["Mac14,2", "Mac15,3"])
}

@Test func binaryUpdateSemanticVersionsAreStrictAndNumeric() {
    #expect(SemanticVersion(tag: "v0.10.0")! > SemanticVersion(tag: "v0.9.0")!)
    #expect(SemanticVersion(tag: "v0.9.10")! > SemanticVersion(tag: "v0.9.9")!)
    #expect(SemanticVersion(tag: "0.10.0") == nil)
    #expect(SemanticVersion(tag: "v01.2.3") == nil)
    #expect(SemanticVersion(tag: "v1.0.0-beta") == nil)
}

@Test func githubReleaseSelectionRejectsUntrustedOrUnusableMetadata() throws {
    let asset = GitHubReleaseAsset(name: "DFUUtility-0.10.0.zip", downloadURL: URL(string: "https://github.com/thehallifax/DFUUtility/releases/download/v0.10.0/DFUUtility-0.10.0.zip")!, size: 100, digest: "sha256:" + String(repeating: "a", count: 64))
    let validator = ReleaseMetadataValidator(); let installed = SemanticVersion(tag: "v0.9.0")!
    let valid = try validator.validate(.init(tagName: "v0.10.0", draft: false, prerelease: false, releaseURL: nil, assets: [asset]), installed: installed)
    #expect(valid.version.description == "0.10.0")
    #expect(throws: BinaryUpdateError.self) { try validator.validate(.init(tagName: "v0.10.0-beta", draft: false, prerelease: true, releaseURL: nil, assets: [asset]), installed: installed) }
    #expect(throws: BinaryUpdateError.self) { try validator.validate(.init(tagName: "v0.10.0", draft: false, prerelease: false, releaseURL: nil, assets: [asset, asset]), installed: installed) }
    let badURL = GitHubReleaseAsset(name: asset.name, downloadURL: URL(string: "http://evil.example/update.zip")!, size: 100, digest: asset.digest)
    #expect(throws: BinaryUpdateError.self) { try validator.validate(.init(tagName: "v0.10.0", draft: false, prerelease: false, releaseURL: nil, assets: [badURL]), installed: installed) }
    let badDigest = GitHubReleaseAsset(name: asset.name, downloadURL: asset.downloadURL, size: 100, digest: "sha256:bad")
    #expect(throws: BinaryUpdateError.self) { try validator.validate(.init(tagName: "v0.10.0", draft: false, prerelease: false, releaseURL: nil, assets: [badDigest]), installed: installed) }
    let draft = GitHubReleaseMetadata(tagName: "v0.11.0", draft: true, prerelease: false, releaseURL: nil, assets: [asset])
    #expect(validator.selectLatest(from: [draft, .init(tagName: "v0.10.0", draft: false, prerelease: false, releaseURL: nil, assets: [asset])], installed: installed)?.version == SemanticVersion(tag: "v0.10.0")!)
}

@Test func githubReleaseClientUsesFixedEndpointAndParsesStableFields() async throws {
    let json = #"[{"tag_name":"v0.10.0","draft":false,"prerelease":false,"html_url":"https://github.com/thehallifax/DFUUtility/releases/tag/v0.10.0","assets":[{"name":"DFUUtility-0.10.0.zip","browser_download_url":"https://github.com/thehallifax/DFUUtility/releases/download/v0.10.0/DFUUtility-0.10.0.zip","size":100,"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}]"#.data(using: .utf8)!
    let releases = try await GitHubReleaseClient(client: ReleaseHTTPFixture(data: json, status: 200)).releases()
    #expect(releases.count == 1); #expect(releases[0].tagName == "v0.10.0"); #expect(releases[0].assets[0].digest?.hasPrefix("sha256:") == true)
}

@Test func binaryArtifactDigestAndBundleStructureAreVerifiedWithoutInstallation() throws {
    let root = try temporaryDirectory(), archive = root.appendingPathComponent("DFUUtility-0.10.0.zip")
    let bytes = Data("fixture archive bytes".utf8); try bytes.write(to: archive)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let asset = GitHubReleaseAsset(name: "DFUUtility-0.10.0.zip", downloadURL: URL(string: "https://github.com/thehallifax/DFUUtility/releases/download/v0.10.0/DFUUtility-0.10.0.zip")!, size: Int64(bytes.count), digest: "sha256:\(digest)")
    let release = try ReleaseMetadataValidator().validate(.init(tagName: "v0.10.0", draft: false, prerelease: false, releaseURL: nil, assets: [asset]), installed: SemanticVersion(tag: "v0.9.0")!)
    let artifact = DownloadedBinaryArtifact(url: archive, byteCount: Int64(bytes.count))
    let verified = try BinaryArtifactVerifier(runner: ArchiveFixtureRunner()).verify(artifact, release: release, stagingDirectory: root.appendingPathComponent("staging"))
    #expect(verified.version.description == "0.10.0"); #expect(verified.build == "1"); #expect(verified.appURL.path.hasPrefix(root.path))
    try Data("different".utf8).write(to: archive)
    #expect(throws: BinaryUpdateError.self) { try BinaryArtifactVerifier(runner: ArchiveFixtureRunner()).verify(artifact, release: release, stagingDirectory: root.appendingPathComponent("staging-bad")) }
}

@Test func binaryArchiveRejectsTraversalAndMultipleApplicationBundles() throws {
    let root = try temporaryDirectory(), archive = root.appendingPathComponent("update.zip")
    try Data("archive".utf8).write(to: archive)
    for listing in ["../outside\n", "DFUUtility.app/Contents/a\nOther.app/Contents/b\n", "/absolute\n"] {
        #expect(throws: BinaryUpdateError.self) { try SafeZIPInspector(runner: ListingRunner(listing)).extract(archive, into: root.appendingPathComponent(UUID().uuidString)) }
    }
}

@Test func binaryDownloaderCleansFailedArtifactAndUsesControlledDestination() async throws {
    let root = try temporaryDirectory(), destination = root.appendingPathComponent("downloads")
    let bytes = Data("binary".utf8), asset = GitHubReleaseAsset(name: "DFUUtility-0.10.0.zip", downloadURL: URL(string: "https://github.com/thehallifax/DFUUtility/releases/download/v0.10.0/DFUUtility-0.10.0.zip")!, size: Int64(bytes.count), digest: "sha256:" + String(repeating: "a", count: 64))
    let release = ValidatedBinaryRelease(version: SemanticVersion(tag: "v0.10.0")!, releaseURL: nil, asset: asset, digest: String(repeating: "a", count: 64))
    let downloaded = try await BinaryUpdateDownloader(networking: BinaryNetworkFixture(bytes: bytes)).download(release, in: destination)
    #expect(downloaded.byteCount == Int64(bytes.count)); #expect(downloaded.url.path.hasPrefix(destination.path))
    let mismatch = GitHubReleaseAsset(name: asset.name, downloadURL: asset.downloadURL, size: Int64(bytes.count + 1), digest: asset.digest)
    let bad = ValidatedBinaryRelease(version: release.version, releaseURL: nil, asset: mismatch, digest: release.digest)
    do { _ = try await BinaryUpdateDownloader(networking: BinaryNetworkFixture(bytes: bytes)).download(bad, in: destination); Issue.record("Expected size mismatch") } catch { #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(asset.name).path)) }
}

@Test func parsesAppleMobileCatalogueByFamilyAndProductType() async throws {
    let phoneURL = URL(string: "https://updates.cdn-apple.com/iPhone.ipsw")!, tabletURL = URL(string: "https://updates.cdn-apple.com/iPad.ipsw")!
    let plist: [String: Any] = ["MobileDeviceSoftwareVersionsByVersion": ["1": ["MobileDeviceSoftwareVersions": [
        "iPhone15,2": ["23G83": ["Restore": ["FirmwareURL": phoneURL.absoluteString, "FirmwareSHA1": "phone", "ProductVersion": "26.6.1", "BuildVersion": "23G83"]]],
        "iPad13,18": ["23G83": ["Restore": ["FirmwareURL": tabletURL.absoluteString, "FirmwareSHA1": "tablet", "ProductVersion": "26.6.1", "BuildVersion": "23G83"]]]
    ]]]]
    let parsed = try AppleMobileIPSWCatalogue.parse(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
    #expect(parsed.count == 2); #expect(parsed.contains { $0.platform == .iOS && $0.supportedDevices == ["iPhone15,2"] })
    #expect(parsed.contains { $0.platform == .iPadOS && $0.supportedDevices == ["iPad13,18"] }); #expect(parsed.allSatisfy { $0.signingStatus == .appleCatalogue && $0.isSigned == nil })
    let service = AppleIPSWService(catalogue: MockCatalogue(), mobileCatalogue: MockCatalogue(parsed), downloader: MockDownloader(), cache: IPSWCache(directory: try temporaryDirectory()), validator: AcceptValidator())
    #expect(try await service.availableImages(for: DFUDevice(family: .iPhone, state: .normal, productType: "iPhone15,2")).map(\.platform) == [.iOS])
    #expect(try await service.availableImages(for: DFUDevice(family: .iPad, state: .normal, productType: "iPad13,18")).map(\.platform) == [.iPadOS])
    #expect(try await service.availableImages(for: DFUDevice(family: .iPhone, state: .normal, productType: "iPhone99,9")).isEmpty)
}

@Test func iPad711CatalogueUsesIPadOSProductFilteringAndNamespace() async throws {
    let padURL = URL(string: "https://updates.cdn-apple.com/iPad7-11.ipsw")!
    let plist: [String: Any] = ["MobileDeviceSoftwareVersionsByVersion": ["1": ["MobileDeviceSoftwareVersions": [
        "iPhone7,2": ["16H81": ["Restore": ["FirmwareURL": "https://updates.cdn-apple.com/phone.ipsw", "FirmwareSHA1": "phone", "ProductVersion": "12.5.8", "BuildVersion": "16H81"]]],
        "iPad7,11": ["22H374": ["Restore": ["FirmwareURL": padURL.absoluteString, "FirmwareSHA1": "tablet", "ProductVersion": "18.7.10", "BuildVersion": "22H374"]]],
        "iPad7,12": ["22H374": ["Restore": ["FirmwareURL": "https://updates.cdn-apple.com/other.ipsw", "FirmwareSHA1": "other", "ProductVersion": "18.7.10", "BuildVersion": "22H374"]]]
    ]]]]
    let releases = try AppleMobileIPSWCatalogue.parse(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
    let service = AppleIPSWService(catalogue: MockCatalogue(), mobileCatalogue: MockCatalogue(releases), downloader: MockDownloader(), cache: IPSWCache(directory: try temporaryDirectory()), validator: AcceptValidator())
    let compatible = try await service.availableImages(for: DFUDevice(family: .iPad, state: .normal, productType: "iPad7,11"))
    #expect(compatible.count == 1); #expect(compatible[0].platform == .iPadOS); #expect(compatible[0].version == "18.7.10"); #expect(compatible[0].build == "22H374"); #expect(compatible[0].supportedDevices == ["iPad7,11"])
    #expect(IPSWCache(directory: URL(fileURLWithPath: "/tmp/cache")).destination(for: compatible[0]).path.contains("/iPadOS/22H374/"))
}

@Test func cfgutilDiscoveryClassifiesMacIPhoneAndIPad() throws {
    func details(_ deviceClass: String, _ product: String, _ state: String, _ ecid: String) -> CommandResult {
        result("{\"ECID\":\"\(ecid)\",\"deviceClass\":\"\(deviceClass)\",\"deviceType\":\"\(product)\",\"bootedState\":\"\(state)\",\"UDID\":\"SYNTHETIC-\(ecid)\",\"serialNumber\":\"SERIAL-REDACTED\"}")
    }
    let runner = SequenceCommandRunner([result("{\"Devices\":[\"1\",\"2\",\"3\"]}"), details("Mac", "Mac14,2", "Booted", "1"), details("iPhone", "iPhone15,2", "Recovery", "2"), details("iPad", "iPad13,18", "DFU", "3")])
    let devices = try ConfiguratorDeviceDiscovery(runner: runner, cfgutil: URL(fileURLWithPath: "/cfgutil")).devices()
    #expect(devices.map(\.family) == [.mac, .iPhone, .iPad]); #expect(devices.map(\.state) == [.normal, .recovery, .dfu])
    #expect(devices[1].restoreProductType == "iPhone15,2"); #expect(devices[1].serialNumber == "SERIAL-REDACTED")
}

@Test func cfgutilDiscoveryNormalizesIdentifierKeyCasing() throws {
    let runner = SequenceCommandRunner([
        result("{\"Devices\":[\"1\"]}"),
        result("{\"ecid\":\"LOWER-ECID\",\"deviceclass\":\"Mac\",\"devicetype\":\"MacBookAir10,1\",\"bootedState\":\"Booted\",\"udid\":\"LOWER-UDID\",\"serialnumber\":\"LOWER-SERIAL\"}")
    ])
    let device = try #require(ConfiguratorDeviceDiscovery(runner: runner, cfgutil: URL(fileURLWithPath: "/cfgutil")).devices().first)
    #expect(device.ecid == "LOWER-ECID"); #expect(device.identifier == "LOWER-UDID"); #expect(device.serialNumber == "LOWER-SERIAL")
}

@Test func mobileCacheIsPlatformSeparatedWithoutMovingMacCache() throws {
    let cache = IPSWCache(directory: URL(fileURLWithPath: "/tmp/cache"))
    let mac = release(), phone = IPSWRelease(platform: .iOS, version: "26.6.1", build: "23G83", downloadURL: sampleURL, supportedDevices: ["iPhone15,2"])
    let tablet = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: sampleURL, supportedDevices: ["iPad13,18"])
    #expect(cache.destination(for: mac).path == "/tmp/cache/25G83/UniversalMac_26.6.2_25G83_Restore.ipsw")
    #expect(cache.destination(for: phone).path.contains("/iOS/23G83/")); #expect(cache.destination(for: tablet).path.contains("/iPadOS/23G83/"))
}

@Test func sameMobileBuildForDifferentProductSetIsNotACacheHit() throws {
    let cache = IPSWCache(directory: try temporaryDirectory())
    let ipad16 = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad16.ipsw")!, supportedDevices: ["iPad16,8", "iPad16,9", "iPad16,10", "iPad16,11"])
    let ipad12 = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad12.ipsw")!, supportedDevices: ["iPad12,1", "iPad12,2"])
    try cache.prepare(for: ipad16)
    try Data(repeating: 1, count: 17).write(to: cache.partialURL(for: ipad16))
    let stored = try cache.commit(partial: cache.partialURL(for: ipad16), release: ipad16)
    #expect(cache.cachedURL(for: ipad16) == stored)
    #expect(cache.cachedURL(for: ipad12) == nil)
    #expect(try cache.validCachedURL(for: ipad12, validator: AcceptValidator()) == nil)
}

@Test func sameBuildMobileAssetsHaveDistinctPartialAndFinalPaths() throws {
    let cache = IPSWCache(directory: try temporaryDirectory())
    let ipad12 = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad12.ipsw")!, checksum: "3bd45a92d29555141103a7423f78bc40099ec204", supportedDevices: ["iPad12,1", "iPad12,2"])
    let ipad16 = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad16.ipsw")!, checksum: "1ef2543373a4a72c43adde7be5825e3d78339fad", supportedDevices: ["iPad16,8", "iPad16,9", "iPad16,10", "iPad16,11"])
    #expect(cache.partialURL(for: ipad12) != cache.partialURL(for: ipad16))
    #expect(cache.destination(for: ipad12) != cache.destination(for: ipad16))
    #expect(cache.releaseDirectory(for: ipad12) != cache.releaseDirectory(for: ipad16))
}

@Test func sameBuildMobileAssetsCanCoexistAndRemainIndependentlyManaged() throws {
    let cache = IPSWCache(directory: try temporaryDirectory()), validator = AcceptValidator()
    let ipad12 = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad12.ipsw")!, checksum: "ipad12", supportedDevices: ["iPad12,1"])
    let ipad16 = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad16.ipsw")!, checksum: "ipad16", supportedDevices: ["iPad16,10"])
    for release in [ipad12, ipad16] {
        try cache.prepare(for: release); try Data(release.checksum!.utf8).write(to: cache.partialURL(for: release))
        _ = try cache.commit(partial: cache.partialURL(for: release), release: release)
    }
    let entries = try cache.managedEntries(validator: validator).filter { $0.release.build == "23G83" }
    #expect(entries.count == 2)
    #expect(Set(entries.map { $0.release.checksum }) == Set(["ipad12", "ipad16"]))
    #expect(cache.cachedURL(for: ipad12) != cache.cachedURL(for: ipad16))
}

@Test func matchingLegacyMobilePartialIsRecognizedButNeverCrossResumed() throws {
    let root = try temporaryDirectory(), cache = IPSWCache(directory: root)
    let ipad12 = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad12.ipsw")!, checksum: "ipad12", supportedDevices: ["iPad12,1"])
    let ipad16 = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad16.ipsw")!, checksum: "ipad16", supportedDevices: ["iPad16,10"])
    let legacy = root.appendingPathComponent("iPadOS/downloads/23G83.partial")
    try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("variant-16".utf8).write(to: legacy)
    try JSONEncoder().encode(ipad16).write(to: legacy.deletingPathExtension().appendingPathExtension("json"))
    #expect(cache.partialURL(for: ipad16) == legacy)
    #expect(cache.partialURL(for: ipad12) != legacy)
    #expect(cache.partialURL(for: ipad12) != cache.partialURL(for: ipad16))
}

@Test func rangeResponsePolicyRestartsFullResponsesAndRejectsWrongRanges() throws {
    #expect(try AppleIPSWDownloader.resumeDisposition(existing: 4096, status: 200, contentRange: nil) == .restart)
    #expect(try AppleIPSWDownloader.resumeDisposition(existing: 4096, status: 206, contentRange: "bytes 4096-8191/8192") == .append)
    #expect(throws: IPSWServiceError.self) { try AppleIPSWDownloader.resumeDisposition(existing: 4096, status: 206, contentRange: "bytes 0-8191/8192") }
}

@Test func downloadKeepsVariantURLChecksumAndProductsPairedThroughValidation() async throws {
    let release = IPSWRelease(platform: .iPadOS, version: "26.6.1", build: "23G83", downloadURL: URL(string: "https://updates.cdn-apple.com/ipad12.ipsw")!, checksum: "3bd45a92d29555141103a7423f78bc40099ec204", supportedDevices: ["iPad12,1", "iPad12,2"])
    let downloader = MockDownloader(), validator = CapturingValidator()
    let service = AppleIPSWService(catalogue: MockCatalogue(), downloader: downloader, cache: IPSWCache(directory: try temporaryDirectory()), validator: validator)
    _ = try await service.download(release)
    #expect(await downloader.requested == [release])
    #expect(validator.releases.last == release)
    #expect(validator.releases.last?.downloadURL == release.downloadURL)
    #expect(validator.releases.last?.checksum == release.checksum)
    #expect(validator.releases.last?.supportedDevices == release.supportedDevices)
}

@Test func managedCacheEnumeratesPlatformsPartialsValidationAndTotalSize() throws {
    let cache = IPSWCache(directory: try temporaryDirectory())
    let mac = release(), phone = IPSWRelease(platform: .iOS, version: "12.5.8", build: "16H81", downloadURL: sampleURL, supportedDevices: ["iPhone7,2"])
    let pad = IPSWRelease(platform: .iPadOS, version: "18.7.10", build: "22H374", downloadURL: sampleURL, supportedDevices: ["iPad7,11"])
    for value in [mac, phone] { try cache.prepare(for: value); try Data(repeating: 1, count: value == mac ? 11 : 13).write(to: cache.partialURL(for: value)); _ = try cache.commit(partial: cache.partialURL(for: value), release: value) }
    try cache.prepare(for: pad); try Data(repeating: 1, count: 17).write(to: cache.partialURL(for: pad))
    let entries = try cache.managedEntries(validator: AcceptValidator())
    #expect(entries.map(\.release.platform).contains(.macOS)); #expect(entries.map(\.release.platform).contains(.iOS)); #expect(entries.map(\.release.platform).contains(.iPadOS))
    #expect(entries.first { $0.release.build == "22H374" }?.state == .partial)
    #expect(entries.filter { $0.state == .completeValidated }.count == 2)
    #expect(entries.reduce(0) { $0 + $1.sizeBytes } == 41)
}

@Test func managedCacheRemovesOnlyRequestedManagedEntryAndRejectsExternalFiles() throws {
    let root = try temporaryDirectory(), cache = IPSWCache(directory: root.appendingPathComponent("cache")), value = release()
    try cache.prepare(for: value); try Data(repeating: 1, count: 9).write(to: cache.partialURL(for: value))
    let partial = try #require(cache.managedEntries(validator: AcceptValidator()).first)
    try cache.remove(partial)
    #expect(!FileManager.default.fileExists(atPath: partial.url.path)); #expect(try cache.managedEntries(validator: AcceptValidator()).isEmpty)
    let external = root.appendingPathComponent("manual.ipsw"); try Data("manual".utf8).write(to: external)
    let unsafe = ManagedIPSWEntry(release: value, state: .completeValidated, sizeBytes: 6, url: external)
    #expect(throws: (any Error).self) { try cache.remove(unsafe) }
    #expect(FileManager.default.fileExists(atPath: external.path))
}

@Test func realMacCacheLayoutPrefersRootManifestAndIsSharedAsValidated() throws {
    let cacheRoot = try temporaryDirectory().appendingPathComponent("IPSW"), release = IPSWRelease(
        version: "26.6.2", build: "25G83", downloadURL: URL(string: "https://updates.cdn-apple.com/UniversalMac.ipsw")!,
        fileSize: 1_100_001, checksum: "4833c12d9d8d330d47216edbcaaf8cb4b926c99a", supportedDevices: ["Mac14,2", "Mac15,3"]
    )
    let cache = IPSWCache(directory: cacheRoot), folder = cacheRoot.appendingPathComponent("25G83")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let image = folder.appendingPathComponent("UniversalMac_26.6.2_25G83_Restore.ipsw")
    try Data(repeating: 0, count: 1_100_001).write(to: image)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(release).write(to: folder.appendingPathComponent("metadata.json"))
    let runner = MacManifestRunner(), validator = IPSWValidator(runner: runner)

    let managed = try cache.managedEntries(validator: validator)
    #expect(managed.count == 1); #expect(managed[0].state == .completeValidated); #expect(managed[0].validationFailure == nil)
    #expect(try cache.validCachedURL(for: release, validator: validator) == image)
    #expect(runner.manifests == ["BuildManifest.plist", "BuildManifest.plist"])
}

@Test func validationDiagnosticsIdentifySupportedDevicePredicate() throws {
    let root = try temporaryDirectory(), image = root.appendingPathComponent("image.ipsw"); try Data(repeating: 0, count: 1_100_001).write(to: image)
    let release = IPSWRelease(version: "1", build: "A", downloadURL: sampleURL, fileSize: 1_100_001, supportedDevices: ["Mac14,2"])
    let runner = SequenceCommandRunner([result("Nested/BuildManifest.plist\nRestore.plist\n"), CommandResult(status: 0, stdout: try PropertyListSerialization.data(fromPropertyList: ["SupportedProductTypes": ["iSim1,1"]], format: .xml, options: 0), stderr: Data())])
    let result = IPSWValidator(runner: runner).validationResult(image, release: release, verifyChecksum: false)
    guard case .invalid(let failure) = result else { Issue.record("Expected a diagnostic validation failure"); return }
    #expect(failure.predicate == .supportedDevices); #expect(failure.reason.contains("compatible"))
}

@Test func validatorRejectsWrongProductMobileIPSW() throws {
    let root = try temporaryDirectory(), file = root.appendingPathComponent("wrong.ipsw"); try Data(repeating: 0, count: 1_100_001).write(to: file)
    let manifest = try PropertyListSerialization.data(fromPropertyList: ["SupportedProductTypes": ["iPad13,18"]], format: .xml, options: 0)
    let runner = SequenceCommandRunner([result("BuildManifest.plist\nRestore.plist\n"), CommandResult(status: 0, stdout: manifest, stderr: Data())])
    let phone = IPSWRelease(platform: .iOS, version: "26.6.1", build: "23G83", downloadURL: sampleURL, supportedDevices: ["iPhone15,2"])
    #expect(throws: DFUError.self) { try IPSWValidator(runner: runner).validate(file, release: phone, verifyChecksum: false) }
}

@Test func validatorRejectsWrongIPadProductIPSW() throws {
    let root = try temporaryDirectory(), file = root.appendingPathComponent("wrong-ipad.ipsw"); try Data(repeating: 0, count: 1_100_001).write(to: file)
    let manifest = try PropertyListSerialization.data(fromPropertyList: ["SupportedProductTypes": ["iPad7,12"]], format: .xml, options: 0)
    let runner = SequenceCommandRunner([result("BuildManifest.plist\nRestore.plist\n"), CommandResult(status: 0, stdout: manifest, stderr: Data())])
    let expected = IPSWRelease(platform: .iPadOS, version: "18.7.10", build: "22H374", downloadURL: sampleURL, supportedDevices: ["iPad7,11"])
    #expect(throws: DFUError.self) { try IPSWValidator(runner: runner).validate(file, release: expected, verifyChecksum: false) }
}

@Test func dfuControllerRejectsAutomaticEntryForIPhone() {
    struct PhoneDiscovery: DeviceDiscovering { func devices() throws -> [DFUDevice] { [DFUDevice(family: .iPhone, state: .normal, ecid: "SYNTHETIC-ECID")] } }
    #expect(throws: DFUError.self) { try DFUController(discovery: PhoneDiscovery(), runner: CapturingRunner(), tool: URL(fileURLWithPath: "/tool")).enterDFU(timeout: 0) }
}

@Test func targetedRestoreSelectsOneDeviceAndKeepsECIDArgument() throws {
    let root = try temporaryDirectory(), ipsw = root.appendingPathComponent("phone.ipsw"); try Data(repeating: 0, count: 1_100_001).write(to: ipsw)
    let manifest = try PropertyListSerialization.data(fromPropertyList: ["SupportedProductTypes": ["iPhone15,2"]], format: .xml, options: 0)
    let runner = SequenceCommandRunner([result("BuildManifest.plist\nRestore.plist\n"), result("BuildManifest.plist\nRestore.plist\n"), CommandResult(status: 0, stdout: manifest, stderr: Data())])
    struct TwoDevices: DeviceDiscovering { func devices() throws -> [DFUDevice] { [DFUDevice(family: .mac, state: .dfu, ecid: "MAC"), DFUDevice(family: .iPhone, state: .dfu, ecid: "PHONE", productType: "iPhone15,2")] } }
    let command = try RestoreEngine(discovery: TwoDevices(), runner: runner, cfgutil: URL(fileURLWithPath: "/cfgutil")).command(for: .targetedRestore(ipsw, ecid: "PHONE"))
    #expect(command.2.family == .iPhone); #expect(command.1.contains("PHONE")); #expect(command.1.suffix(2) == ["--ipsw", ipsw.path])
}

private struct FixedRestoreDiscovery: DeviceDiscovering {
    let values: [DFUDevice]
    func devices() throws -> [DFUDevice] { values }
}

private func mobileRestoreCommand(family: AppleDeviceFamily, state: DeviceState, product: String, ecid: String = "SYNTHETIC-ECID", manifestProducts: [String]? = nil) throws -> (URL, [String], DFUDevice) {
    let root = try temporaryDirectory(), ipsw = root.appendingPathComponent("mobile.ipsw")
    try Data(repeating: 0, count: 1_100_001).write(to: ipsw)
    let manifest = try PropertyListSerialization.data(fromPropertyList: ["SupportedProductTypes": manifestProducts ?? [product]], format: .xml, options: 0)
    let runner = SequenceCommandRunner([result("BuildManifest.plist\nRestore.plist\n"), result("BuildManifest.plist\nRestore.plist\n"), CommandResult(status: 0, stdout: manifest, stderr: Data())])
    let target = DFUDevice(family: family, state: state, ecid: ecid, productType: product)
    return try RestoreEngine(discovery: FixedRestoreDiscovery(values: [target]), runner: runner, cfgutil: URL(fileURLWithPath: "/cfgutil")).command(for: .restore(ipsw))
}

@Test func restoreEngineUsesExplicitFamilyStateMatrix() throws {
    for family in [AppleDeviceFamily.iPhone, .iPad] {
        let product = family == .iPhone ? "iPhone15,2" : "iPad13,18"
        for state in [DeviceState.recovery, .dfu] {
            let command = try mobileRestoreCommand(family: family, state: state, product: product)
            #expect(command.2.state == state)
            #expect(command.1.contains("restore")); #expect(command.1.contains("--ipsw"))
        }
        do {
            _ = try mobileRestoreCommand(family: family, state: .normal, product: product)
            Issue.record("Expected Normal-state mobile Restore rejection")
        } catch let error as DFUError {
            #expect(error.localizedDescription == "Restore requires the \(family.displayName) to be in Recovery or DFU mode.")
        }
    }
    #expect(RestoreTargetStatePolicy.allowsRestore(DFUDevice(family: .mac, state: .dfu)))
    #expect(!RestoreTargetStatePolicy.allowsRestore(DFUDevice(family: .mac, state: .recovery)))
    #expect(!RestoreTargetStatePolicy.allowsRestore(DFUDevice(family: .mac, state: .normal)))
}

@Test func recoveryMobileRestoreKeepsTargetedCfgutilCommandShape() throws {
    let phone = try mobileRestoreCommand(family: .iPhone, state: .recovery, product: "iPhone15,2", ecid: "PHONE-ECID")
    #expect(phone.1.prefix(7) == ["--progress", "--verbose", "--timeout", "30", "--ecid", "PHONE-ECID", "restore"])
    #expect(phone.1[phone.1.count - 2] == "--ipsw"); #expect(phone.1.last?.hasSuffix("mobile.ipsw") == true)
    let pad = try mobileRestoreCommand(family: .iPad, state: .recovery, product: "iPad13,18", ecid: "PAD-ECID")
    #expect(pad.1.contains("PAD-ECID")); #expect(pad.1.contains("restore")); #expect(pad.1.contains("--ipsw"))
}

@Test func targetedReviveAndRestartCommandsRemainUnambiguous() throws {
    let target = DFUDevice(family: .iPhone, state: .recovery, ecid: "PHONE", productType: "iPhone15,2")
    let engine = RestoreEngine(discovery: FixedRestoreDiscovery(values: [target]), runner: SequenceCommandRunner([]), cfgutil: URL(fileURLWithPath: "/cfgutil"))
    let revive = try engine.command(for: .targetedRevive(ecid: "PHONE"))
    #expect(revive.1 == ["--progress", "--verbose", "--timeout", "30", "--ecid", "PHONE", "revive"])
    let restart = try engine.command(for: .targetedReboot(ecid: "PHONE"))
    #expect(restart.1 == ["--progress", "--verbose", "--timeout", "30", "--ecid", "PHONE", "restart"])
}

@Test func mobileRestoreStillRequiresProductCompatibilityAndSingleTarget() throws {
    #expect(throws: DFUError.self) { _ = try mobileRestoreCommand(family: .iPhone, state: .recovery, product: "iPhone15,2", manifestProducts: ["iPhone16,1"]) }

    let root = try temporaryDirectory(), ipsw = root.appendingPathComponent("mobile.ipsw")
    try Data(repeating: 0, count: 1_100_001).write(to: ipsw)
    let validationRunner = SequenceCommandRunner([result("BuildManifest.plist\nRestore.plist\n")])
    let missingProduct = DFUDevice(family: .iPhone, state: .recovery, ecid: "PHONE")
    #expect(throws: DFUError.invalidIPSW("the selected mobile target does not expose a product type")) {
        _ = try RestoreEngine(discovery: FixedRestoreDiscovery(values: [missingProduct]), runner: validationRunner, cfgutil: URL(fileURLWithPath: "/cfgutil")).command(for: .restore(ipsw))
    }

    let twoTargets = [DFUDevice(family: .iPhone, state: .recovery, ecid: "ONE", productType: "iPhone15,2"), DFUDevice(family: .iPad, state: .recovery, ecid: "TWO", productType: "iPad13,18")]
    let multipleRunner = SequenceCommandRunner([result("BuildManifest.plist\nRestore.plist\n")])
    #expect(throws: DFUError.multipleTargets(2)) {
        _ = try RestoreEngine(discovery: FixedRestoreDiscovery(values: twoTargets), runner: multipleRunner, cfgutil: URL(fileURLWithPath: "/cfgutil")).command(for: .restore(ipsw))
    }
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

@Test func accessoryConnectionReadinessIsHonestlyUnknownAndDeterministic() {
    let first = AccessoryConnectionReadiness(), second = AccessoryConnectionReadiness()
    #expect(first == second)
    #expect(first.policy == .notReliablyReadable)
    #expect(first.detectedState.contains("does not provide DFUUtility a supported way to read"))
    #expect(!first.detectedState.localizedCaseInsensitiveContains("always allow"))
    #expect(first.diagnosticLines.contains { $0.contains("Privacy & Security → Accessories") })
    #expect(first.diagnosticLines.contains { $0.contains("Automatically allow when unlocked") })
}

@Test func accessoryReadinessImplementationHasNoSecurityMutationPath() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: root.appendingPathComponent("Sources/DFUCore/AccessoryConnectionReadiness.swift"), encoding: .utf8)
    for forbidden in ["defaults write", "UserDefaults", "Process(", "osascript", "NSWorkspace", "openURL", "AuthorizationExecute"] {
        #expect(!source.contains(forbidden))
    }
}

@Test func detailedDiagnosticsRetainExistingFactsAndReportAccessoryPolicyAsUnreadable() {
    let host = HostStatus(isAppleSilicon: true, macOSVersion: "26.6", macVDMToolPath: URL(fileURLWithPath: "/tool"), cfgutilPath: URL(fileURLWithPath: "/cfgutil"), macVDMToolSource: .bundled)
    let report = DoctorReport(status: UtilityStatus(host: host, targets: []), configuratorPresent: true, cacheDirectory: URL(fileURLWithPath: "/cache"), cacheWritable: true, restoreSupported: true)
    let text = AcceptanceDiagnostics.render(report: report, privilegeMode: .community, helperState: .notRegistered, appURL: URL(fileURLWithPath: "/missing.app"))
    #expect(text.contains("Apple Configurator: Available")); #expect(text.contains("cfgutil: /cfgutil")); #expect(text.contains("macvdmtool: /tool"))
    #expect(text.contains("Accessory Connections: Not available"))
    #expect(text.contains("does not provide DFUUtility a supported way to read this setting"))
    #expect(!text.contains("Accessory Connections: Ready"))
}

@Test func liveAppleCatalogueOptIn() async throws {
    guard ProcessInfo.processInfo.environment["DFU_LIVE_TESTS"] == "1" else { return }
    let releases = try await AppleIPSWCatalogue().releases(); #expect(!releases.isEmpty); #expect(releases.allSatisfy { $0.downloadURL.host == "updates.cdn-apple.com" })
}

@Test func liveAppleMobileCatalogueOptIn() async throws {
    guard ProcessInfo.processInfo.environment["DFU_LIVE_TESTS"] == "1" else { return }
    let releases = try await AppleMobileIPSWCatalogue().releases()
    #expect(releases.contains { $0.platform == .iOS && $0.supportedDevices.contains(where: { $0.hasPrefix("iPhone") }) })
    #expect(releases.contains { $0.platform == .iPadOS && $0.supportedDevices.contains(where: { $0.hasPrefix("iPad") }) })
    #expect(releases.allSatisfy { $0.downloadURL.host?.hasSuffix("apple.com") == true && $0.signingStatus == .appleCatalogue && $0.isSigned == nil })
}

@Test func existingErrorsRemainUseful() { #expect(DFUError.targetNotInDFU.localizedDescription.contains("not in DFU")); #expect(DFUError.multipleTargets(2).localizedDescription.contains("2")) }

private func executableFile(in directory: URL, name: String = "macvdmtool", executable: Bool = true) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name); try Data("tool".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path); return url
}

private final class CapturingRunner: @unchecked Sendable, CommandRunning {
    private let lock = NSLock()
    let result: CommandResult
    private(set) var calls: [(URL, [String])] = []
    init(status: Int32 = 0, output: String = "") { result = CommandResult(status: status, stdout: Data(), stderr: Data(output.utf8)) }
    func run(_ executable: URL, arguments: [String]) throws -> CommandResult { lock.withLock { calls.append((executable, arguments)) }; return result }
}

private struct ThrowingRunner: CommandRunning {
    func run(_ executable: URL, arguments: [String]) throws -> CommandResult { throw CocoaError(.executableNotLoadable) }
}

@Test func signingCapabilitySelectsPrivilegeMode() {
    let adHoc = CodeSignatureInfo(identifier: PrivilegedDFUConstants.appIdentifier, teamIdentifier: nil, isValid: true, hardenedRuntime: false)
    let signedApp = CodeSignatureInfo(identifier: PrivilegedDFUConstants.appIdentifier, teamIdentifier: "TEAM", isValid: true, hardenedRuntime: true)
    let signedHelper = CodeSignatureInfo(identifier: PrivilegedDFUConstants.machService, teamIdentifier: "TEAM", isValid: true, hardenedRuntime: true)
    let invalidHelper = CodeSignatureInfo(identifier: PrivilegedDFUConstants.machService, teamIdentifier: "TEAM", isValid: false, hardenedRuntime: true)
    #expect(PrivilegeModeSelector.select(app: adHoc, helper: adHoc) == .community)
    #expect(PrivilegeModeSelector.select(app: signedApp, helper: signedHelper) == .signedHelper)
    #expect(PrivilegeModeSelector.select(app: signedApp, helper: adHoc) == .community)
    #expect(PrivilegeModeSelector.select(app: signedApp, helper: invalidHelper) == .community)
}

@Test func communityRequestInvokesOnlyOsascriptAndFixedDFUOperation() throws {
    let root = try temporaryDirectory(), tool = try executableFile(in: root.appendingPathComponent("odd ' quote $ directory"))
    let runner = CapturingRunner()
    try CommunityDFURequest(runner: runner, tool: tool).enterDFU()
    #expect(runner.calls.count == 1)
    #expect(runner.calls[0].0 == CommunityDFURequest.osascriptURL)
    #expect(runner.calls[0].1.count == 2 && runner.calls[0].1[0] == "-e")
    let script = runner.calls[0].1[1]
    #expect(script == CommunityDFURequest.appleScript(tool: tool))
    #expect(CommunityDFURequest.posixShellQuote(tool.path).contains("'\\''"))
    #expect(script.hasSuffix(" dfu\" with administrator privileges"))
}

@Test func communityToolResolutionExcludesOverridesAndExternalCopies() throws {
    let root = try temporaryDirectory(), project = root.appendingPathComponent("project"), external = root.appendingPathComponent("external")
    let helper = try executableFile(in: project), override = try executableFile(in: external)
    let result = ToolLocator.communityMacVDMTool(bundleURL: nil, bundleResourceURL: nil, executableURL: project.appendingPathComponent("DFUUtility"))
    #expect(result == ToolResolution(url: helper, source: .projectBuild))
    #expect(result?.url != override)
}

@Test func communityAuthorizationErrorsRemainDistinct() throws {
    let tool = try executableFile(in: try temporaryDirectory())
    #expect(throws: CommunityDFUError.authorizationCancelled) { try CommunityDFURequest(runner: CapturingRunner(status: 1, output: "execution error: User canceled. (-128)"), tool: tool).enterDFU() }
    #expect(throws: CommunityDFUError.authorizationFailed("execution error: Not authorized. (-60007)")) { try CommunityDFURequest(runner: CapturingRunner(status: 1, output: "execution error: Not authorized. (-60007)"), tool: tool).enterDFU() }
    #expect(throws: MacVDMToolFailure.self) { try CommunityDFURequest(runner: CapturingRunner(status: 1, output: "macvdmtool: device not found"), tool: tool).enterDFU() }
    #expect(throws: MacVDMToolFailure.self) { try CommunityDFURequest(runner: ThrowingRunner(), tool: tool).enterDFU() }
}

@Test func macVDMToolFailuresAreClassifiedWithoutDecodingOpaqueReply() {
    let observed = "Mac type: J414sAP\nLooking for HPM devices...\nFound: IOService:/fixture\nConnection: Source\nStatus: APP\nUnlocking... OK\nEntering DBMa mode... Status: DBMa\nRebooting target into DFU mode... VDM failed (reply: 0x05ac8092)\nExiting DBMa mode... OK\nVDM failed"
    let communication = MacVDMToolFailure.classify(status: 255, output: observed)
    #expect(communication.kind == .targetCommunication); #expect(communication.exitStatus == 255)
    #expect(communication.replyCode == "0x05ac8092")
    #expect(communication.localizedDescription.contains("did not accept the DFU transition"))
    #expect(communication.diagnosticDescription.contains(observed))
    let wrapped = MacVDMToolFailure.classify(status: 1, output: observed + "\nexecution error: VDM failed (255)")
    #expect(wrapped.exitStatus == 255); #expect(wrapped.wrapperExitStatus == 1)
    let missing = MacVDMToolFailure.classify(status: 255, output: "Looking for HPM devices...\nNo matching devices")
    #expect(missing.kind == .noCompatibleTargetPath)
    #expect(MacVDMToolFailure.classify(status: 7, output: "unexpected fixture failure").kind == .unknown)
}

@Test func missingFinalVDMReplyRemainsFailureWithRediscoveryGuidance() {
    let output = "Looking for HPM devices...\nFound: IOService:/fixture\nUnlocking... OK\nEntering DBMa mode... Status: DBMa\nDid not get a reply to VDM"
    let failure = MacVDMToolFailure.classify(status: 255, output: output)
    #expect(failure.kind == .targetCommunication)
    #expect(failure.exitStatus == 255)
    #expect(failure.reachedDBMaWithoutFinalReply)
    #expect(failure.localizedDescription.contains("Couldn’t verify"))
    #expect(failure.recoverySuggestion?.contains("may already be in DFU") == true)
    #expect(failure.recoverySuggestion?.contains("click Refresh") == true)
    #expect(failure.recoverySuggestion?.contains("reconnect the cable") == true)
    #expect(failure.recoverySuggestion?.contains("model-specific DFU-port guidance") == true)
    #expect(failure.diagnosticDescription.contains("DFU state remains unverified until rediscovery"))

    let incompleteEvidence = MacVDMToolFailure.classify(status: 255, output: "Entering DBMa mode... Failed.\nSomething else was OK.\nDid not get a reply to VDM")
    #expect(incompleteEvidence.kind == .targetCommunication)
    #expect(!incompleteEvidence.reachedDBMaWithoutFinalReply)
    #expect(!incompleteEvidence.localizedDescription.contains("Couldn’t verify"))
    #expect(incompleteEvidence.recoverySuggestion?.contains("may already be in DFU") == false)
}

@Test func communityDiagnosticsDoNotRequireHelperRegistration() {
    let text = AcceptanceDiagnostics.render(report: nil, privilegeMode: .community, helperState: .notRegistered, appURL: URL(fileURLWithPath: "/missing.app"))
    #expect(text.contains("Privilege mode: Community"))
    #expect(text.contains("GUI DFU authorization: System administrator prompt"))
    #expect(text.contains("Privileged helper: Not required"))
    #expect(!text.contains("Helper registration: Not registered"))
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

private struct InteractiveVDMFailureRunner: CommandRunning {
    func run(_ executable: URL, arguments: [String]) throws -> CommandResult { CommandResult(status: 255, stdout: Data("VDM failed (reply: 0x05ac8092)\nVDM failed\n".utf8), stderr: Data()) }
    func runInteractive(_ executable: URL, arguments: [String]) throws -> CommandResult { try run(executable, arguments: arguments) }
}

@Test func sudoWrappedToolFailureIsNotMisclassifiedAsAuthorization() {
    let controller = DFUController(discovery: NormalDiscovery(), runner: InteractiveVDMFailureRunner(), tool: URL(fileURLWithPath: "/tool"))
    do { try controller.enterDFU(timeout: 0); Issue.record("Expected VDM failure") }
    catch let failure as MacVDMToolFailure { #expect(failure.kind == .targetCommunication); #expect(failure.replyCode == "0x05ac8092") }
    catch { Issue.record("Unexpected classification: \(error)") }
}

@Test func directToolProcessLaunchFailureIsClassified() {
    let controller = DFUController(discovery: NormalDiscovery(), runner: ThrowingRunner(), tool: URL(fileURLWithPath: "/tool"))
    do { try controller.enterDFU(timeout: 0); Issue.record("Expected launch failure") }
    catch let failure as MacVDMToolFailure { #expect(failure.kind == .processLaunch); #expect(!failure.output.isEmpty) }
    catch { Issue.record("Unexpected classification: \(error)") }
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

@Test func cfgutilParsesRealRestoreStagesAndSentinel() {
    let fixture = try! fixture("cfgutil-restore-success.txt")
    var parser = CFGUtilEventParser()
    let events = parser.consume(fixture, final: true)
    #expect(events.contains(.waitingForDevice))
    #expect(events.contains(.stageStarted(name: "Installing System", index: 2, total: 2)))
    #expect(events.contains(.progress(stage: "Installing System", fraction: 0.495)))
    #expect(events.contains(.stageCompleted(name: "Installing System")))
    #expect(!events.contains { if case .progress(_, let value) = $0 { return value < 0 }; return false })
}

@Test func cfgutilClampsProgressAndResetsStageName() {
    let fixture = """
    Step = "Downloading System";
    Type = Step;

    Progress = "1.7";
    Type = Progress;

    Step = "Installing System";
    Type = Step;

    Progress = "0.1";
    Type = Progress;

    """
    var parser = CFGUtilEventParser()
    let events = parser.consume(Data(fixture.utf8), final: true)
    #expect(events.contains(.progress(stage: "Downloading System", fraction: 1)))
    #expect(events.contains(.progress(stage: "Installing System", fraction: 0.1)))
}

@Test func operationLogRedactsCredentialsAndUsesPrivatePermissions() throws {
    let root = try temporaryDirectory(), logger = OperationLogger(directory: root)
    let url = try logger.start(operation: "Restore", target: DFUDevice(state: .dfu, model: "Mac14,2", ecid: "TEST"), release: release())
    try logger.append("password=secret authorizationToken: abc123 useful message", to: url)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(!text.contains("secret")); #expect(!text.contains("abc123")); #expect(text.contains("useful message"))
    let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    #expect(mode == 0o600)
}

@Test func privilegedCallerPolicyRejectsUnauthorizedIdentity() {
    let helper = CallerIdentity(identifier: "org.dfuutility.privileged-helper", teamIdentifier: "TEAM")
    #expect(CallerIdentityPolicy.permits(CallerIdentity(identifier: "org.dfuutility.app", teamIdentifier: "TEAM"), helper: helper, developmentAdHoc: false))
    #expect(!CallerIdentityPolicy.permits(CallerIdentity(identifier: "org.attacker.app", teamIdentifier: "TEAM"), helper: helper, developmentAdHoc: false))
    #expect(!CallerIdentityPolicy.permits(CallerIdentity(identifier: "org.dfuutility.app", teamIdentifier: "OTHER"), helper: helper, developmentAdHoc: false))
}

@Test func developmentCallerRequiresExactAdHocCodeHash() {
    let caller = CallerIdentity(identifier: PrivilegedDFUConstants.appIdentifier, teamIdentifier: nil)
    let hash = Data([1, 2, 3])
    #expect(CallerValidationPolicy.permits(caller: caller, expectedTeam: nil, callerHash: hash, expectedHash: hash))
    #expect(!CallerValidationPolicy.permits(caller: caller, expectedTeam: nil, callerHash: hash, expectedHash: Data([9])))
    #expect(!CallerValidationPolicy.permits(caller: CallerIdentity(identifier: "org.attacker", teamIdentifier: nil), expectedTeam: nil, callerHash: hash, expectedHash: hash))
}

@Test func productionCallerRequiresMatchingTeamEvenWithHash() {
    let hash = Data([1])
    #expect(CallerValidationPolicy.permits(caller: CallerIdentity(identifier: PrivilegedDFUConstants.appIdentifier, teamIdentifier: "TEAM"), expectedTeam: "TEAM", callerHash: hash, expectedHash: hash))
    #expect(!CallerValidationPolicy.permits(caller: CallerIdentity(identifier: PrivilegedDFUConstants.appIdentifier, teamIdentifier: "OTHER"), expectedTeam: "TEAM", callerHash: hash, expectedHash: hash))
}

@Test func helperLayoutUsesAbsoluteExecutableRatherThanRelativeArgv() {
    let helper = URL(fileURLWithPath: "/Applications/DFUUtility.app/Contents/Library/LaunchServices/DFUPrivilegedHelper")
    #expect(PrivilegedHelperLayout.containingAppURL(for: helper)?.path == "/Applications/DFUUtility.app")
    #expect(PrivilegedHelperLayout.bundledToolURL(for: helper)?.path == "/Applications/DFUUtility.app/Contents/Resources/macvdmtool")
    #expect(PrivilegedHelperLayout.containingAppURL(for: URL(fileURLWithPath: "/DFUPrivilegedHelper")) == nil)
}

@Test func launchDaemonIdentifiersMatchRuntimeConstants() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let plistURL = root.appendingPathComponent("Packaging/org.dfuutility.privileged-helper.plist")
    let data = try Data(contentsOf: plistURL), plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(plist["Label"] as? String == PrivilegedDFUConstants.machService)
    #expect(plist["BundleProgram"] as? String == PrivilegedDFUConstants.helperBundleProgram)
    let services = try #require(plist["MachServices"] as? [String: Bool]); #expect(services == [PrivilegedDFUConstants.machService: true])
    #expect(plist["AssociatedBundleIdentifiers"] as? [String] == [PrivilegedDFUConstants.appIdentifier])
}

@Test func helperConnectionFailuresNeverMasqueradeAsAuthorizationCancellation() {
    #expect(PrivilegedDFUClientError.authorizationCancelled.localizedDescription == "Administrator authorization was cancelled.")
    #expect(!PrivilegedDFUClientError.connectionInterrupted.localizedDescription.localizedCaseInsensitiveContains("cancelled"))
    #expect(!PrivilegedDFUClientError.connectionInvalidated.localizedDescription.localizedCaseInsensitiveContains("cancelled"))
    #expect(!PrivilegedDFUClientError.callerRejected.localizedDescription.localizedCaseInsensitiveContains("cancelled"))
}

@Test func privilegedXPCSurfaceHasNoCommandOrPathParameters() {
    // The request selector contains only authorization and reply; no caller-
    // controlled executable, command, or argument crosses the boundary.
    #expect(NSStringFromSelector(#selector(PrivilegedDFUXPCProtocol.enterDFU(authorization:reply:))) == "enterDFUWithAuthorization:reply:")
}

@Test func helperProtocolVersionCompatibilityIsExplicit() {
    #expect(HelperProtocolCompatibility.evaluate(installed: 1, required: 1) == .compatible)
    #expect(HelperProtocolCompatibility.evaluate(installed: 1, required: 2) == .outdated)
    #expect(HelperProtocolCompatibility.evaluate(installed: 3, required: 2) == .newerIncompatible)
}

@Test func helperRegistrationAndUpgradeStatesAreDistinct() {
    #expect(HelperStateResolver.resolve(registration: .notRegistered) == .notRegistered)
    #expect(HelperStateResolver.resolve(registration: .registrationRequested) == .registrationRequested)
    #expect(HelperStateResolver.resolve(registration: .awaitingApproval) == .awaitingApproval)
    #expect(HelperStateResolver.resolve(registration: .enabled) == .registered)
    #expect(HelperStateResolver.resolve(registration: .enabled, installedProtocol: 0) == .upgradeRequired(installedProtocol: 0))
    #expect(HelperStateResolver.resolve(registration: .enabled, installedProtocol: 2) == .incompatibleNewer(installedProtocol: 2))
    #expect(HelperStateResolver.resolve(registration: .enabled, installedProtocol: 1, version: "0.5.0") == .running(version: "0.5.0", protocolVersion: 1))
    #expect(HelperStateResolver.resolve(registration: .notRegistered) == .notRegistered) // post-uninstall state
}

@Test func buildVersionAndDiagnosticsMetadataPropagate() throws {
    #expect(BuildMetadata.displayVersion == "0.10.8 (1)")
    #expect(BuildMetadata.helperProtocolVersion == 1)
    let text = AcceptanceDiagnostics.render(report: nil, privilegeMode: .signedHelper, helperState: .upgradeRequired(installedProtocol: 0), appURL: URL(fileURLWithPath: "/missing.app"))
    #expect(text.contains("App version: 0.10.8 (1)")); #expect(text.contains("Responding — upgrade required")); #expect(text.contains("Required helper protocol: 1"))
    #expect(text.contains("Helper registration signing: Unsupported"))
}

@Test func registrationFailureRetainsSanitizedTechnicalDetails() {
    let detail = "SMAppServiceErrorDomain code 1: Operation not permitted"
    let error = PrivilegedDFUClientError.registrationFailed(detail)
    #expect(error.localizedDescription.contains("See Diagnostics"))
    if case .registrationFailed(let retained) = error { #expect(retained == detail) }
    else { Issue.record("Expected registration failure") }
}

@Test func packagingScriptRejectsUnknownArgumentsBeforeBuilding() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [root.appendingPathComponent("scripts/package-app.sh").path, "--unknown"]
    process.standardOutput = Pipe(); process.standardError = Pipe(); try process.run(); process.waitUntilExit()
    #expect(process.terminationStatus == 64)
}

@Test func localInstallScriptValidatesArgumentsAndDestination() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let script = root.appendingPathComponent("scripts/install-local.sh")
    func invoke(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [script.path] + arguments
        process.standardOutput = output; process.standardError = output; try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    let unknown = try invoke(["--unknown"])
    #expect(unknown.0 == 64); #expect(unknown.1.contains("Usage:"))
    let help = try invoke(["--test", "--verbose", "--help"])
    #expect(help.0 == 0); #expect(help.1.contains("[--test] [--verbose]"))
    let text = try String(contentsOf: script, encoding: .utf8)
    #expect(text.contains("/Applications/DFUUtility.app"))
    #expect(text.contains("scripts/package-app.sh release"))
    #expect(text.contains("scripts/verify-app.sh"))
    #expect(text.contains("--test")); #expect(!text.contains("--skip-tests"))
    #expect(text.contains("--verbose")); #expect(text.contains("if [ \"$run_tests\" -eq 1 ]"))
    #expect(text.contains("if [ \"$verbose\" -eq 1 ]")); #expect(text.contains("run_step \"Running tests\""))
    #expect(text.contains("cat \"$log\"")); #expect(text.contains("FAILED")); #expect(text.contains("--- end $name output ---"))
    #expect(text.contains("Full test mode requires a newer Swift/Xcode toolchain")); #expect(text.contains("installed without --test"))
    #expect(text.contains("Mac DFU entry may request administrator authorization")); #expect(text.contains("iPhone/iPad DFU uses guided physical-button instructions"))
    #expect(text.contains("Previous app moved to Trash:")); #expect(text.contains("Open Applications → DFUUtility"))
    #expect(text.contains("To update DFUUtility later:")); #expect(text.contains("scripts/update.sh"))
    #expect(text.contains("Library/Application Support/DFUUtility")); #expect(text.contains("update-source")); #expect(text.contains("chmod 600"))
}

@Test func updaterShellSafetyMatrix() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let script = root.appendingPathComponent("scripts/test-update.sh")
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script.path]
    process.standardOutput = output; process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    #expect(process.terminationStatus == 0)
    #expect(text.contains("Updater shell tests passed."))
}

@Test func mainWindowAndApplicationMenuShareManualUpdateAction() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let content = try String(contentsOf: root.appendingPathComponent("Sources/DFUUtilityApp/ContentView.swift"), encoding: .utf8)
    let application = try String(contentsOf: root.appendingPathComponent("Sources/DFUUtilityApp/DFUUtilityApp.swift"), encoding: .utf8)
    #expect(content.contains("Button(checkButtonTitle) { model.requestManualUpdateCheck() }"))
    #expect(application.contains("Button(\"Check for Updates…\") { model.requestManualUpdateCheck() }"))
}

private func releaseLibrary(_ command: String) throws -> (Int32, String) {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let library = root.appendingPathComponent("scripts/release-check-lib.sh").path
    let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", ". \"$1\"; \(command)", "release-test", library]; process.standardOutput = output; process.standardError = output
    try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

@Test func releaseCheckParsesVersionAndRejectsMalformedMetadata() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    #expect(try releaseLibrary("validate_version_metadata \"\(root.appendingPathComponent("Config/Version.env").path)\"; metadata_value \"\(root.appendingPathComponent("Config/Version.env").path)\" MARKETING_VERSION").1 == "0.10.8")
    let malformed = try temporaryDirectory().appendingPathComponent("Version.env"); try Data("MARKETING_VERSION=bad!\n".utf8).write(to: malformed)
    #expect(try releaseLibrary("validate_version_metadata \"\(malformed.path)\"").0 != 0)
    #expect(try releaseLibrary("metadata_value /definitely/missing MARKETING_VERSION").0 != 0)
}

@Test func communityHardwareAcceptanceRecordIsCompleteAndVersioned() throws {
    struct Acceptance: Decodable {
        struct Hardware: Decodable { let displayName: String; let identifier: String }
        struct Results: Decodable { let normalDetection, guiEnterDFU, sameECIDVerification, guiRevive, guiRestore, liveProgress, targetRestartVerification: String }
        struct MobileHardware: Decodable {
            struct Results: Decodable { let normalDetection, recoveryDetection, guidedDFU, sameECIDVerification, imageDiscovery, guiImageDownload, ipswValidation, guiRestore, liveProgress, targetRestartVerification: String }
            let displayName, productType, acceptanceDate, cableObservation, scopeNote: String; let results: Results
        }
        struct IPadHardware: Decodable {
            struct Results: Decodable { let normalDetection, recoveryDetection, guidedDFU, sameECIDVerification, imageDiscovery, guiImageDownload, ipswValidation, guiRestore, liveProgress, targetRestartVerification: String }
            struct TimingObservation: Decodable { let clock: String; let disappearanceSeconds, releaseCueSeconds, dfuEnumerationSeconds: Double }
            let displayName, productType, modelNumber, observationDate, cableObservation, scopeNote: String
            let results: Results; let timingObservation: TimingObservation
        }
        struct NewerMacHardware: Decodable {
            struct Results: Decodable { let discovery, automaticEnterDFU, dfuRediscovery, guiRestore, liveProgress, targetRestartVerification: String }
            let displayName, productType, observationDate, restoreImage, portObservation, scopeNote: String
            let results: Results
        }
        struct MultiDeviceHardware: Decodable {
            let productType, observationDate, sequentialRestore, scopeNote: String
            let deviceCount: Int
        }
        struct MobileCachedFirmwareAssignment: Decodable {
            struct Results: Decodable { let exactCompatibleAssetAssigned, validatedManagedCacheReused, deviceRemainedUnselected, recoveryRestoreReadiness, explicitOperationSelectionRequired: String }
            let productType, observationDate, restoreImage, scopeNote: String
            let results: Results
        }
        let appVersion, distributionMode, acceptanceDate: String
        let hardware: Hardware; let results: Results; let mobileHardware: MobileHardware; let iPadHardware: IPadHardware
        let newerMacHardware: NewerMacHardware; let multiDeviceHardware: MultiDeviceHardware
        let mobileCachedFirmwareAssignment: MobileCachedFirmwareAssignment
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let value = try JSONDecoder().decode(Acceptance.self, from: Data(contentsOf: root.appendingPathComponent("Config/HardwareAcceptance.json")))
    #expect(value.appVersion == BuildMetadata.version); #expect(value.distributionMode == "Community")
    #expect(value.hardware.displayName == "MacBook Air M2"); #expect(value.hardware.identifier == "Mac14,2")
    #expect(!value.acceptanceDate.isEmpty)
    #expect([value.results.normalDetection, value.results.guiEnterDFU, value.results.sameECIDVerification, value.results.guiRevive, value.results.guiRestore, value.results.liveProgress, value.results.targetRestartVerification].allSatisfy { $0 == "PASS" })
    #expect(value.mobileHardware.displayName == "iPhone 6"); #expect(value.mobileHardware.productType == "iPhone7,2")
    #expect([value.mobileHardware.results.normalDetection, value.mobileHardware.results.recoveryDetection, value.mobileHardware.results.guidedDFU, value.mobileHardware.results.sameECIDVerification, value.mobileHardware.results.imageDiscovery, value.mobileHardware.results.guiImageDownload, value.mobileHardware.results.ipswValidation, value.mobileHardware.results.guiRestore, value.mobileHardware.results.liveProgress, value.mobileHardware.results.targetRestartVerification].allSatisfy { $0 == "PASS" })
    #expect(value.mobileHardware.cableObservation.contains("not a universal")); #expect(value.mobileHardware.scopeNote.contains("Broader"))
    #expect(value.iPadHardware.displayName == "iPad (7th generation) Wi-Fi"); #expect(value.iPadHardware.productType == "iPad7,11"); #expect(value.iPadHardware.modelNumber == "A2197")
    #expect([value.iPadHardware.results.normalDetection, value.iPadHardware.results.guidedDFU, value.iPadHardware.results.sameECIDVerification, value.iPadHardware.results.imageDiscovery, value.iPadHardware.results.guiImageDownload, value.iPadHardware.results.ipswValidation].allSatisfy { $0 == "PASS" })
    #expect([value.iPadHardware.results.recoveryDetection, value.iPadHardware.results.guiRestore].allSatisfy { $0 == "PASS" })
    #expect([value.iPadHardware.results.liveProgress, value.iPadHardware.results.targetRestartVerification].allSatisfy { $0 == "PENDING" })
    #expect(value.iPadHardware.timingObservation.clock == "monotonic")
    #expect(value.iPadHardware.timingObservation.disappearanceSeconds == 5.370)
    #expect(value.iPadHardware.timingObservation.releaseCueSeconds == 6.438)
    #expect(value.iPadHardware.timingObservation.dfuEnumerationSeconds == 17.170)
    #expect(value.iPadHardware.cableObservation.contains("does not establish that USB-A to Lightning is required"))
    #expect(value.iPadHardware.scopeNote.contains("Recovery-mode GUI Restore") && value.iPadHardware.scopeNote.contains("remain pending"))
    #expect(value.newerMacHardware.productType == "Mac17,6")
    #expect([value.newerMacHardware.results.discovery, value.newerMacHardware.results.automaticEnterDFU, value.newerMacHardware.results.dfuRediscovery, value.newerMacHardware.results.guiRestore, value.newerMacHardware.results.liveProgress, value.newerMacHardware.results.targetRestartVerification].allSatisfy { $0 == "PASS" })
    #expect(value.newerMacHardware.restoreImage.contains("26.6.2 / 25G83"))
    #expect(value.newerMacHardware.portObservation.contains("rightmost USB-C port on the left side"))
    #expect(value.newerMacHardware.portObservation.contains("not a universal"))
    #expect(value.multiDeviceHardware.productType == "iPad12,1"); #expect(value.multiDeviceHardware.deviceCount == 2)
    #expect(value.multiDeviceHardware.sequentialRestore == "PASS")
    #expect(value.mobileCachedFirmwareAssignment.productType == "iPad12,1")
    #expect(value.mobileCachedFirmwareAssignment.restoreImage.contains("26.6.1 / 23G83"))
    #expect([value.mobileCachedFirmwareAssignment.results.exactCompatibleAssetAssigned, value.mobileCachedFirmwareAssignment.results.validatedManagedCacheReused, value.mobileCachedFirmwareAssignment.results.deviceRemainedUnselected, value.mobileCachedFirmwareAssignment.results.recoveryRestoreReadiness, value.mobileCachedFirmwareAssignment.results.explicitOperationSelectionRequired].allSatisfy { $0 == "PASS" })
    #expect(value.mobileCachedFirmwareAssignment.scopeNote.contains("No automatic download or Restore occurred"))
    let releaseCheck = try String(contentsOf: root.appendingPathComponent("scripts/release-check.sh"), encoding: .utf8)
    #expect(releaseCheck.contains("pass \"Hardware acceptance\"")); #expect(releaseCheck.contains("pass \"iPhone acceptance\"")); #expect(releaseCheck.contains("pass \"iPad acceptance\""))
    #expect(releaseCheck.contains("pass \"Newer Mac acceptance\"")); #expect(releaseCheck.contains("pass \"Multi-device acceptance\"")); #expect(releaseCheck.contains("pass \"Mobile cache assignment\""))
    #expect(releaseCheck.contains("for key in recoveryDetection guiRestore")); #expect(releaseCheck.contains("for key in liveProgress targetRestartVerification"))
    #expect(releaseCheck.contains("Recovery-mode Restore accepted; progress/restart verification pending"))
}

@Test func sanitizedIPhone72HardwareFixturesContainNoRealIdentifiers() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let names = ["iphone7,2-normal-status.txt", "iphone7,2-recovery-observation.txt", "iphone7,2-dfu-observation.txt", "iphone7,2-restore-success.txt"]
    for name in names {
        let text = try String(contentsOf: root.appendingPathComponent("Tests/Fixtures/\(name)"), encoding: .utf8)
        #expect(text.contains("iPhone7,2")); #expect(text.contains("SYNTHETIC") || text.contains("0x1234567890ABCDEF"))
        #expect(!text.contains("Users/")); #expect(!text.localizedCaseInsensitiveContains("hallifax"))
    }
}

@Test func sanitizedIPad711DFUFixtureRecordsOnlyTheAcceptedMilestone() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let text = try String(contentsOf: root.appendingPathComponent("Tests/Fixtures/ipad7,11-dfu-observation.txt"), encoding: .utf8)
    #expect(text.contains("iPad7,11")); #expect(text.contains("SYNTHETIC-IPAD-SERIAL")); #expect(text.contains("SYNTHETIC-IPAD-UDID"))
    #expect(text.contains("+5.370 s")); #expect(text.contains("+6.438 s")); #expect(text.contains("+17.170 s"))
    #expect(text.contains("Same-ECID verification: PASS")); #expect(text.contains("Restore initiated: No"))
    #expect(!text.contains("Recovery detected")); #expect(!text.contains("Restore completed")); #expect(!text.contains("Users/")); #expect(!text.localizedCaseInsensitiveContains("hallifax"))
}

@Test func releaseCheckArtifactIdentitySignatureAndResults() throws {
    #expect(try releaseLibrary("distribution_artifact_name 9.8.7").1 == "DFUUtility-9.8.7.zip")
    #expect(try releaseLibrary("classify_identities '1) HASH \"Developer ID Application: Example (TEAM)\"'").1 == "configured")
    #expect(try releaseLibrary("classify_identities '1) HASH \"Apple Development: Example\"'").1 == "not-configured")
    #expect(try releaseLibrary("classify_signature 'Authority=Developer ID Application: Example'").1 == "developer-id")
    #expect(try releaseLibrary("classify_signature 'Signature=adhoc'").1 == "ad-hoc")
    #expect(try releaseLibrary("release_result 0 2 development").1 == "DEVELOPMENT_RC_READY_WITH_WARNINGS")
    #expect(try releaseLibrary("release_result 1 0 strict").1 == "FAIL")
    #expect(try releaseLibrary("dirty_tree_outcome development").1 == "WARN")
    #expect(try releaseLibrary("dirty_tree_outcome strict").1 == "FAIL")
}

@Test func githubReleaseAssetRedirectPolicyIsExactAndHTTPSOnly() {
    let source = URL(string: "https://github.com/thehallifax/DFUUtility/releases/download/v0.10.2/DFUUtility-0.10.2.zip")!
    #expect(BinaryRedirectPolicy.allows(source: source, destination: URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/file")!))
    #expect(!BinaryRedirectPolicy.allows(source: source, destination: URL(string: "http://release-assets.githubusercontent.com/file")!))
    #expect(!BinaryRedirectPolicy.allows(source: source, destination: URL(string: "https://release-assets.githubusercontent.com.evil.example/file")!))
    #expect(!BinaryRedirectPolicy.allows(source: source, destination: URL(string: "https://evil-release-assets.githubusercontent.com/file")!))
    #expect(!BinaryRedirectPolicy.allows(source: source, destination: URL(string: "https://127.0.0.1/file")!))
    #expect(!BinaryRedirectPolicy.allows(source: source, destination: URL(string: "https://user:secret@release-assets.githubusercontent.com/file")!))
    #expect(!BinaryRedirectPolicy.allows(source: source, destination: URL(string: "https://release-assets.githubusercontent.com:8443/file")!))
    let logged = BinaryRedirectPolicy.logMessage(source: source, destination: URL(string: "https://release-assets.githubusercontent.com/file?token=secret.jwt")!, accepted: true)
    #expect(logged.contains("github.com") && logged.contains("release-assets.githubusercontent.com"))
    #expect(!logged.contains("token") && !logged.contains("secret.jwt") && !logged.contains("?"))
}
