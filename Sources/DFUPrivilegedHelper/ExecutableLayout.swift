import Darwin
import DFUCore
import Foundation

enum ExecutableLayout {
    static func currentExecutableURL() -> URL? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).resolvingSymlinksInPath()
    }

    static func containingAppURL(for helperURL: URL) -> URL? {
        PrivilegedHelperLayout.containingAppURL(for: helperURL)
    }

    static func bundledToolURL(for helperURL: URL) -> URL? {
        PrivilegedHelperLayout.bundledToolURL(for: helperURL)
    }
}
