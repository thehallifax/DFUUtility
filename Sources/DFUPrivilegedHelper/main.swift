import DFUCore
import Foundation
import Security
import OSLog

private let helperLogger = Logger(subsystem: "org.dfuutility.privileged-helper", category: "Service")

private final class PrivilegedService: NSObject, PrivilegedDFUXPCProtocol {
    func status(reply: @escaping (Int, String) -> Void) { reply(BuildMetadata.helperProtocolVersion, BuildMetadata.displayVersion) }

    func enterDFU(authorization: Data, reply: @escaping (Int32, String?) -> Void) {
        guard validateAuthorization(authorization) else { reply(EPERM, "Administrator authorization failed."); return }
        guard let helperURL = ExecutableLayout.currentExecutableURL(), let tool = ExecutableLayout.bundledToolURL(for: helperURL) else { reply(ENOENT, "The privileged helper could not resolve its containing application."); return }
        guard Self.validBundledTool(tool) else { reply(EPERM, "The bundled DFU implementation failed integrity validation."); return }
        let process = Process(); process.executableURL = tool; process.arguments = ["dfu"]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        do {
            try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            let message = String(decoding: data, as: UTF8.self)
            reply(process.terminationStatus, process.terminationStatus == 0 ? nil : (message.isEmpty ? "VDM DFU request failed." : message))
        } catch { reply(-1, error.localizedDescription) }
    }

    private static func validBundledTool(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o022 == 0 else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
    }

    private func validateAuthorization(_ data: Data) -> Bool {
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else { return false }
        var external = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &external) { data.copyBytes(to: $0) }
        var authorization: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&external, &authorization) == errAuthorizationSuccess, let authorization else { return false }
        defer { AuthorizationFree(authorization, []) }
        return PrivilegedDFUConstants.authorizationRight.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(authorization, &rights, nil, [], nil) == errAuthorizationSuccess
            }
        }
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = PrivilegedService()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let result = Self.validateCaller(connection.processIdentifier)
        guard result.accepted else { helperLogger.error("Rejected XPC caller pid=\(connection.processIdentifier) reason=\(result.reason, privacy: .public)"); return false }
        helperLogger.notice("Accepted XPC caller pid=\(connection.processIdentifier)")
        connection.exportedInterface = NSXPCInterface(with: PrivilegedDFUXPCProtocol.self)
        connection.exportedObject = service; connection.resume(); return true
    }

    static func validateCaller(_ pid: pid_t) -> (accepted: Bool, reason: String) {
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else { return (false, "caller code unavailable") }
        var guestStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &guestStatic) == errSecSuccess, let guestStatic else { return (false, "caller static code unavailable") }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(guestStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [CFString: Any] else { return (false, "caller signing information unavailable") }
        let caller = CallerIdentity(identifier: values[kSecCodeInfoIdentifier] as? String, teamIdentifier: values[kSecCodeInfoTeamIdentifier] as? String)
        guard caller.identifier == PrivilegedDFUConstants.appIdentifier else { return (false, "app identifier mismatch") }

        // Bind the connection to the exact app containing this daemon. This keeps
        // ad-hoc development builds from trusting an attacker-controlled binary
        // that merely copies the bundle identifier.
        guard let helperURL = ExecutableLayout.currentExecutableURL(), let appURL = ExecutableLayout.containingAppURL(for: helperURL) else { return (false, "containing app path unavailable") }
        var expectedCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &expectedCode) == errSecSuccess, let expectedCode else { return (false, "containing app code unavailable") }
        var expectedInfo: CFDictionary?
        guard SecStaticCodeCheckValidity(expectedCode, [], nil) == errSecSuccess,
              SecStaticCodeCheckValidity(guestStatic, [], nil) == errSecSuccess,
              SecCodeCopySigningInformation(expectedCode, SecCSFlags(rawValue: kSecCSSigningInformation), &expectedInfo) == errSecSuccess,
              let expected = expectedInfo as? [CFString: Any] else { return (false, "code validity or signing information failed") }
        if let expectedTeam = expected[kSecCodeInfoTeamIdentifier] as? String {
            // Stable production requirement: valid code, exact app identifier,
            // and the same Developer ID Team ID permit signed upgrades.
            let accepted = CallerValidationPolicy.permits(caller: caller, expectedTeam: expectedTeam, callerHash: nil, expectedHash: nil)
            return (accepted, accepted ? "same Developer ID team" : "Team ID mismatch")
        }
        guard let callerHash = values[kSecCodeInfoUnique] as? Data,
              let expectedHash = expected[kSecCodeInfoUnique] as? Data else { return (false, "ad-hoc code hash unavailable") }
        let accepted = CallerValidationPolicy.permits(caller: caller, expectedTeam: nil, callerHash: callerHash, expectedHash: expectedHash)
        return (accepted, accepted ? "exact ad-hoc app code" : "ad-hoc code hash mismatch")
    }
}

private let delegate = ListenerDelegate(), listener = NSXPCListener(machServiceName: PrivilegedDFUConstants.machService)
helperLogger.notice("Helper starting pid=\(getpid()) executable=\(ExecutableLayout.currentExecutableURL()?.path ?? "unavailable", privacy: .public)")
listener.delegate = delegate; listener.resume(); helperLogger.notice("XPC listener active: \(PrivilegedDFUConstants.machService, privacy: .public)"); RunLoop.current.run()
