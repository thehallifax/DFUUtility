import DFUCore
import Foundation
import Security

private final class PrivilegedService: NSObject, PrivilegedDFUXPCProtocol {
    func status(reply: @escaping (Int, String) -> Void) { reply(PrivilegedDFUConstants.helperVersion, "Available") }

    func enterDFU(authorization: Data, reply: @escaping (Int32, String?) -> Void) {
        guard validateAuthorization(authorization) else { reply(EPERM, "Administrator authorization failed."); return }
        let helperURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let tool = helperURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/macvdmtool")
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
        guard Self.validCaller(connection.processIdentifier) else { return false }
        connection.exportedInterface = NSXPCInterface(with: PrivilegedDFUXPCProtocol.self)
        connection.exportedObject = service; connection.resume(); return true
    }

    private static func validCaller(_ pid: pid_t) -> Bool {
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else { return false }
        var guestStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &guestStatic) == errSecSuccess, let guestStatic else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(guestStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [CFString: Any] else { return false }
        let caller = CallerIdentity(identifier: values[kSecCodeInfoIdentifier] as? String, teamIdentifier: values[kSecCodeInfoTeamIdentifier] as? String)
        guard caller.identifier == PrivilegedDFUConstants.appIdentifier else { return false }

        // Bind the connection to the exact app containing this daemon. This keeps
        // ad-hoc development builds from trusting an attacker-controlled binary
        // that merely copies the bundle identifier.
        let helperURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let appURL = helperURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var expectedCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &expectedCode) == errSecSuccess, let expectedCode else { return false }
        var expectedInfo: CFDictionary?
        guard SecCodeCopySigningInformation(expectedCode, SecCSFlags(rawValue: kSecCSSigningInformation), &expectedInfo) == errSecSuccess,
              let expected = expectedInfo as? [CFString: Any],
              let callerHash = values[kSecCodeInfoUnique] as? Data,
              let expectedHash = expected[kSecCodeInfoUnique] as? Data,
              callerHash == expectedHash else { return false }
        if let expectedTeam = expected[kSecCodeInfoTeamIdentifier] as? String { return caller.teamIdentifier == expectedTeam }
        return caller.teamIdentifier == nil
    }
}

private let delegate = ListenerDelegate(), listener = NSXPCListener(machServiceName: PrivilegedDFUConstants.machService)
listener.delegate = delegate; listener.resume(); RunLoop.current.run()
