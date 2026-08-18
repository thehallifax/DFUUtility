import Foundation

public protocol OperationLogging: Sendable {
    func start(operation: String, target: DFUDevice?, release: IPSWRelease?) throws -> URL
    func append(_ message: String, to url: URL) throws
}

public final class OperationLogger: @unchecked Sendable, OperationLogging {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DFUUtility", isDirectory: true)) {
        self.directory = directory
    }

    public func start(operation: String, target: DFUDevice?, release: IPSWRelease?) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        let safeDate = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("\(safeDate)-\(operation.lowercased()).log")
        let header = "Timestamp: \(formatter.string(from: Date()))\nOperation: \(operation)\nTarget model: \(target?.model ?? "Unknown")\nTarget ECID: \(target?.ecid ?? "Unknown")\nIPSW: \(release.map { "macOS \($0.version) (\($0.build))" } ?? "Not applicable")\n\n"
        try Data(redact(header).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    public func append(_ message: String, to url: URL) throws {
        try lock.withLock {
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: Data("[\(ISO8601DateFormatter().string(from: Date()))] \(redact(message))\n".utf8))
        }
    }

    public func redact(_ text: String) -> String {
        var result = text
        for pattern in [#"(?i)(password\s*[:=]\s*)\S+"#, #"(?i)(authorization(?:token|externalform)?\s*[:=]\s*)\S+"#] {
            result = result.replacingOccurrences(of: pattern, with: "$1<redacted>", options: .regularExpression)
        }
        return result
    }
}
