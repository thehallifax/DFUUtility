import Foundation
import DFUCore

public enum DevelopmentUpdateAcceptance {
    public static func isEnabled(arguments: [String], bundleURL: URL) -> Bool {
        arguments.contains("--update-test") && bundleURL.pathExtension.lowercased() != "app"
    }
}

public struct UpdateAvailability: Equatable, Sendable {
    public let currentVersion: String
    public let latestVersion: String
    public let currentCommit: String
    public let latestCommit: String
    public init(currentVersion: String, latestVersion: String, currentCommit: String, latestCommit: String) {
        self.currentVersion = currentVersion; self.latestVersion = latestVersion
        self.currentCommit = currentCommit; self.latestCommit = latestCommit
    }
    public var versionChanged: Bool { currentVersion != latestVersion }
}

public enum AppUpdateState: Equatable, Sendable {
    case idle, checking, current
    case available(UpdateAvailability)
    case binaryAvailable(ValidatedBinaryRelease)
    case downloading
    case verifying
    case verifiedReady(VerifiedUpdateArtifact)
    case blockedByOperation(String)
    case unavailable(String)
    case preparing
    case failed(String)
}

public struct UpdateOperationSnapshot: Equatable, Sendable {
    public var restoreOrReconnect = false
    public var download = false
    public var validation = false
    public var guidedDFU = false
    public var batch = false
    public init(restoreOrReconnect: Bool = false, download: Bool = false, validation: Bool = false, guidedDFU: Bool = false, batch: Bool = false) {
        self.restoreOrReconnect = restoreOrReconnect; self.download = download; self.validation = validation
        self.guidedDFU = guidedDFU; self.batch = batch
    }
    public var permitsUpdate: Bool { !restoreOrReconnect && !download && !validation && !guidedDFU && !batch }
}

public struct AppUpdateResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable { case success, failure }
    public let outcome: Outcome
    public let oldVersion: String?
    public let newVersion: String?
    public let isSimulation: Bool
    public init(outcome: Outcome, oldVersion: String?, newVersion: String?, isSimulation: Bool = false) {
        self.outcome = outcome; self.oldVersion = oldVersion; self.newVersion = newVersion; self.isSimulation = isSimulation
    }
}

public protocol UpdateServicing: Sendable {
    func check(sourceRoot: URL) async throws -> AppUpdateState
    func launch(sourceRoot: URL, oldPID: Int32, appURL: URL, resultURL: URL) throws
}

public enum InstallationUpdateMode: Equatable, Sendable {
    case source(URL)
    case binary
    case invalidSourceRecord(String)
}

public enum ApplicationInstallationKind: String, Sendable {
    case distribution
    case source
}

@MainActor public protocol ApplicationTerminationRequesting: AnyObject {
    func requestTermination()
}

@MainActor public final class NoOpApplicationTerminator: ApplicationTerminationRequesting {
    public init() {}
    public func requestTermination() {}
}

public enum UpdateServiceError: LocalizedError, Equatable {
    case sourceNotRecorded, sourceMissing, sourceInvalid(String), updaterMissing, malformedResponse, checkFailed(String), launchFailed(String)
    public var errorDescription: String? {
        switch self {
        case .sourceNotRecorded: "Automatic updates are unavailable because DFUUtility's source folder has not been recorded. Reinstall DFUUtility from GitHub to restore automatic updates."
        case .sourceMissing: "Automatic updates are unavailable because DFUUtility's source folder could not be found. Reinstall DFUUtility from GitHub to restore automatic updates."
        case .sourceInvalid(let detail): detail
        case .updaterMissing: "The recorded source folder does not contain the DFUUtility updater."
        case .malformedResponse: "The updater returned an unreadable response."
        case .checkFailed(let message): message
        case .launchFailed(let message): "The external updater could not be started. \(message)"
        }
    }
}

public struct ShellUpdateService: UpdateServicing {
    public let launcherURL: URL
    public init(launcherURL: URL) { self.launcherURL = launcherURL }

    public func check(sourceRoot: URL) async throws -> AppUpdateState {
        let updater = sourceRoot.appendingPathComponent("scripts/update.sh")
        guard FileManager.default.isExecutableFile(atPath: updater.path) else { throw UpdateServiceError.updaterMissing }
        return try await Task.detached {
            let process = Process(), pipe = Pipe()
            process.executableURL = updater; process.arguments = ["--check", "--machine-readable"]
            process.currentDirectoryURL = sourceRoot; process.standardOutput = pipe; process.standardError = pipe
            try process.run(); process.waitUntilExit()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let fields = Self.fields(text)
            guard let status = fields["status"] else { throw UpdateServiceError.malformedResponse }
            if status == "current" { return .current }
            if status == "update_available",
               let currentVersion = fields["current_version"], let latestVersion = fields["latest_version"],
               let currentCommit = fields["current_commit"], let latestCommit = fields["latest_commit"] {
                return .available(.init(currentVersion: currentVersion, latestVersion: latestVersion, currentCommit: currentCommit, latestCommit: latestCommit))
            }
            if status == "fetch_failed" { throw UpdateServiceError.checkFailed(fields["message"] ?? "Could not contact the DFUUtility Git repository.") }
            if status == "invalid_source" { throw UpdateServiceError.sourceInvalid(fields["message"] ?? "Invalid source checkout") }
            return .unavailable(fields["message"] ?? "The source updater reported: \(status.replacingOccurrences(of: "_", with: " ")).")
        }.value
    }

    public func launch(sourceRoot: URL, oldPID: Int32, appURL: URL, resultURL: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: launcherURL.path) else { throw UpdateServiceError.updaterMissing }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [launcherURL.path, sourceRoot.path, String(oldPID), appURL.path, resultURL.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UpdateServiceError.launchFailed(error.localizedDescription) }
    }

    private static func fields(_ text: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let separator = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<separator]), String(line[line.index(after: separator)...]))
        })
    }
}

#if DEBUG
public struct SimulatedUpdateService: UpdateServicing {
    public static let availability = UpdateAvailability(currentVersion: "0.6.1", latestVersion: "0.7.0-test", currentCommit: "update-test-current", latestCommit: "update-test-latest")
    public init() {}
    public func check(sourceRoot: URL) async throws -> AppUpdateState { .available(Self.availability) }
    public func launch(sourceRoot: URL, oldPID: Int32, appURL: URL, resultURL: URL) throws {}
}
#endif

@MainActor
public final class UpdateCoordinator: ObservableObject {
    public static let sourceGuidance = "DFUUtility was installed without a usable source checkout, or the original checkout has moved. Reinstall DFUUtility from the project repository to enable Community updates."
    @Published public private(set) var sourceCheckoutUnavailable = false
    @Published public private(set) var state: AppUpdateState = .idle
    @Published public private(set) var launchSucceeded = false
    @Published public private(set) var pendingResult: AppUpdateResult?
    @Published public private(set) var verifiedBinaryArtifact: VerifiedUpdateArtifact?
    public let sourceRecordURL: URL
    public let resultURL: URL
    public let binaryResultURL: URL
    public let logURL: URL
    public let isSimulation: Bool
    private let service: any UpdateServicing
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let appURL: URL
    private let pid: Int32
    private let binaryClient: GitHubReleaseClient
    private let binaryValidator: ReleaseMetadataValidator
    private let binaryDownloader: BinaryUpdateDownloader
    private let binaryVerifier: BinaryArtifactVerifier
    private let binaryStagingURL: URL
    private let runningVersion: SemanticVersion?
    private let runningBuild: String?
    private let binaryHandoff: any BinaryInstallHandingOff
    private let binaryTransactionURL: URL
    private var binaryDownloadTask: Task<Void, Never>?
    private static let lastCheckKey = "DFUUtilityLastSuccessfulUpdateCheck"

    public init(service: any UpdateServicing, sourceRecordURL: URL, resultURL: URL, logURL: URL, defaults: UserDefaults = .standard, appURL: URL = Bundle.main.bundleURL, pid: Int32 = ProcessInfo.processInfo.processIdentifier, isSimulation: Bool = false, now: @escaping @Sendable () -> Date = Date.init, binaryClient: GitHubReleaseClient = GitHubReleaseClient(), binaryDownloader: BinaryUpdateDownloader = BinaryUpdateDownloader(), binaryVerifier: BinaryArtifactVerifier = BinaryArtifactVerifier(), binaryStagingURL: URL? = nil, runningVersion: SemanticVersion? = nil, binaryHandoff: (any BinaryInstallHandingOff)? = nil, binaryTransactionURL: URL? = nil, binaryResultURL: URL? = nil) {
        self.service = service; self.sourceRecordURL = sourceRecordURL; self.resultURL = resultURL; self.logURL = logURL
        self.defaults = defaults; self.appURL = appURL; self.pid = pid; self.isSimulation = isSimulation; self.now = now
        self.binaryClient = binaryClient; self.binaryValidator = ReleaseMetadataValidator(); self.binaryDownloader = binaryDownloader; self.binaryVerifier = binaryVerifier
        self.binaryStagingURL = binaryStagingURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DFUUtility/Updates", isDirectory: true)
        self.runningVersion = runningVersion ?? Bundle(url: appURL)?.infoDictionary.flatMap { SemanticVersion(string: $0["CFBundleShortVersionString"] as? String) } ?? Bundle.main.infoDictionary.flatMap { SemanticVersion(string: $0["CFBundleShortVersionString"] as? String) }
        self.runningBuild = Bundle(url: appURL)?.infoDictionary?["CFBundleVersion"] as? String ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DFUUtility", isDirectory: true)
        self.binaryTransactionURL = binaryTransactionURL ?? support.appendingPathComponent("binary-update-transaction.json")
        self.binaryResultURL = binaryResultURL ?? support.appendingPathComponent("binary-update-result")
        self.binaryHandoff = binaryHandoff ?? ExternalBinaryInstallHandoff(installerURL: Bundle(url: appURL)?.url(forResource: "DFUBinaryInstaller", withExtension: nil) ?? appURL.appendingPathComponent("Contents/Resources/DFUBinaryInstaller"))
    }

    public convenience init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support/DFUUtility")
        let launcher = Bundle.main.url(forResource: "update-and-relaunch", withExtension: "sh") ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/update-and-relaunch.sh")
        self.init(service: ShellUpdateService(launcherURL: launcher), sourceRecordURL: support.appendingPathComponent("update-source"), resultURL: support.appendingPathComponent("update-result"), logURL: home.appendingPathComponent("Library/Logs/DFUUtility/update.log"))
    }

    #if DEBUG
    public static func simulated() -> UpdateCoordinator {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DFUUtility-Update-Test", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let record = root.appendingPathComponent("update-source")
        try? root.path.write(to: record, atomically: true, encoding: .utf8)
        let defaults = UserDefaults(suiteName: "org.dfuutility.update-test.\(UUID().uuidString)")!
        return UpdateCoordinator(service: SimulatedUpdateService(), sourceRecordURL: record, resultURL: root.appendingPathComponent("update-result"), logURL: root.appendingPathComponent("update.log"), defaults: defaults, appURL: root.appendingPathComponent("DFUUtility.app"), pid: 999_999, isSimulation: true)
    }
    #endif

    public func automaticCheckIfDue(disabled: Bool) async {
        guard !disabled else { return }
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date, now().timeIntervalSince(last) < 86_400 { return }
        await check(manual: false)
    }

    public func check(manual: Bool) async {
        sourceCheckoutUnavailable = false
        verifiedBinaryArtifact = nil
        state = .checking
        appendBinaryLog("binary update check started")
        do {
            switch installationMode {
            case .source(let source): state = try await service.check(sourceRoot: source)
            case .binary:
                guard let runningVersion else { throw BinaryUpdateError.invalidVersionTag("installed version unavailable") }
                let releases = try await binaryClient.releases()
                if let candidate = binaryValidator.selectLatest(from: releases, installed: runningVersion) { state = .binaryAvailable(candidate); appendBinaryLog("binary update available: " + candidate.version.description) }
                else { state = .current; appendBinaryLog("binary update check completed: current") }
            case .invalidSourceRecord(let detail): throw UpdateServiceError.sourceInvalid(detail)
            }
            defaults.set(now(), forKey: Self.lastCheckKey)
        } catch {
            switch error {
            case UpdateServiceError.sourceMissing, UpdateServiceError.sourceInvalid, UpdateServiceError.updaterMissing:
                sourceCheckoutUnavailable = true
            default: break
            }
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let detail = "Update check failed: \(error.localizedDescription)\n"
            if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(detail.utf8))
            }
            state = manual ? .failed(sourceCheckoutUnavailable ? Self.sourceGuidance : error.localizedDescription) : .idle
            appendBinaryLog("binary update check failed: " + error.localizedDescription)
        }
    }

    public var installationMode: InstallationUpdateMode {
        // A packaged distribution carries positive provenance in its bundle
        // metadata. This prevents a historical machine-global source record
        // from hijacking a later manually copied release. Unmarked bundles
        // retain the legacy behavior so older source installs do not silently
        // switch update mechanisms.
        if let kind = Self.installationKind(at: appURL) {
            if kind == .distribution { return .binary }
            return sourceInstallationMode()
        }
        return legacyInstallationMode()
    }

    public static func installationKind(at appURL: URL) -> ApplicationInstallationKind? {
        guard appURL.pathExtension.lowercased() == "app" else { return nil }
        guard let value = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))?["DFUUtilityInstallationKind"] as? String else { return nil }
        return ApplicationInstallationKind(rawValue: value)
    }

    private func sourceInstallationMode() -> InstallationUpdateMode {
        // A marked source install must retain the source updater, but still
        // reports missing/invalid registration rather than falling back to a
        // binary update.
        return recordedSourceMode(packagedMissingRecordIsBinary: false)
    }

    private func legacyInstallationMode() -> InstallationUpdateMode {
        // Before provenance metadata existed, a packaged `.app` without a
        // source record was a normal binary installation. Existing records
        // remain source-mode to preserve historical developer installations.
        return recordedSourceMode(packagedMissingRecordIsBinary: true)
    }

    private func recordedSourceMode(packagedMissingRecordIsBinary: Bool) -> InstallationUpdateMode {
        guard FileManager.default.fileExists(atPath: sourceRecordURL.path) else {
            return packagedMissingRecordIsBinary && appURL.pathExtension.lowercased() == "app" ? .binary : .invalidSourceRecord("No source checkout has been recorded.")
        }
        guard let value = try? String(contentsOf: sourceRecordURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return .invalidSourceRecord("The recorded source checkout path is empty.") }
        let url = URL(fileURLWithPath: value, isDirectory: true)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { return .invalidSourceRecord("The recorded source checkout no longer exists.") }
        let git = url.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: git.path) else { return .invalidSourceRecord("The recorded source path is not a Git worktree.") }
        return .source(url)
    }

    public func downloadBinaryUpdate() async {
        guard case .binaryAvailable(let release) = state else { return }
        state = .downloading
        appendBinaryLog("binary update download started")
        do {
            do { try FileManager.default.createDirectory(at: binaryStagingURL, withIntermediateDirectories: true) }
            catch { throw BinaryUpdateError.stagingFailure(error.localizedDescription) }
            // Candidate directories are identity-scoped. Remove only prior
            // updater-owned candidates so an older verified artifact cannot be
            // accidentally reused for a later release.
            if let entries = try? FileManager.default.contentsOfDirectory(at: binaryStagingURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for entry in entries { try? FileManager.default.removeItem(at: entry) }
            }
            let candidateRoot = binaryStagingURL.appendingPathComponent(release.version.description, isDirectory: true)
            do { try FileManager.default.createDirectory(at: candidateRoot, withIntermediateDirectories: true) }
            catch { throw BinaryUpdateError.stagingFailure(error.localizedDescription) }
            let downloaded = try await binaryDownloader.download(release, in: candidateRoot)
            appendBinaryLog("binary update download completed: " + String(downloaded.byteCount) + " bytes")
            state = .verifying
            let extractRoot = candidateRoot.appendingPathComponent("extracted", isDirectory: true)
            let artifact = try binaryVerifier.verify(downloaded, release: release, stagingDirectory: extractRoot)
            let marker = candidateRoot.appendingPathComponent("verified.json")
            let markerData = try JSONEncoder().encode(BinaryVerifiedMarker(version: artifact.version.description, digest: release.digest, build: artifact.build))
            do { try markerData.write(to: marker, options: .atomic) }
            catch { throw BinaryUpdateError.stagingFailure(error.localizedDescription) }
            verifiedBinaryArtifact = artifact
            state = .verifiedReady(artifact)
            appendBinaryLog("binary update archive and bundle verification completed")
        } catch is CancellationError {
            state = .failed(BinaryUpdateError.cancelled.localizedDescription)
        } catch {
            verifiedBinaryArtifact = nil
            appendBinaryLog("binary update failed: " + error.localizedDescription)
            state = .failed(error.localizedDescription)
        }
    }

    private func appendBinaryLog(_ message: String) {
        guard !isSimulation else { return }
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let handle = try FileHandle(forWritingTo: logURL); defer { try? handle.close() }
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[" + timestamp + "] " + message + "\n"
            try handle.seekToEnd(); try handle.write(contentsOf: Data(line.utf8))
        } catch { }
    }

    public func startBinaryDownload() {
        guard binaryDownloadTask == nil else { return }
        binaryDownloadTask = Task { [weak self] in
            guard let self else { return }
            await self.downloadBinaryUpdate()
            self.binaryDownloadTask = nil
        }
    }

    public func cancelBinaryDownload() {
        binaryDownloadTask?.cancel()
        binaryDownloadTask = nil
        if case .downloading = state { state = .failed("Update download cancelled.") }
    }

    public func installVerifiedBinaryUpdate(operationAllowed: Bool) throws {
        guard case .verifiedReady(let artifact) = state else { throw ApplicationInstallError.missingArtifact }
        let destination = try ApplicationDestinationPolicy().resolve(currentAppURL: appURL)
        _ = try ApplicationInstaller().preflight(artifact: artifact, destination: destination, stagingRoot: binaryStagingURL, operationAllowed: operationAllowed)
        let backup = Self.backupURL(for: destination)
        let transaction = BinaryInstallTransaction(expectedVersion: artifact.version, expectedBuild: artifact.build, artifactURL: artifact.appURL, destinationURL: destination, backupURL: backup, resultURL: binaryResultURL, originatingPID: pid)
        try BinaryInstallTransactionStore(url: binaryTransactionURL).write(transaction)
        state = .preparing
        do { try binaryHandoff.launch(transactionURL: binaryTransactionURL) }
        catch { state = .verifiedReady(artifact); throw error }
    }

    public static func backupURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".DFUUtility-backup-" + UUID().uuidString, isDirectory: true)
    }

    public func launchUpdate() throws {
        let source = try recordedSource(), previousState = state
        state = .preparing
        do {
            try service.launch(sourceRoot: source, oldPID: pid, appURL: appURL, resultURL: resultURL)
            launchSucceeded = true
        } catch {
            state = previousState
            throw error
        }
    }

    public func completeSimulation() {
        #if DEBUG
        guard isSimulation, launchSucceeded else { return }
        pendingResult = .init(outcome: .success, oldVersion: SimulatedUpdateService.availability.currentVersion, newVersion: SimulatedUpdateService.availability.latestVersion, isSimulation: true)
        state = .current
        #endif
    }

    public func consumeResult() {
        if let data = try? String(contentsOf: binaryResultURL, encoding: .utf8) {
            let values = Dictionary(uniqueKeysWithValues: data.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
                guard let index = line.firstIndex(of: "=") else { return nil }; return (String(line[..<index]), String(line[line.index(after: index)...]))
            })
            let launchVerified = values["status"] == "success" && values["version"] == runningVersion?.description && values["build"] == runningBuild
            if launchVerified {
                pendingResult = .init(outcome: .success, oldVersion: runningVersion?.description, newVersion: values["version"])
            } else {
                pendingResult = .init(outcome: .failure, oldVersion: runningVersion?.description, newVersion: values["version"])
            }
            try? FileManager.default.removeItem(at: binaryResultURL)
            try? FileManager.default.removeItem(at: binaryTransactionURL)
            return
        }
        guard let data = try? String(contentsOf: resultURL, encoding: .utf8) else { return }
        let values = Dictionary(uniqueKeysWithValues: data.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            guard let index = line.firstIndex(of: "=") else { return nil }; return (String(line[..<index]), String(line[line.index(after: index)...]))
        })
        pendingResult = .init(outcome: values["status"] == "success" ? .success : .failure, oldVersion: values["old_version"], newVersion: values["new_version"])
        try? FileManager.default.removeItem(at: resultURL)
    }

    public func clearResult() { pendingResult = nil }

    public var shareableSourceHealth: String {
        if case .binary = installationMode { return "Binary installation; Git source not required" }
        do {
            _ = try recordedSource()
            return "Recorded source available"
        } catch UpdateServiceError.sourceNotRecorded {
            return "Source not recorded"
        } catch UpdateServiceError.sourceMissing {
            return "Recorded source unavailable"
        } catch {
            return "Source status unavailable"
        }
    }

    private func recordedSource() throws -> URL {
        guard let value = try? String(contentsOf: sourceRecordURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { throw UpdateServiceError.sourceNotRecorded }
        let url = URL(fileURLWithPath: value, isDirectory: true)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { throw UpdateServiceError.sourceMissing }
        return url
    }
}

private struct BinaryVerifiedMarker: Codable, Sendable {
    let version: String
    let digest: String
    let build: String
}

private extension SemanticVersion {
    init?(string: String?) {
        guard let string else { return nil }
        self.init(tag: "v\(string)")
    }
}
