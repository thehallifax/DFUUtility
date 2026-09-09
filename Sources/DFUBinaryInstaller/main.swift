import DFUAppSupport
import Foundation
import Darwin

let arguments = CommandLine.arguments
guard arguments.count == 2 else { exit(64) }
let descriptor = URL(fileURLWithPath: arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DFUUtility", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
let staging = support.appendingPathComponent("Updates", isDirectory: true)
guard descriptor.path.hasPrefix(support.path + "/") else { exit(65) }
let store = BinaryInstallTransactionStore(url: descriptor)
do {
    let transaction = try store.read()
    guard transaction.destinationURL.pathExtension.lowercased() == "app",
          transaction.artifactURL.pathExtension.lowercased() == "app",
          transaction.resultURL.path.hasPrefix(support.path + "/"),
          transaction.artifactURL.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(staging.path + "/") else { throw ApplicationInstallError.malformedTransaction }
    guard try ApplicationDestinationPolicy().resolve(currentAppURL: transaction.destinationURL) == transaction.destinationURL.standardizedFileURL.resolvingSymlinksInPath() else { throw ApplicationInstallError.malformedTransaction }
    try ApplicationInstaller().install(transaction: transaction, store: store)
    let result = "status=success\nversion=\(transaction.expectedVersion.description)\nbuild=\(transaction.expectedBuild)\n"
    try result.write(to: transaction.resultURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transaction.resultURL.path)
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open"); process.arguments = ["-a", transaction.destinationURL.path]; try process.run(); process.waitUntilExit()
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
