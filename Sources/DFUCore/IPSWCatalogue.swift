import Foundation

public protocol HTTPDataFetching: Sendable { func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) }
public struct URLSessionHTTPClient: HTTPDataFetching {
    public init() {}
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw IPSWServiceError.malformedCatalogue("non-HTTP response") }
        return (data, http)
    }
}
public protocol IPSWCatalogueFetching: Sendable { func releases() async throws -> [IPSWRelease] }

public struct AppleIPSWCatalogue: IPSWCatalogueFetching {
    public static let url = URL(string: "https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml")!
    private let client: any HTTPDataFetching; private let includeSizes: Bool
    public init(client: any HTTPDataFetching = URLSessionHTTPClient(), includeSizes: Bool = true) { self.client = client; self.includeSizes = includeSizes }
    public func releases() async throws -> [IPSWRelease] {
        var request = URLRequest(url: Self.url); request.setValue("MobileAsset/1.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await client.data(for: request)
        guard response.statusCode == 200 else { throw IPSWServiceError.http(response.statusCode) }
        var releases = try Self.parse(data)
        if includeSizes {
            for index in releases.indices {
                var head = URLRequest(url: releases[index].downloadURL); head.httpMethod = "HEAD"
                if let (_, result) = try? await client.data(for: head), result.statusCode == 200,
                   let length = result.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) { releases[index].fileSize = length }
            }
        }
        return AppleIPSWService.sortNewestFirst(releases)
    }
    public static func parse(_ data: Data) throws -> [IPSWRelease] {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let versions = root["MobileDeviceSoftwareVersionsByVersion"] as? [String: Any],
              let generation = versions["1"] as? [String: Any],
              let models = generation["MobileDeviceSoftwareVersions"] as? [String: Any] else { throw IPSWServiceError.malformedCatalogue("missing MobileDeviceSoftwareVersions") }
        var found: [URL: (String, String, String?, Set<String>)] = [:]
        for (model, rawBuilds) in models {
            guard let builds = rawBuilds as? [String: Any] else { continue }
            for raw in builds.values {
                guard let dictionary = raw as? [String: Any] else { continue }
                let restore = dictionary["Restore"] as? [String: Any] ?? (dictionary["Universal"] as? [String: Any])?["Restore"] as? [String: Any]
                guard let restore, let text = restore["FirmwareURL"] as? String, let url = URL(string: text),
                      let version = restore["ProductVersion"] as? String, let build = restore["BuildVersion"] as? String else { continue }
                guard isTrustedFirmwareURL(url) else { throw IPSWServiceError.untrustedURL(text) }
                var item = found[url] ?? (version, build, restore["FirmwareSHA1"] as? String, [])
                if model != "Unknown" { item.3.insert(model) }; found[url] = item
            }
        }
        let result = found.map { IPSWRelease(version: $0.value.0, build: $0.value.1, downloadURL: $0.key, checksum: $0.value.2, supportedDevices: $0.value.3.sorted()) }
        guard !result.isEmpty else { throw IPSWServiceError.noReleases }; return AppleIPSWService.sortNewestFirst(result)
    }
    public static func isTrustedFirmwareURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "updates.cdn-apple.com" || host.hasSuffix(".apple.com")
    }
}
