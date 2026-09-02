import Foundation

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

public enum UpdateServiceError: LocalizedError, Equatable {
    case sourceNotRecorded, sourceMissing, updaterMissing, malformedResponse, checkFailed(String), launchFailed(String)
    public var errorDescription: String? {
        switch self {
        case .sourceNotRecorded: "Automatic updates are unavailable because DFUUtility's source folder has not been recorded. Reinstall DFUUtility from GitHub to restore automatic updates."
        case .sourceMissing: "Automatic updates are unavailable because DFUUtility's source folder could not be found. Reinstall DFUUtility from GitHub to restore automatic updates."
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
    @Published public private(set) var state: AppUpdateState = .idle
    @Published public private(set) var launchSucceeded = false
    @Published public private(set) var pendingResult: AppUpdateResult?
    public let sourceRecordURL: URL
    public let resultURL: URL
    public let logURL: URL
    public let isSimulation: Bool
    private let service: any UpdateServicing
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let appURL: URL
    private let pid: Int32
    private static let lastCheckKey = "DFUUtilityLastSuccessfulUpdateCheck"

    public init(service: any UpdateServicing, sourceRecordURL: URL, resultURL: URL, logURL: URL, defaults: UserDefaults = .standard, appURL: URL = Bundle.main.bundleURL, pid: Int32 = ProcessInfo.processInfo.processIdentifier, isSimulation: Bool = false, now: @escaping @Sendable () -> Date = Date.init) {
        self.service = service; self.sourceRecordURL = sourceRecordURL; self.resultURL = resultURL; self.logURL = logURL
        self.defaults = defaults; self.appURL = appURL; self.pid = pid; self.isSimulation = isSimulation; self.now = now
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
        state = .checking
        do {
            let source = try recordedSource()
            state = try await service.check(sourceRoot: source)
            defaults.set(now(), forKey: Self.lastCheckKey)
        } catch {
            state = manual ? .failed(error.localizedDescription) : .idle
        }
    }

    public func launchUpdate() throws {
        let source = try recordedSource(); state = .preparing
        try service.launch(sourceRoot: source, oldPID: pid, appURL: appURL, resultURL: resultURL)
        launchSucceeded = true
    }

    public func completeSimulation() {
        #if DEBUG
        guard isSimulation, launchSucceeded else { return }
        pendingResult = .init(outcome: .success, oldVersion: SimulatedUpdateService.availability.currentVersion, newVersion: SimulatedUpdateService.availability.latestVersion, isSimulation: true)
        state = .current
        #endif
    }

    public func consumeResult() {
        guard let data = try? String(contentsOf: resultURL, encoding: .utf8) else { return }
        let values = Dictionary(uniqueKeysWithValues: data.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            guard let index = line.firstIndex(of: "=") else { return nil }; return (String(line[..<index]), String(line[line.index(after: index)...]))
        })
        pendingResult = .init(outcome: values["status"] == "success" ? .success : .failure, oldVersion: values["old_version"], newVersion: values["new_version"])
        try? FileManager.default.removeItem(at: resultURL)
    }

    public func clearResult() { pendingResult = nil }

    private func recordedSource() throws -> URL {
        guard let value = try? String(contentsOf: sourceRecordURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { throw UpdateServiceError.sourceNotRecorded }
        let url = URL(fileURLWithPath: value, isDirectory: true)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { throw UpdateServiceError.sourceMissing }
        return url
    }
}
