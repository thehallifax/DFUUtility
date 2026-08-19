import Foundation
import Security
import ServiceManagement
import OSLog

public enum PrivilegedDFUConstants {
    public static let machService = "org.dfuutility.privileged-helper"
    public static let daemonPlist = "org.dfuutility.privileged-helper.plist"
    public static let authorizationRight = "org.dfuutility.enter-dfu"
    public static let appIdentifier = "org.dfuutility.app"
    public static let helperExecutableName = "DFUPrivilegedHelper"
    public static let helperBundleProgram = "Contents/Library/LaunchServices/DFUPrivilegedHelper"
    public static let helperProtocolVersion = BuildMetadata.helperProtocolVersion
}

public enum PrivilegedHelperLayout {
    public static func containingAppURL(for helperURL: URL) -> URL? {
        guard helperURL.lastPathComponent == PrivilegedDFUConstants.helperExecutableName else { return nil }
        let app = helperURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }
    public static func bundledToolURL(for helperURL: URL) -> URL? { containingAppURL(for: helperURL)?.appendingPathComponent("Contents/Resources/macvdmtool") }
}

@objc public protocol PrivilegedDFUXPCProtocol {
    func enterDFU(authorization: Data, reply: @escaping (Int32, String?) -> Void)
    func status(reply: @escaping (Int, String) -> Void)
}

public enum PrivilegedHelperState: Equatable, Sendable, CustomStringConvertible {
    case notRegistered, registrationRequested, awaitingApproval, registered
    case running(version: String, protocolVersion: Int)
    case upgradeRequired(installedProtocol: Int), incompatibleNewer(installedProtocol: Int)
    case authorizationUnavailable, signatureMismatch, failed(String)

    public var isReady: Bool {
        if case .running(_, let value) = self { return value == BuildMetadata.helperProtocolVersion }
        return false
    }
    public var description: String {
        switch self {
        case .notRegistered: "Not registered"
        case .registrationRequested: "Registration requested"
        case .awaitingApproval: "Awaiting user approval"
        case .registered: "Registered; service is not responding"
        case .running(let version, let value): "Running — version \(version), protocol \(value)"
        case .upgradeRequired(let value): "Helper upgrade required — installed protocol \(value)"
        case .incompatibleNewer(let value): "Incompatible newer helper — installed protocol \(value)"
        case .authorizationUnavailable: "Authorization unavailable"
        case .signatureMismatch: "Signature mismatch"
        case .failed(let detail): "Failed — \(detail)"
        }
    }
}

public enum HelperProtocolCompatibility: Equatable, Sendable {
    case compatible, outdated, newerIncompatible
    public static func evaluate(installed: Int, required: Int = BuildMetadata.helperProtocolVersion) -> Self {
        installed == required ? .compatible : (installed < required ? .outdated : .newerIncompatible)
    }
}
public enum HelperRegistrationStatus: Equatable, Sendable { case notRegistered, registrationRequested, awaitingApproval, enabled, failed(String) }
public enum HelperStateResolver {
    public static func resolve(registration: HelperRegistrationStatus, installedProtocol: Int? = nil, version: String = BuildMetadata.displayVersion) -> PrivilegedHelperState {
        switch registration {
        case .notRegistered: return .notRegistered
        case .registrationRequested: return .registrationRequested
        case .awaitingApproval: return .awaitingApproval
        case .failed(let detail): return .failed(detail)
        case .enabled:
            guard let installedProtocol else { return .registered }
            switch HelperProtocolCompatibility.evaluate(installed: installedProtocol) {
            case .compatible: return .running(version: version, protocolVersion: installedProtocol)
            case .outdated: return .upgradeRequired(installedProtocol: installedProtocol)
            case .newerIncompatible: return .incompatibleNewer(installedProtocol: installedProtocol)
            }
        }
    }
}

public struct CallerIdentity: Equatable, Sendable {
    public let identifier: String?; public let teamIdentifier: String?
    public init(identifier: String?, teamIdentifier: String?) { self.identifier = identifier; self.teamIdentifier = teamIdentifier }
}
public enum CallerIdentityPolicy {
    public static func permits(_ caller: CallerIdentity, helper: CallerIdentity, developmentAdHoc: Bool) -> Bool {
        guard caller.identifier == PrivilegedDFUConstants.appIdentifier else { return false }
        if let team = helper.teamIdentifier { return caller.teamIdentifier == team }
        return developmentAdHoc && caller.teamIdentifier == nil
    }
}
public enum CallerValidationPolicy {
    public static func permits(caller: CallerIdentity, expectedTeam: String?, callerHash: Data?, expectedHash: Data?) -> Bool {
        guard caller.identifier == PrivilegedDFUConstants.appIdentifier else { return false }
        if let expectedTeam { return caller.teamIdentifier == expectedTeam }
        return caller.teamIdentifier == nil && callerHash != nil && callerHash == expectedHash
    }
}

public enum PrivilegedDFUClientError: LocalizedError {
    case authorizationCancelled, authorizationFailed(OSStatus), notRegistered(String)
    case incompatibleProtocol(installed: Int, required: Int)
    case registrationFailed(String), connectionInterrupted, connectionInvalidated, callerRejected, connection(String), helper(Int32, String)
    public var errorDescription: String? {
        switch self {
        case .authorizationCancelled: "Administrator authorization was cancelled."
        case .authorizationFailed: "Administrator authorization failed."
        case .notRegistered(let detail): "The privileged DFU helper is not registered. \(detail)"
        case .incompatibleProtocol(let installed, let required): "The privileged DFU helper protocol is incompatible (installed \(installed), required \(required))."
        case .connection(let detail): "The privileged DFU helper is unavailable. \(detail)"
        case .registrationFailed: "Privileged helper registration failed. See Diagnostics for the macOS error details."
        case .connectionInterrupted: "The privileged DFU helper connection was interrupted."
        case .connectionInvalidated: "The privileged DFU helper connection was invalidated."
        case .callerRejected: "The privileged DFU helper rejected this application identity."
        case .helper(_, let detail): detail
        }
    }
}

public protocol PrivilegedDFURequesting: Sendable { func enterDFU() throws }

public final class PrivilegedDFUClient: @unchecked Sendable {
    private let logger = Logger(subsystem: "org.dfuutility.app", category: "PrivilegedHelper")
    public init() {}

    @discardableResult public func setUp() throws -> PrivilegedHelperState {
        let service = SMAppService.daemon(plistName: PrivilegedDFUConstants.daemonPlist)
        let initial = state()
        logger.notice("Setup requested; initial state: \(initial.description, privacy: .public)")
        if case .upgradeRequired = initial { try service.unregister(); try service.register() }
        // An enabled service that is not responding may contain valuable launchd
        // failure state. Do not destroy it merely because Setup was clicked again.
        // Replacement is reserved for a helper that answered and proved outdated.
        else if case .registered = initial { return initial }
        else if service.status == .notRegistered || service.status == .notFound {
            let app = CodeSignatureInfo.inspect(Bundle.main.bundleURL)
            let helper = CodeSignatureInfo.inspect(Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(PrivilegedDFUConstants.helperExecutableName)"))
            guard let appTeam = app.teamIdentifier, let helperTeam = helper.teamIdentifier, appTeam == helperTeam else {
                let details = "The app and privileged helper need matching Apple-issued Team IDs. This package is ad-hoc signed; macOS will not launch its bundled daemon. Package with scripts/package-app.sh --identity using an Apple Development or Developer ID Application identity."
                logger.error("Registration preflight failed: \(details, privacy: .public)")
                throw PrivilegedDFUClientError.registrationFailed(details)
            }
            do { try service.register() }
            catch {
                var after = state()
                for _ in 0..<10 where after == .notRegistered { Thread.sleep(forTimeInterval: 0.1); after = state() }
                logger.notice("Registration returned \(error.localizedDescription, privacy: .public); OS state: \(after.description, privacy: .public)")
                if case .awaitingApproval = after { return after }
                let details = NSErrorDiagnostics.describe(error)
                logger.error("Registration failed: \(details, privacy: .public)")
                throw PrivilegedDFUClientError.registrationFailed(details)
            }
        }
        return state()
    }

    public func enterDFU() throws {
        let helperState = try setUp()
        guard case .running(_, let installed) = helperState, installed == BuildMetadata.helperProtocolVersion else {
            if case .upgradeRequired(let value) = helperState { throw PrivilegedDFUClientError.incompatibleProtocol(installed: value, required: BuildMetadata.helperProtocolVersion) }
            if case .incompatibleNewer(let value) = helperState { throw PrivilegedDFUClientError.incompatibleProtocol(installed: value, required: BuildMetadata.helperProtocolVersion) }
            throw PrivilegedDFUClientError.notRegistered("Approve DFUUtility in System Settings > General > Login Items if requested.")
        }
        let authorization = try authorizationExternalForm()
        let connection = makeConnection(); defer { connection.invalidate() }
        let semaphore = DispatchSemaphore(value: 0), box = ReplyBox()
        connection.interruptionHandler = { self.logger.error("XPC connection interrupted"); box.setError(.connectionInterrupted); semaphore.signal() }
        connection.invalidationHandler = { self.logger.error("XPC connection invalidated"); box.setError(.connectionInvalidated); semaphore.signal() }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in self.logger.error("XPC proxy error: \(error.localizedDescription, privacy: .public)"); box.setError(.callerRejected); semaphore.signal() }) as? PrivilegedDFUXPCProtocol else { throw PrivilegedDFUClientError.connection("Could not create XPC proxy.") }
        proxy.enterDFU(authorization: authorization) { status, detail in box.set(status, detail); semaphore.signal() }
        semaphore.wait()
        if let error = box.error { throw error }
        let result = box.value
        guard result.0 == 0 else { throw PrivilegedDFUClientError.helper(result.0, result.1 ?? "Privileged DFU operation failed.") }
    }

    public func state() -> PrivilegedHelperState {
        switch SMAppService.daemon(plistName: PrivilegedDFUConstants.daemonPlist).status {
        case .enabled: remoteState() ?? .registered
        case .requiresApproval: .awaitingApproval
        case .notRegistered, .notFound: .notRegistered
        @unknown default: .failed("Unknown Service Management state")
        }
    }

    public func unregister() throws { try SMAppService.daemon(plistName: PrivilegedDFUConstants.daemonPlist).unregister() }

    private func remoteState() -> PrivilegedHelperState? {
        let connection = makeConnection(); defer { connection.invalidate() }
        let semaphore = DispatchSemaphore(value: 0), box = StatusReplyBox()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in semaphore.signal() }) as? PrivilegedDFUXPCProtocol else { return nil }
        proxy.status { protocolVersion, version in box.set(protocolVersion, version); semaphore.signal() }
        guard semaphore.wait(timeout: .now() + 2) == .success, let result = box.value else { return nil }
        switch HelperProtocolCompatibility.evaluate(installed: result.0) {
        case .compatible: return .running(version: result.1, protocolVersion: result.0)
        case .outdated: return .upgradeRequired(installedProtocol: result.0)
        case .newerIncompatible: return .incompatibleNewer(installedProtocol: result.0)
        }
    }

    private func makeConnection() -> NSXPCConnection {
        logger.debug("Creating XPC connection to \(PrivilegedDFUConstants.machService, privacy: .public)")
        let connection = NSXPCConnection(machServiceName: PrivilegedDFUConstants.machService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedDFUXPCProtocol.self); connection.resume(); return connection
    }

    private func authorizationExternalForm() throws -> Data {
        var reference: AuthorizationRef?
        var status = AuthorizationCreate(nil, nil, [], &reference)
        guard status == errAuthorizationSuccess, let reference else { throw PrivilegedDFUClientError.authorizationFailed(status) }
        defer { AuthorizationFree(reference, []) }
        _ = PrivilegedDFUConstants.authorizationRight.withCString { right in
            AuthorizationRightSet(reference, right, kAuthorizationRuleAuthenticateAsAdmin as CFString, "DFUUtility needs administrator authorization to place the connected Mac into DFU." as CFString, nil, nil)
        }
        status = PrivilegedDFUConstants.authorizationRight.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(reference, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        if status == errAuthorizationCanceled { throw PrivilegedDFUClientError.authorizationCancelled }
        guard status == errAuthorizationSuccess else { throw PrivilegedDFUClientError.authorizationFailed(status) }
        var external = AuthorizationExternalForm(); status = AuthorizationMakeExternalForm(reference, &external)
        guard status == errAuthorizationSuccess else { throw PrivilegedDFUClientError.authorizationFailed(status) }
        return withUnsafeBytes(of: external) { Data($0) }
    }
}

public enum NSErrorDiagnostics {
    public static func describe(_ error: Error) -> String { describe(error as NSError, depth: 0) }
    private static func describe(_ error: NSError, depth: Int) -> String {
        var fields = ["domain=\(error.domain)", "code=\(error.code)", "description=\(redact(error.localizedDescription))"]
        if let reason = error.localizedFailureReason { fields.append("reason=\(redact(reason))") }
        if let recovery = error.localizedRecoverySuggestion { fields.append("recovery=\(redact(recovery))") }
        let safeInfo = error.userInfo.compactMap { key, value -> String? in
            let name = String(describing: key)
            if name == NSUnderlyingErrorKey || name.localizedCaseInsensitiveContains("token") || name.localizedCaseInsensitiveContains("authorization") || name.localizedCaseInsensitiveContains("password") { return nil }
            return "\(name)=\(redact(String(describing: value)))"
        }.sorted()
        if !safeInfo.isEmpty { fields.append("userInfo={\(safeInfo.joined(separator: ", "))}") }
        if depth < 4, let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { fields.append("underlying=[\(describe(underlying, depth: depth + 1))]") }
        return fields.joined(separator: "; ")
    }
    private static func redact(_ value: String) -> String {
        value.replacingOccurrences(of: #"(?i)(password|token|authorization)\s*[:=]\s*\S+"#, with: "$1=<redacted>", options: .regularExpression)
    }
}
extension PrivilegedDFUClient: PrivilegedDFURequesting {}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock(); private var result: (Int32, String?) = (-1, nil); private var storedError: PrivilegedDFUClientError?
    func set(_ status: Int32, _ detail: String?) { lock.withLock { guard storedError == nil else { return }; result = (status, detail) } }
    func setError(_ error: PrivilegedDFUClientError) { lock.withLock { if storedError == nil { storedError = error } } }
    var error: PrivilegedDFUClientError? { lock.withLock { storedError } }
    var value: (Int32, String?) { lock.withLock { result } }
}
private final class StatusReplyBox: @unchecked Sendable {
    private let lock = NSLock(); private var result: (Int, String)?
    func set(_ value: Int, _ version: String) { lock.withLock { result = (value, version) } }
    var value: (Int, String)? { lock.withLock { result } }
}
