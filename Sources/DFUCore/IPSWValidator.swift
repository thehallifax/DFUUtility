import Foundation

public enum IPSWValidationPredicate: String, Equatable, Sendable { case existence, minimumSize, expectedSize, archiveDirectory, requiredManifests, supportedDevices, checksum }
public struct IPSWValidationFailure: Equatable, Sendable {
    public let predicate: IPSWValidationPredicate
    public let reason: String
    public init(predicate: IPSWValidationPredicate, reason: String) { self.predicate = predicate; self.reason = reason }
}
public enum IPSWValidationResult: Equatable, Sendable { case valid; case invalid(IPSWValidationFailure) }
public protocol IPSWValidating: Sendable { func validate(_ url: URL, release: IPSWRelease?, verifyChecksum: Bool) throws }
public extension IPSWValidating {
    func validationResult(_ url: URL, release: IPSWRelease?, verifyChecksum: Bool) -> IPSWValidationResult {
        do { try validate(url, release: release, verifyChecksum: verifyChecksum); return .valid }
        catch let error as IPSWServiceError {
            let predicate: IPSWValidationPredicate = if case .incorrectSize = error { .expectedSize } else { .checksum }
            return .invalid(.init(predicate: predicate, reason: error.localizedDescription))
        }
        catch let error as DFUError {
            let reason = error.localizedDescription
            let predicate: IPSWValidationPredicate
            if reason.contains("does not exist") { predicate = .existence }
            else if reason.contains("small") { predicate = .minimumSize }
            else if reason.contains("ZIP directory") { predicate = .archiveDirectory }
            else if reason.contains("missing BuildManifest") { predicate = .requiredManifests }
            else if reason.contains("compatible") { predicate = .supportedDevices }
            else if reason.contains("SHA-1") { predicate = .checksum }
            else { predicate = .archiveDirectory }
            return .invalid(.init(predicate: predicate, reason: reason))
        }
        catch { return .invalid(.init(predicate: .archiveDirectory, reason: error.localizedDescription)) }
    }
}
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
        if let release, !release.supportedDevices.isEmpty {
            let manifestPaths = listing.stdoutString.split(separator: "\n").map(String.init).filter { $0.hasSuffix("BuildManifest.plist") }
            let manifestPath = manifestPaths.first(where: { $0 == "BuildManifest.plist" }) ?? manifestPaths.min(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) ?? "BuildManifest.plist"
            let manifest = try runner.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-p", url.path, manifestPath])
            guard manifest.status == 0,
                  let plist = try? PropertyListSerialization.propertyList(from: manifest.stdout, format: nil) as? [String: Any],
                  let products = plist["SupportedProductTypes"] as? [String],
                  !Set(products).isDisjoint(with: release.supportedDevices) else {
                throw DFUError.invalidIPSW("BuildManifest is not compatible with the selected product type")
            }
        }
        if verifyChecksum, let expected = release?.checksum?.lowercased() {
            let hash = try runner.run(URL(fileURLWithPath: "/usr/bin/shasum"), arguments: ["-a", "1", url.path])
            guard hash.status == 0, let actual = hash.stdoutString.split(separator: " ").first.map(String.init) else { throw DFUError.invalidIPSW("could not calculate SHA-1") }
            guard actual.lowercased() == expected else { throw IPSWServiceError.checksumMismatch(expected: expected, actual: actual) }
        }
    }
}
