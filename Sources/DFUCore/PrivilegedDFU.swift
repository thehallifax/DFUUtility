import Foundation
import Security
import ServiceManagement

public enum PrivilegedDFUConstants {
    public static let machService = "org.dfuutility.privileged-helper"
    public static let daemonPlist = "org.dfuutility.privileged-helper.plist"
    public static let authorizationRight = "org.dfuutility.enter-dfu"
    public static let appIdentifier = "org.dfuutility.app"
    public static let helperVersion = 1
}

@objc public protocol PrivilegedDFUXPCProtocol {
    /// The deliberately narrow privileged surface. No path, command, or arguments
    /// cross the boundary.
    func enterDFU(authorization: Data, reply: @escaping (Int32, String?) -> Void)
    func status(reply: @escaping (Int, String) -> Void)
}

public enum PrivilegedHelperState: Equatable, Sendable {
    case installed, registered, available, notRegistered, authorizationUnavailable, versionMismatch, signatureMismatch
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

public enum PrivilegedDFUClientError: LocalizedError {
    case authorizationCancelled, authorizationFailed(OSStatus), notRegistered(String), connection(String), helper(Int32, String)
    public var errorDescription: String? {
        switch self {
        case .authorizationCancelled: "Administrator authorization was cancelled."
        case .authorizationFailed: "Administrator authorization failed."
        case .notRegistered(let detail): "The privileged DFU helper is not registered. \(detail)"
        case .connection(let detail): "The privileged DFU helper is unavailable. \(detail)"
        case .helper(_, let detail): detail
        }
    }
}

public protocol PrivilegedDFURequesting: Sendable { func enterDFU() throws }

public final class PrivilegedDFUClient: @unchecked Sendable {
    public init() {}

    public func registerIfNeeded() throws {
        let service = SMAppService.daemon(plistName: PrivilegedDFUConstants.daemonPlist)
        if service.status == .notRegistered { try service.register() }
        guard service.status == .enabled else { throw PrivilegedDFUClientError.notRegistered("Approve DFUUtility in System Settings > General > Login Items if requested.") }
    }

    public func enterDFU() throws {
        try registerIfNeeded()
        let authorization = try authorizationExternalForm()
        let connection = NSXPCConnection(machServiceName: PrivilegedDFUConstants.machService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedDFUXPCProtocol.self)
        connection.resume(); defer { connection.invalidate() }
        let semaphore = DispatchSemaphore(value: 0), box = ReplyBox()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in box.set(-1, error.localizedDescription); semaphore.signal() }) as? PrivilegedDFUXPCProtocol else {
            throw PrivilegedDFUClientError.connection("Could not create XPC proxy.")
        }
        proxy.enterDFU(authorization: authorization) { status, detail in box.set(status, detail); semaphore.signal() }
        semaphore.wait()
        let result = box.value
        guard result.0 == 0 else { throw PrivilegedDFUClientError.helper(result.0, result.1 ?? "Privileged DFU operation failed.") }
    }

    public func state() -> PrivilegedHelperState {
        switch SMAppService.daemon(plistName: PrivilegedDFUConstants.daemonPlist).status {
        case .enabled: .registered
        case .requiresApproval, .notRegistered, .notFound: .notRegistered
        @unknown default: .notRegistered
        }
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
        var external = AuthorizationExternalForm()
        status = AuthorizationMakeExternalForm(reference, &external)
        guard status == errAuthorizationSuccess else { throw PrivilegedDFUClientError.authorizationFailed(status) }
        return withUnsafeBytes(of: external) { Data($0) }
    }
}
extension PrivilegedDFUClient: PrivilegedDFURequesting {}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock(); private var result: (Int32, String?) = (-1, nil)
    func set(_ status: Int32, _ detail: String?) { lock.withLock { result = (status, detail) } }
    var value: (Int32, String?) { lock.withLock { result } }
}
