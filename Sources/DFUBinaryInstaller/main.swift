import DFUAppSupport
import Foundation
import Darwin

let arguments = CommandLine.arguments
let environment = ProcessInfo.processInfo.environment
let explicitTestMode = arguments.count == 3 && arguments[1] == "--test-mode"
guard arguments.count == 2 || (explicitTestMode && environment["DFUUTILITY_INSTALLER_TEST_MODE"] == "1") else { exit(64) }
let testMode = explicitTestMode
let descriptor = URL(fileURLWithPath: arguments[testMode ? 2 : 1]).standardizedFileURL.resolvingSymlinksInPath()
let support: URL
if testMode, let override = environment["DFUUTILITY_INSTALLER_SUPPORT_ROOT"] {
    support = URL(fileURLWithPath: override).standardizedFileURL.resolvingSymlinksInPath()
} else {
    support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DFUUtility", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
}
let staging = support.appendingPathComponent("Updates", isDirectory: true)
func isWithin(_ child: URL, _ root: URL) -> Bool {
    func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
    let childPath = canonicalPath(child)
    let rootPath = canonicalPath(root)
    return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
}
guard isWithin(descriptor, support) else { exit(65) }
let store = BinaryInstallTransactionStore(url: descriptor)
do {
    let transaction = try store.read()
    guard transaction.destinationURL.pathExtension.lowercased() == "app",
          transaction.artifactURL.pathExtension.lowercased() == "app",
          isWithin(transaction.resultURL, support),
          isWithin(transaction.artifactURL, staging) else { throw ApplicationInstallError.malformedTransaction }
    let resolvedDestination = try ApplicationDestinationPolicy().resolve(currentAppURL: transaction.destinationURL)
    let expectedDestination = transaction.destinationURL.standardizedFileURL.resolvingSymlinksInPath()
    guard resolvedDestination == expectedDestination else { throw ApplicationInstallError.malformedTransaction }
    var verificationCalls = 0
    let forcedFailure = testMode ? environment["DFUUTILITY_INSTALLER_TEST_FAILURE"] : nil
    let verifierOverride: ApplicationInstaller.Verifier? = if forcedFailure == "verification" || forcedFailure == "rollback" {
        { url, _, _ in
            verificationCalls += 1
            guard verificationCalls == 1 else {
                if forcedFailure == "rollback" {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: transaction.destinationURL.deletingLastPathComponent().path)
                }
                return false
            }
            return FileManager.default.fileExists(atPath: url.path)
        }
    } else { nil }
    try ApplicationInstaller().install(transaction: transaction, verifierOverride: verifierOverride, store: store)
    let result = "status=success\nversion=\(transaction.expectedVersion.description)\nbuild=\(transaction.expectedBuild)\n"
    try result.write(to: transaction.resultURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transaction.resultURL.path)
    let process = Process()
    if testMode, let launcher = environment["DFUUTILITY_INSTALLER_LAUNCHER"] {
        process.executableURL = URL(fileURLWithPath: launcher)
        process.arguments = [transaction.destinationURL.path]
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", transaction.destinationURL.path]
    }
    try process.run(); process.waitUntilExit()
    if process.terminationStatus != 0 { throw UpdateServiceError.launchFailed("The installed application could not be launched.") }
} catch {
    if let transaction = try? store.read() {
        let message = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
        let result = "status=failure\nerror=\(message)\n"
        try? result.write(to: transaction.resultURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transaction.resultURL.path)
    }
    exit(1)
}
