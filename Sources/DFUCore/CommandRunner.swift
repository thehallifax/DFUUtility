import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    public var combinedOutput: String { stdoutString + stderrString }
}

public protocol CommandRunning: Sendable {
    func run(_ executable: URL, arguments: [String]) throws -> CommandResult
    func runStreaming(_ executable: URL, arguments: [String]) throws -> CommandResult
}

public extension CommandRunning {
    func runStreaming(_ executable: URL, arguments: [String]) throws -> CommandResult {
        let result = try run(executable, arguments: arguments)
        if !result.stdout.isEmpty { FileHandle.standardOutput.write(result.stdout) }
        if !result.stderr.isEmpty { FileHandle.standardError.write(result.stderr) }
        return result
    }
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ executable: URL, arguments: [String]) throws -> CommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, stdout: out, stderr: err)
    }

    public func runStreaming(_ executable: URL, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, stdout: Data(), stderr: Data())
    }
}

public enum ToolLocator {
    public static func executable(named name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fm = FileManager.default
        let override = environment["DFUCTL_\(name.uppercased())_PATH"]
        let candidates = [override,
            "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)",
            name == "cfgutil" ? "/Applications/Apple Configurator.app/Contents/MacOS/cfgutil" : nil
        ].compactMap { $0 }
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }
}
