import Foundation
import Testing
@testable import DFUAppSupport
@testable import DFUCore

private func fakeApp(_ root: URL, name: String, version: String, build: String, marker: String = "valid") throws -> URL {
    let app = root.appendingPathComponent(name)
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("Library/LaunchServices"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": ApplicationDestinationPolicy.bundleIdentifier, "CFBundleShortVersionString": version, "CFBundleVersion": build]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    for path in ["MacOS/DFUUtility", "Library/LaunchServices/DFUPrivilegedHelper", "Resources/macvdmtool", "Resources/DFUUtility-LICENSE.txt"] {
        try Data().write(to: contents.appendingPathComponent(path))
    }
    try marker.write(to: app.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
    return app
}

private func installerFixture() throws -> (URL, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DFUUtility-installer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (root, root.appendingPathComponent("staging"), root.appendingPathComponent("Updates"))
}

@Test func applicationDestinationPolicyAcceptsOnlyDFUUtilityBundles() throws {
    let (root, _, _) = try installerFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let app = try fakeApp(root, name: "DFUUtility.app", version: "0.9.0", build: "1")
    #expect(try ApplicationDestinationPolicy().resolve(currentAppURL: app) == app.resolvingSymlinksInPath())
    let other = root.appendingPathComponent("Other.app"); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    #expect(throws: ApplicationInstallError.self) { try ApplicationDestinationPolicy().resolve(currentAppURL: other) }
}

@Test func applicationInstallerReplacesAndRetiresBackupOnlyAfterVerification() throws {
    let (root, staging, _) = try installerFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let old = try fakeApp(root, name: "DFUUtility.app", version: "0.9.0", build: "1", marker: "old")
    let staged = try fakeApp(staging, name: "DFUUtility.app", version: "0.10.0", build: "1", marker: "new")
    let verifier: ApplicationInstaller.Verifier = { url, version, build in
        (try? String(contentsOf: url.appendingPathComponent("marker"))) == "new" && version.description == "0.10.0" && build == "1"
    }
    let transaction = BinaryInstallTransaction(expectedVersion: SemanticVersion(tag: "v0.10.0")!, expectedBuild: "1", artifactURL: staged, destinationURL: old, backupURL: root.appendingPathComponent(".backup"), resultURL: root.appendingPathComponent("result"))
    try ApplicationInstaller(verifier: verifier).install(transaction: transaction)
    #expect(try String(contentsOf: old.appendingPathComponent("marker")) == "new")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".backup").path))
}

@Test func applicationInstallerRollsBackWhenInPlaceVerificationFails() throws {
    let (root, staging, _) = try installerFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let old = try fakeApp(root, name: "DFUUtility.app", version: "0.9.0", build: "1", marker: "old")
    let staged = try fakeApp(staging, name: "DFUUtility.app", version: "0.10.0", build: "1", marker: "new")
    let verifier: ApplicationInstaller.Verifier = { url, _, _ in (try? String(contentsOf: url.appendingPathComponent("marker"))) == "old" }
    let transaction = BinaryInstallTransaction(expectedVersion: SemanticVersion(tag: "v0.10.0")!, expectedBuild: "1", artifactURL: staged, destinationURL: old, backupURL: root.appendingPathComponent(".backup"), resultURL: root.appendingPathComponent("result"))
    #expect(throws: ApplicationInstallError.self) { try ApplicationInstaller(verifier: verifier).install(transaction: transaction) }
    #expect(try String(contentsOf: old.appendingPathComponent("marker")) == "old")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".backup").path))
}

@Test func binaryTransactionStoreUsesRestrictivePermissionsAndRejectsMalformedData() throws {
    let (root, _, _) = try installerFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("transaction.json"), store = BinaryInstallTransactionStore(url: url)
    let tx = BinaryInstallTransaction(expectedVersion: SemanticVersion(tag: "v0.10.0")!, expectedBuild: "1", artifactURL: root.appendingPathComponent("a.app"), destinationURL: root.appendingPathComponent("DFUUtility.app"), backupURL: root.appendingPathComponent("backup"), resultURL: root.appendingPathComponent("result"))
    try store.write(tx)
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try Data("not-json".utf8).write(to: url)
    #expect(throws: ApplicationInstallError.self) { try store.read() }
}

@Test @MainActor func generatedBackupPathUsesRealUniqueUUID() {
    let destination = URL(fileURLWithPath: "/tmp/DFUUtility.app")
    let first = UpdateCoordinator.backupURL(for: destination)
    let second = UpdateCoordinator.backupURL(for: destination)
    #expect(first.deletingLastPathComponent() == destination.deletingLastPathComponent())
    #expect(first.lastPathComponent.hasPrefix(".DFUUtility-backup-"))
    #expect(!first.lastPathComponent.contains("UUID().uuidString"))
    #expect(first != second)
    #expect(UUID(uuidString: String(first.lastPathComponent.dropFirst(".DFUUtility-backup-".count))) != nil)
}

@Test func transactionCarriesOriginatingPIDForInstallerHandoff() {
    let tx = BinaryInstallTransaction(expectedVersion: SemanticVersion(tag: "v0.10.4")!, expectedBuild: "1", artifactURL: URL(fileURLWithPath: "/tmp/a.app"), destinationURL: URL(fileURLWithPath: "/tmp/DFUUtility.app"), backupURL: URL(fileURLWithPath: "/tmp/.backup"), resultURL: URL(fileURLWithPath: "/tmp/result"), originatingPID: 4242)
    #expect(tx.originatingPID == 4242)
}

@Test func relaunchObservationRequiresDistinctProcessAtExpectedBundle() {
    let expected = URL(fileURLWithPath: "/tmp/DFUUtility.app")
    #expect(BinaryHandoffPolicy.accepts(observedPID: 200, originatingPID: 100, observedBundleURL: expected, expectedBundleURL: expected))
    #expect(!BinaryHandoffPolicy.accepts(observedPID: 100, originatingPID: 100, observedBundleURL: expected, expectedBundleURL: expected))
    #expect(!BinaryHandoffPolicy.accepts(observedPID: 200, originatingPID: 100, observedBundleURL: URL(fileURLWithPath: "/tmp/Other.app"), expectedBundleURL: expected))
    #expect(!BinaryHandoffPolicy.accepts(observedPID: 200, originatingPID: 100, observedBundleURL: nil, expectedBundleURL: expected))
}
