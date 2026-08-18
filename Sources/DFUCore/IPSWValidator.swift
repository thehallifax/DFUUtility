import Foundation

public protocol IPSWValidating: Sendable { func validate(_ url: URL, release: IPSWRelease?, verifyChecksum: Bool) throws }
public struct IPSWValidator: IPSWValidating {
    private let runner: any CommandRunning
    public init(runner: any CommandRunning = ProcessRunner()) { self.runner = runner }
    public func validate(_ url: URL, release: IPSWRelease? = nil, verifyChecksum: Bool = false) throws {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else { throw DFUError.invalidIPSW("file does not exist") }
        let size = ((try FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard size > 1_000_000 else { throw DFUError.invalidIPSW("file is implausibly small") }
        if let expected = release?.fileSize, expected != size { throw IPSWServiceError.incorrectSize(expected: expected, actual: size) }
        let listing = try runner.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z1", url.path])
        guard listing.status == 0 else { throw DFUError.invalidIPSW("ZIP directory is unreadable") }
        guard listing.stdoutString.contains("BuildManifest.plist"), listing.stdoutString.contains("Restore.plist") else { throw DFUError.invalidIPSW("missing BuildManifest.plist or Restore.plist") }
        if verifyChecksum, let expected = release?.checksum?.lowercased() {
            let hash = try runner.run(URL(fileURLWithPath: "/usr/bin/shasum"), arguments: ["-a", "1", url.path])
            guard hash.status == 0, let actual = hash.stdoutString.split(separator: " ").first.map(String.init) else { throw DFUError.invalidIPSW("could not calculate SHA-1") }
            guard actual.lowercased() == expected else { throw IPSWServiceError.checksumMismatch(expected: expected, actual: actual) }
        }
    }
}
