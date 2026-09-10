import CryptoKit
import Foundation

/// Strict release version used by the binary updater. GitHub tags are required
/// to use the `vMAJOR.MINOR.PATCH` form with no prerelease suffixes.
public struct SemanticVersion: Comparable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    public init?(tag: String) {
        guard tag.first == "v" else { return nil }
        let components = tag.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && ($0 == "0" || $0.first != "0") && $0.allSatisfy(\.isNumber) }),
              let major = Int(components[0]), let minor = Int(components[1]), let patch = Int(components[2]) else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
    public var tag: String { "v\(description)" }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public struct GitHubReleaseAsset: Equatable, Sendable {
    public let name: String
    public let downloadURL: URL
    public let size: Int64
    public let digest: String?
    public init(name: String, downloadURL: URL, size: Int64, digest: String?) {
        self.name = name; self.downloadURL = downloadURL; self.size = size; self.digest = digest
    }
}

public struct GitHubReleaseMetadata: Equatable, Sendable {
    public let tagName: String
    public let draft: Bool
    public let prerelease: Bool
    public let releaseURL: URL?
    public let assets: [GitHubReleaseAsset]
    public init(tagName: String, draft: Bool, prerelease: Bool, releaseURL: URL?, assets: [GitHubReleaseAsset]) {
        self.tagName = tagName; self.draft = draft; self.prerelease = prerelease; self.releaseURL = releaseURL; self.assets = assets
    }
}

public struct ValidatedBinaryRelease: Equatable, Sendable {
    public let version: SemanticVersion
    public let releaseURL: URL?
    public let asset: GitHubReleaseAsset
    public let digest: String
    public init(version: SemanticVersion, releaseURL: URL?, asset: GitHubReleaseAsset, digest: String) {
        self.version = version; self.releaseURL = releaseURL; self.asset = asset; self.digest = digest
    }
}

public enum BinaryUpdateError: LocalizedError, Equatable, Sendable {
    case invalidVersionTag(String)
    case draftOrPrerelease
    case notNewer(String)
    case invalidAsset(String)
    case duplicateAssets
    case httpStatus(Int)
    case network(String)
    case oversizedArtifact
    case sizeMismatch(expected: Int64, actual: Int64)
    case malformedDigest
    case digestMismatch
    case unsafeArchive(String)
    case extractionFailed(String)
    case invalidBundle(String)
    case signatureVerificationFailed
    case stagingFailure(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidVersionTag(let value): "Release tag is not a strict semantic version: \(value)"
        case .draftOrPrerelease: "Draft and prerelease releases are not eligible."
        case .notNewer(let value): "Release \(value) is not newer than the installed version."
        case .invalidAsset(let value): "Release asset is invalid: \(value)"
        case .duplicateAssets: "The release contains duplicate matching DFUUtility assets."
        case .httpStatus(let code): "Update server returned HTTP \(code)."
        case .network(let value): "Update download failed: \(value)"
        case .oversizedArtifact: "The update artifact exceeds the safety size limit."
        case .sizeMismatch(let expected, let actual): "Update size mismatch (expected \(expected), received \(actual))."
        case .malformedDigest: "The release does not contain a valid SHA-256 digest."
        case .digestMismatch: "The downloaded update failed SHA-256 verification."
        case .unsafeArchive(let value): "The update archive is unsafe: \(value)"
        case .extractionFailed(let value): "The update archive could not be extracted: \(value)"
        case .invalidBundle(let value): "The extracted application is invalid: \(value)"
        case .signatureVerificationFailed: "The extracted application failed structural code-signature verification."
        case .stagingFailure(let value): "The update could not be staged safely: \(value)"
        case .cancelled: "Update download cancelled."
        }
    }
}

public struct GitHubReleaseClient: Sendable {
    public static let owner = "thehallifax"
    public static let repository = "DFUUtility"
    public static let apiURL = URL(string: "https://api.github.com/repos/thehallifax/DFUUtility/releases")!
    private let client: any HTTPDataFetching
    public init(client: any HTTPDataFetching = URLSessionHTTPClient()) { self.client = client }

    public func releases() async throws -> [GitHubReleaseMetadata] {
        var request = URLRequest(url: Self.apiURL)
        request.setValue("DFUUtility/0.10 release-check", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await client.data(for: request)
        guard response.statusCode == 200 else { throw BinaryUpdateError.httpStatus(response.statusCode) }
        do {
            return try JSONDecoder().decode([ReleaseDTO].self, from: data).map(\.metadata)
        } catch { throw BinaryUpdateError.network("GitHub returned malformed release metadata") }
    }

    private struct ReleaseDTO: Decodable {
        let tag_name: String; let draft: Bool; let prerelease: Bool; let html_url: URL?; let assets: [AssetDTO]
        var metadata: GitHubReleaseMetadata { .init(tagName: tag_name, draft: draft, prerelease: prerelease, releaseURL: html_url, assets: assets.map(\.metadata)) }
    }
    private struct AssetDTO: Decodable {
        let name: String; let browser_download_url: URL; let size: Int64; let digest: String?
        var metadata: GitHubReleaseAsset { .init(name: name, downloadURL: browser_download_url, size: size, digest: digest) }
    }
}

public struct ReleaseMetadataValidator: Sendable {
    public static let maximumArtifactSize: Int64 = 512 * 1024 * 1024
    public init() {}

    /// Selects the newest eligible stable release. Invalid, draft, prerelease,
    /// and non-newer candidates are ignored rather than becoming installable.
    public func selectLatest(from releases: [GitHubReleaseMetadata], installed: SemanticVersion) -> ValidatedBinaryRelease? {
        releases.compactMap { release in
            try? validate(release, installed: installed)
        }.max { $0.version < $1.version }
    }

    public func validate(_ release: GitHubReleaseMetadata, installed: SemanticVersion) throws -> ValidatedBinaryRelease {
        guard !release.draft, !release.prerelease else { throw BinaryUpdateError.draftOrPrerelease }
        guard let version = SemanticVersion(tag: release.tagName) else { throw BinaryUpdateError.invalidVersionTag(release.tagName) }
        guard version > installed else { throw BinaryUpdateError.notNewer(version.description) }
        let expectedName = "DFUUtility-\(version).zip"
        let matches = release.assets.filter { $0.name == expectedName }
        guard matches.count == 1 else { throw matches.isEmpty ? BinaryUpdateError.invalidAsset("missing \(expectedName)") : BinaryUpdateError.duplicateAssets }
        let asset = matches[0]
        guard asset.size > 0, asset.size <= Self.maximumArtifactSize else { throw asset.size <= 0 ? BinaryUpdateError.invalidAsset("invalid size") : BinaryUpdateError.oversizedArtifact }
        guard asset.downloadURL.scheme?.lowercased() == "https", asset.downloadURL.host?.lowercased() == "github.com",
              asset.downloadURL.path == "/thehallifax/DFUUtility/releases/download/\(release.tagName)/\(expectedName)" else { throw BinaryUpdateError.invalidAsset("download URL is not the expected GitHub release asset") }
        guard let digest = normalizedDigest(asset.digest) else { throw BinaryUpdateError.malformedDigest }
        return .init(version: version, releaseURL: release.releaseURL, asset: asset, digest: digest)
    }

    public func normalizedDigest(_ value: String?) -> String? {
        guard let value, value.lowercased().hasPrefix("sha256:") else { return nil }
        let hex = String(value.dropFirst("sha256:".count)).lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) }) else { return nil }
        return hex
    }
}

public struct DownloadedBinaryArtifact: Equatable, Sendable {
    public let url: URL
    public let byteCount: Int64
    public init(url: URL, byteCount: Int64) { self.url = url; self.byteCount = byteCount }
}

public protocol BinaryUpdateNetworking: Sendable {
    func download(_ url: URL, expectedSize: Int64, maximumSize: Int64, to destination: URL) async throws -> Int64
}

public enum BinaryRedirectPolicy {
    public static let maximumRedirects = 5
    public static let allowedHosts: Set<String> = ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]

    public static func allows(source: URL, destination: URL) -> Bool {
        guard source.scheme?.lowercased() == "https", destination.scheme?.lowercased() == "https",
              destination.user == nil, destination.port == nil,
              let host = destination.host?.lowercased(), allowedHosts.contains(host),
              destination.host?.contains(".") == true else { return false }
        return true
    }

    public static func logMessage(source: URL?, destination: URL?, accepted: Bool) -> String {
        let sourceHost = source?.host?.lowercased() ?? "unknown"
        let destinationHost = destination?.host?.lowercased() ?? "unknown"
        return "redirect " + (accepted ? "accepted" : "rejected") + ": " + sourceHost + " → " + destinationHost
    }
}

public struct URLSessionBinaryUpdateNetworking: BinaryUpdateNetworking {
    private let log: (@Sendable (String) -> Void)?
    public init(log: (@Sendable (String) -> Void)? = nil) { self.log = log ?? URLSessionBinaryUpdateNetworking.appendDefaultLog }
    private static func appendDefaultLog(_ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DFUUtility/update.log")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
            try handle.seekToEnd(); let line = "[" + ISO8601DateFormatter().string(from: Date()) + "] " + message + "\n"; try handle.write(contentsOf: Data(line.utf8))
        } catch { }
    }
    public func download(_ url: URL, expectedSize: Int64, maximumSize: Int64, to destination: URL) async throws -> Int64 {
        guard url.scheme?.lowercased() == "https" else { throw BinaryUpdateError.invalidAsset("download URL is not HTTPS") }
        let delegate = RedirectDelegate(log: log)
        var request = URLRequest(url: url); request.setValue("DFUUtility/0.10 binary-update", forHTTPHeaderField: "User-Agent")
        do {
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw BinaryUpdateError.network("non-HTTP response") }
            guard http.statusCode == 200 else { throw BinaryUpdateError.httpStatus(http.statusCode) }
            guard let finalURL = response.url, BinaryRedirectPolicy.allows(source: url, destination: finalURL) else { throw BinaryUpdateError.invalidAsset("download redirected to an untrusted host") }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination); defer { try? handle.close() }
            var count: Int64 = 0
            for try await byte in bytes {
                try Task.checkCancellation(); count += 1
                guard count <= maximumSize else { throw BinaryUpdateError.oversizedArtifact }
                try handle.write(contentsOf: Data([byte]))
            }
            guard count == expectedSize else { throw BinaryUpdateError.sizeMismatch(expected: expectedSize, actual: count) }
            return count
        } catch let error as BinaryUpdateError { try? FileManager.default.removeItem(at: destination); throw error }
        catch is CancellationError { try? FileManager.default.removeItem(at: destination); throw BinaryUpdateError.cancelled }
        catch { try? FileManager.default.removeItem(at: destination); throw BinaryUpdateError.network(error.localizedDescription) }
    }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let log: (@Sendable (String) -> Void)?
        var redirects = 0
        init(log: (@Sendable (String) -> Void)?) { self.log = log }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            redirects += 1
            guard redirects <= BinaryRedirectPolicy.maximumRedirects, let source = task.currentRequest?.url, let destination = request.url,
                  BinaryRedirectPolicy.allows(source: source, destination: destination) else {
                log?(BinaryRedirectPolicy.logMessage(source: task.currentRequest?.url, destination: request.url, accepted: false))
                completionHandler(nil); return
            }
            log?(BinaryRedirectPolicy.logMessage(source: source, destination: destination, accepted: true))
            completionHandler(request)
        }
    }
}

public struct BinaryUpdateDownloader: Sendable {
    private let networking: any BinaryUpdateNetworking
    public init(networking: any BinaryUpdateNetworking = URLSessionBinaryUpdateNetworking()) { self.networking = networking }
    public func download(_ release: ValidatedBinaryRelease, in directory: URL) async throws -> DownloadedBinaryArtifact {
        let destination = directory.appendingPathComponent(release.asset.name)
        do {
            let count = try await networking.download(release.asset.downloadURL, expectedSize: release.asset.size, maximumSize: ReleaseMetadataValidator.maximumArtifactSize, to: destination)
            return .init(url: destination, byteCount: count)
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
}

public struct VerifiedUpdateArtifact: Equatable, Sendable {
    public let appURL: URL
    public let version: SemanticVersion
    public let build: String
    public init(appURL: URL, version: SemanticVersion, build: String) { self.appURL = appURL; self.version = version; self.build = build }
}

public struct SafeZIPInspector: Sendable {
    private let runner: any CommandRunning
    public init(runner: any CommandRunning = ProcessRunner()) { self.runner = runner }

    public func extract(_ archive: URL, into root: URL) throws -> URL {
        let listing = try runner.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z1", archive.path])
        guard listing.status == 0 else { throw BinaryUpdateError.extractionFailed(listing.stderrString) }
        let entries = listing.stdoutString.split(whereSeparator: \.isNewline).map(String.init)
        guard !entries.isEmpty else { throw BinaryUpdateError.unsafeArchive("archive is empty") }
        var topLevelApps = Set<String>()
        for entry in entries {
            guard !entry.hasPrefix("/"), !entry.split(separator: "/").contains("..") else { throw BinaryUpdateError.unsafeArchive("path traversal entry \(entry)") }
            let components = entry.split(separator: "/"); guard let first = components.first else { continue }
            if first.hasSuffix(".app") { topLevelApps.insert(String(first)) }
        }
        guard topLevelApps == ["DFUUtility.app"] else { throw BinaryUpdateError.unsafeArchive("expected exactly one DFUUtility.app") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = try runner.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-qq", "-o", archive.path, "-d", root.path])
        guard result.status == 0 else { throw BinaryUpdateError.extractionFailed(result.stderrString) }
        let app = root.appendingPathComponent("DFUUtility.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw BinaryUpdateError.unsafeArchive("DFUUtility.app was not extracted") }
        try rejectEscapingSymlinks(in: root)
        return app
    }

    private func rejectEscapingSymlinks(in root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
               !url.resolvingSymlinksInPath().path.hasPrefix(root.standardizedFileURL.path + "/") { throw BinaryUpdateError.unsafeArchive("symbolic link escapes staging root") }
        }
    }
}

public struct BinaryArtifactVerifier: Sendable {
    private let runner: any CommandRunning
    private let inspector: SafeZIPInspector
    public init(runner: any CommandRunning = ProcessRunner(), inspector: SafeZIPInspector? = nil) { self.runner = runner; self.inspector = inspector ?? SafeZIPInspector(runner: runner) }

    public func verify(_ artifact: DownloadedBinaryArtifact, release: ValidatedBinaryRelease, stagingDirectory: URL) throws -> VerifiedUpdateArtifact {
        guard SHA256.hash(file: artifact.url) == release.digest else { throw BinaryUpdateError.digestMismatch }
        let app = try inspector.extract(artifact.url, into: stagingDirectory)
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else { throw BinaryUpdateError.invalidBundle("Info.plist is missing or malformed") }
        guard info["CFBundleIdentifier"] as? String == "org.dfuutility.app" else { throw BinaryUpdateError.invalidBundle("bundle identifier mismatch") }
        guard info["CFBundleShortVersionString"] as? String == release.version.description else { throw BinaryUpdateError.invalidBundle("version mismatch") }
        guard let build = info["CFBundleVersion"] as? String, !build.isEmpty, Int(build) != nil else { throw BinaryUpdateError.invalidBundle("build is missing or malformed") }
        let required = ["Contents/MacOS/DFUUtility", "Contents/Library/LaunchServices/DFUPrivilegedHelper", "Contents/Resources/macvdmtool", "Contents/Resources/DFUUtility-LICENSE.txt", "Contents/Resources/ThirdPartyLicenses/macvdmtool-Apache-2.0.txt", "Contents/Resources/ThirdPartyLicenses/macvdmtool-UPSTREAM_REVISION.txt"]
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: app.appendingPathComponent($0).path) }) else { throw BinaryUpdateError.invalidBundle("required application resource is missing") }
        let signature = try runner.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--verify", "--deep", "--strict", app.path])
        guard signature.status == 0 else { throw BinaryUpdateError.signatureVerificationFailed }
        return .init(appURL: app, version: release.version, build: build)
    }
}

private extension SHA256 {
    static func hash(file url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        var hasher = SHA256(); defer { try? handle.close() }
        while true {
            let data = handle.readData(ofLength: 1_048_576)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
