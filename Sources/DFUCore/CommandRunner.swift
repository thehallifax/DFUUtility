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
    func runInteractive(_ executable: URL, arguments: [String]) throws -> CommandResult
}

public extension CommandRunning {
    func runStreaming(_ executable: URL, arguments: [String]) throws -> CommandResult {
        let result = try run(executable, arguments: arguments)
        if !result.stdout.isEmpty { FileHandle.standardOutput.write(result.stdout) }
        if !result.stderr.isEmpty { FileHandle.standardError.write(result.stderr) }
        return result
    }

    func runInteractive(_ executable: URL, arguments: [String]) throws -> CommandResult {
        try runStreaming(executable, arguments: arguments)
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

    public func runInteractive(_ executable: URL, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Explicitly preserve the caller's controlling terminal. In particular,
        // sudo must own terminal echo and authentication; DFUUtility never reads stdin.
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        let terminal = STDIN_FILENO
        let parentProcessGroup = getpgrp()
        let childProcessGroup = getpgid(process.processIdentifier)
        let hasTerminal = isatty(terminal) == 1 && childProcessGroup > 0
        if hasTerminal {
            // Foundation Process creates a new process group. Make it the TTY's
            // foreground group so sudo can read /dev/tty and manage echo.
            let previous = signal(SIGTTOU, SIG_IGN)
            _ = tcsetpgrp(terminal, childProcessGroup)
            _ = kill(-childProcessGroup, SIGCONT)
            _ = signal(SIGTTOU, previous)
        }
        process.waitUntilExit()
        if hasTerminal {
            let previous = signal(SIGTTOU, SIG_IGN)
            _ = tcsetpgrp(terminal, parentProcessGroup)
            _ = signal(SIGTTOU, previous)
        }
        return CommandResult(status: process.terminationStatus, stdout: Data(), stderr: Data())
    }
}

public enum ToolSource: Equatable, Sendable {
    case bundled
    case developmentOverride
    case projectBuild
    case external(String)

    public var displayName: String {
        switch self { case .bundled: "Bundled"; case .developmentOverride: "Development override"; case .projectBuild: "Project build"; case .external(let path): path }
    }
    public var category: String { if case .external = self { return "External" }; return displayName }
}

public struct ToolResolution: Equatable, Sendable { public let url: URL; public let source: ToolSource; public init(url: URL, source: ToolSource) { self.url = url; self.source = source } }

public enum ToolLocator {
    public static func macVDMTool(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL? = Bundle.main.bundleURL,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        executableURL: URL? = Bundle.main.executableURL,
        externalCandidates: [String] = ["/opt/homebrew/bin/macvdmtool", "/usr/local/bin/macvdmtool"]
    ) -> ToolResolution? {
        let fm = FileManager.default
        let bundled = bundleURL?.pathExtension == "app" ? bundleResourceURL?.appendingPathComponent("macvdmtool") : nil
        var candidates: [(URL?, ToolSource)] = [
            (bundled, .bundled),
            (environment["DFUCTL_MACVDMTOOL_PATH"].map { URL(fileURLWithPath: $0) }, .developmentOverride),
            (executableURL?.deletingLastPathComponent().appendingPathComponent("macvdmtool"), .projectBuild),
        ]
        candidates += externalCandidates.map { (URL(fileURLWithPath: $0), .external(URL(fileURLWithPath: $0).deletingLastPathComponent().path)) }
        for (url, source) in candidates { if let url, fm.isExecutableFile(atPath: url.path) { return ToolResolution(url: url, source: source) } }
        return nil
    }

    public static func executable(named name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if name == "macvdmtool" { return macVDMTool(environment: environment)?.url }
        let fm = FileManager.default
        let override = environment["DFUCTL_\(name.uppercased())_PATH"]
        let candidates = [override, "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)",
            name == "cfgutil" ? "/Applications/Apple Configurator.app/Contents/MacOS/cfgutil" : nil
        ].compactMap { $0 }
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }
}
