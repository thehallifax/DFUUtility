import Foundation
import DFUCore

public enum ApplicationInstallPhase: String, Codable, Sendable {
    case preflight, staging, backup, replacement, inPlaceVerification, rollback, completed
}

public enum ApplicationInstallError: LocalizedError, Equatable, Sendable {
    case invalidDestination(String)
    case missingArtifact
    case artifactIdentityMismatch
    case destinationIdentityMismatch
    case destinationMissing
    case sourceAndDestinationMatch
    case unsupportedPath(String)
    case permissionDenied(String)
    case replacementFailed(String)
    case verificationFailed(String)
    case rollbackFailed(String)
    case conflictingTransaction
    case malformedTransaction

    public var errorDescription: String? {
        switch self {
        case .invalidDestination(let value): "Invalid application destination: \(value)"
        case .missingArtifact: "The verified update application is no longer available."
        case .artifactIdentityMismatch: "The staged update no longer matches its verified version or build."
        case .destinationIdentityMismatch: "The destination is not DFUUtility."
        case .destinationMissing: "The existing DFUUtility application could not be found."
        case .sourceAndDestinationMatch: "The staged update and installed application are the same path."
        case .unsupportedPath(let value): "Unsupported application path: \(value)"
        case .permissionDenied(let value): "The application destination is not writable: \(value)"
        case .replacementFailed(let value): "Application replacement failed: \(value)"
        case .verificationFailed(let value): "The replacement failed in-place verification: \(value)"
        case .rollbackFailed(let value): "Critical recovery failure: rollback failed: \(value)"
        case .conflictingTransaction: "Another binary update transaction is already in progress."
        case .malformedTransaction: "The binary update transaction is malformed or unsafe."
        }
    }
}

public struct BinaryInstallTransaction: Codable, Equatable, Sendable {
    public let id: UUID
    public let expectedVersion: SemanticVersion
    public let expectedBuild: String
    public let artifactURL: URL
    public let destinationURL: URL
    public let backupURL: URL
    public let resultURL: URL
    public let originatingPID: Int32?
    public var phase: ApplicationInstallPhase
    public let createdAt: Date
    public init(id: UUID = UUID(), expectedVersion: SemanticVersion, expectedBuild: String, artifactURL: URL, destinationURL: URL, backupURL: URL, resultURL: URL, originatingPID: Int32? = nil, phase: ApplicationInstallPhase = .preflight, createdAt: Date = Date()) {
        self.id = id; self.expectedVersion = expectedVersion; self.expectedBuild = expectedBuild; self.artifactURL = artifactURL; self.destinationURL = destinationURL; self.backupURL = backupURL; self.resultURL = resultURL; self.originatingPID = originatingPID; self.phase = phase; self.createdAt = createdAt
    }
}

public struct BinaryInstallTransactionStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func write(_ transaction: BinaryInstallTransaction) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(transaction)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func read() throws -> BinaryInstallTransaction {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(BinaryInstallTransaction.self, from: data) else { throw ApplicationInstallError.malformedTransaction }
        return value
    }
    public func remove() { try? FileManager.default.removeItem(at: url) }
}

public struct ApplicationDestinationPolicy: Sendable {
    public static let bundleIdentifier = "org.dfuutility.app"
    public init() {}
    public func resolve(currentAppURL: URL) throws -> URL {
        let destination = currentAppURL.standardizedFileURL.resolvingSymlinksInPath()
        guard destination.pathExtension.lowercased() == "app" else { throw ApplicationInstallError.unsupportedPath(destination.path) }
        guard FileManager.default.fileExists(atPath: destination.path) else { throw ApplicationInstallError.destinationMissing }
        guard bundleIdentifier(at: destination) == Self.bundleIdentifier else { throw ApplicationInstallError.destinationIdentityMismatch }
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else { throw ApplicationInstallError.permissionDenied(destination.deletingLastPathComponent().path) }
        return destination
    }
    public func bundleIdentifier(at url: URL) -> String? {
        (NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String) ?? (Bundle(url: url)?.infoDictionary?["CFBundleIdentifier"] as? String)
    }
}

public struct ApplicationInstaller {
    public typealias Verifier = (URL, SemanticVersion, String) -> Bool
    private let fileManager: FileManager
    private let verifier: Verifier
    public init(fileManager: FileManager = .default, verifier: Verifier? = nil) {
        self.fileManager = fileManager
        self.verifier = verifier ?? { url, version, build in
            guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == ApplicationDestinationPolicy.bundleIdentifier,
                  info["CFBundleShortVersionString"] as? String == version.description,
                  info["CFBundleVersion"] as? String == build else { return false }
            let required = ["Contents/MacOS/DFUUtility", "Contents/Library/LaunchServices/DFUPrivilegedHelper", "Contents/Resources/macvdmtool", "Contents/Resources/DFUUtility-LICENSE.txt"]
            guard required.allSatisfy({ fileManager.fileExists(atPath: url.appendingPathComponent($0).path) }) else { return false }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); process.arguments = ["--verify", "--deep", "--strict", url.path]
            try? process.run(); process.waitUntilExit(); return process.terminationStatus == 0
        }
    }

    public func preflight(artifact: VerifiedUpdateArtifact, destination: URL, stagingRoot: URL, operationAllowed: Bool, existingTransaction: BinaryInstallTransaction? = nil) throws -> URL {
        guard operationAllowed else { throw ApplicationInstallError.permissionDenied("an active DFUUtility operation blocks updating") }
        let policy = ApplicationDestinationPolicy(); let resolved = try policy.resolve(currentAppURL: destination)
        let source = artifact.appURL.standardizedFileURL.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: source.path), verifier(source, artifact.version, artifact.build) else { throw ApplicationInstallError.artifactIdentityMismatch }
        guard source != resolved else { throw ApplicationInstallError.sourceAndDestinationMatch }
        let root = stagingRoot.standardizedFileURL.resolvingSymlinksInPath().path
        guard source.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { throw ApplicationInstallError.unsupportedPath("artifact is outside the controlled staging area") }
        if existingTransaction != nil { throw ApplicationInstallError.conflictingTransaction }
        return resolved
    }

    public func install(transaction: BinaryInstallTransaction, verifierOverride: Verifier? = nil, store: BinaryInstallTransactionStore? = nil) throws {
        var tx = transaction
        func persist() { try? store?.write(tx) }
        let verify = verifierOverride ?? verifier
        guard fileManager.fileExists(atPath: tx.artifactURL.path), verify(tx.artifactURL, tx.expectedVersion, tx.expectedBuild) else { throw ApplicationInstallError.artifactIdentityMismatch }
        guard fileManager.fileExists(atPath: tx.destinationURL.path), ApplicationDestinationPolicy().bundleIdentifier(at: tx.destinationURL) == ApplicationDestinationPolicy.bundleIdentifier else { throw ApplicationInstallError.destinationIdentityMismatch }
        guard !fileManager.fileExists(atPath: tx.backupURL.path) else { throw ApplicationInstallError.conflictingTransaction }
        do {
            tx.phase = .backup; persist(); try fileManager.moveItem(at: tx.destinationURL, to: tx.backupURL)
            tx.phase = .replacement; persist(); try fileManager.moveItem(at: tx.artifactURL, to: tx.destinationURL)
            tx.phase = .inPlaceVerification; persist()
            guard verify(tx.destinationURL, tx.expectedVersion, tx.expectedBuild) else { throw ApplicationInstallError.verificationFailed("bundle identity, version, build, or required resource check failed") }
            tx.phase = .completed; persist()
            try? fileManager.removeItem(at: tx.backupURL)
        } catch {
            tx.phase = .rollback; persist()
            do {
                if fileManager.fileExists(atPath: tx.destinationURL.path) { try fileManager.removeItem(at: tx.destinationURL) }
                if fileManager.fileExists(atPath: tx.backupURL.path) { try fileManager.moveItem(at: tx.backupURL, to: tx.destinationURL) }
                guard ApplicationDestinationPolicy().bundleIdentifier(at: tx.destinationURL) == ApplicationDestinationPolicy.bundleIdentifier else { throw ApplicationInstallError.rollbackFailed("restored bundle identity could not be verified") }
            } catch let rollbackError { throw ApplicationInstallError.rollbackFailed(rollbackError.localizedDescription) }
            if let value = error as? ApplicationInstallError { throw value }
            throw ApplicationInstallError.replacementFailed(error.localizedDescription)
        }
    }
}

public protocol BinaryInstallHandingOff: Sendable {
    func launch(transactionURL: URL) throws
}

public enum BinaryHandoffPolicy {
    public static func accepts(observedPID: Int32, originatingPID: Int32?, observedBundleURL: URL?, expectedBundleURL: URL) -> Bool {
        guard observedPID != originatingPID, let observedBundleURL else { return false }
        return observedBundleURL.standardizedFileURL == expectedBundleURL.standardizedFileURL
    }
}

public struct ExternalBinaryInstallHandoff: BinaryInstallHandingOff {
    public let installerURL: URL
    public init(installerURL: URL) { self.installerURL = installerURL }
    public func launch(transactionURL: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: installerURL.path) else { throw ApplicationInstallError.unsupportedPath("bundled installer is unavailable") }
        let process = Process(); process.executableURL = installerURL; process.arguments = [transactionURL.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ApplicationInstallError.replacementFailed(error.localizedDescription) }
    }
}
