import DFUAppSupport
import Foundation
import Darwin
import AppKit

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
func log(_ message: String) {
    let url = support.appendingPathComponent("../Logs/DFUUtility/update.log").standardizedFileURL
    do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }; let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }; try handle.seekToEnd(); try handle.write(contentsOf: Data(("[" + ISO8601DateFormatter().string(from: Date()) + "] " + message + "\n").utf8)) } catch { }
}
func processExists(_ pid: Int32) -> Bool { guard pid > 0 else { return false }; let result = kill(pid, 0); return result == 0 || errno == EPERM }
func waitForExit(_ pid: Int32, timeout: TimeInterval = 30) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while processExists(pid) && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    return !processExists(pid)
}
func waitForNewApplication(at bundleURL: URL, excluding pid: Int32?, timeout: TimeInterval = 30) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: ApplicationDestinationPolicy.bundleIdentifier)
        if apps.contains(where: { BinaryHandoffPolicy.accepts(observedPID: $0.processIdentifier, originatingPID: pid, observedBundleURL: $0.bundleURL, expectedBundleURL: bundleURL) }) { return true }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return false
}
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
    if let pid = transaction.originatingPID, processExists(pid) { log("handoff termination wait started for originating PID \(pid)"); let timeout = testMode ? (Double(environment["DFUUTILITY_INSTALLER_TEST_TIMEOUT"] ?? "30") ?? 30) : 30; guard waitForExit(pid, timeout: timeout) else { log("termination timeout for originating PID \(pid)"); throw UpdateServiceError.launchFailed("The previous DFUUtility process did not terminate before the update timeout.") }; log("originating PID \(pid) exited") }
    log("replacement started")
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
    log("replacement completed; relaunch requested")
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
    if !testMode, !waitForNewApplication(at: transaction.destinationURL, excluding: transaction.originatingPID) { log("relaunch timeout"); throw UpdateServiceError.launchFailed("The updated application did not relaunch within the verification timeout.") }
    if !testMode { log("new application process observed") }
    let result = "status=success\nversion=\(transaction.expectedVersion.description)\nbuild=\(transaction.expectedBuild)\n"
    try result.write(to: transaction.resultURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transaction.resultURL.path)
    log("transaction completed")
} catch {
    if let transaction = try? store.read() {
        let message = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
        let result = "status=failure\nerror=\(message)\n"
        try? result.write(to: transaction.resultURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transaction.resultURL.path)
    }
    exit(1)
}
