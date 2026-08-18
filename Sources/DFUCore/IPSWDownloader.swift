import Foundation

public protocol IPSWDownloading: Sendable { func download(_ release: IPSWRelease, to partial: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws }
public struct AppleIPSWDownloader: IPSWDownloading {
    public init() {}
    public func download(_ release: IPSWRelease, to partial: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        let fm = FileManager.default; try fm.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = ((try? fm.attributesOfItem(atPath: partial.path)[.size]) as? NSNumber)?.int64Value ?? 0
        var request = URLRequest(url: release.downloadURL); if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        let (bytes, rawResponse) = try await URLSession.shared.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse else { throw IPSWServiceError.malformedCatalogue("non-HTTP download response") }
        guard let finalURL = response.url, AppleIPSWCatalogue.isTrustedFirmwareURL(finalURL) else { throw IPSWServiceError.untrustedURL(response.url?.absoluteString ?? "unknown") }
        guard response.statusCode == 200 || response.statusCode == 206 else { throw IPSWServiceError.http(response.statusCode) }
        let resumed = existing > 0 && response.statusCode == 206
        if resumed, response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(existing)-") != true { throw IPSWServiceError.malformedCatalogue("CDN returned an unexpected resume range") }
        if existing > 0 && !resumed { try? fm.removeItem(at: partial) }
        if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: partial); defer { try? handle.close() }
        if resumed { try handle.seekToEnd() } else { try handle.truncate(atOffset: 0) }
        let base = resumed ? existing : 0
        let responseLength = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        let total = release.fileSize ?? responseLength.map { $0 + base }
        var buffer = Data(); buffer.reserveCapacity(1_048_576)
        var received: Int64 = base; var lastBytes: Int64 = received; var lastDate = Date()
        for try await byte in bytes {
            try Task.checkCancellation(); buffer.append(byte)
            if buffer.count >= 1_048_576 {
                try handle.write(contentsOf: buffer); received += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                let now = Date(), elapsed = now.timeIntervalSince(lastDate)
                if elapsed >= 0.25 { progress(DownloadProgress(received: received, total: total, bytesPerSecond: Double(Int64(received - lastBytes)) / elapsed, resumed: resumed)); lastDate = now; lastBytes = received }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); received += Int64(buffer.count) }
        progress(DownloadProgress(received: received, total: total, bytesPerSecond: 0, resumed: resumed))
    }
}
