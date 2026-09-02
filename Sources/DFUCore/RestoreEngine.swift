import Foundation

public enum RestoreAction: Sendable, Equatable {
    case restore(URL), targetedRestore(URL, ecid: String), revive, targetedRevive(ecid: String), reboot, targetedReboot(ecid: String)

    public var operationName: String {
        switch self { case .restore, .targetedRestore: "Restore"; case .revive, .targetedRevive: "Revive"; case .reboot, .targetedReboot: "Restart" }
    }
}

public enum RestoreTargetStatePolicy {
    public static func allowsRestore(_ target: DFUDevice) -> Bool {
        switch target.family {
        case .iPhone, .iPad: target.state == .recovery || target.state == .dfu
        case .mac, .unknown: target.state == .dfu
        }
    }

    public static func validateRestore(_ target: DFUDevice) throws {
        guard !allowsRestore(target) else { return }
        if target.family == .iPhone || target.family == .iPad {
            throw DFUError.invalidTargetState(operation: "Restore", target: target.family.displayName, allowedStates: [DeviceState.recovery.rawValue, DeviceState.dfu.rawValue])
        }
        throw DFUError.targetNotInDFU
    }
}

public enum RestoreEvent: Sendable, Equatable {
    case preparing
    case waitingForDevice
    case stageStarted(name: String, index: Int?, total: Int?)
    case progress(stage: String, fraction: Double)
    case stageCompleted(name: String)
    case message(String)
    case reconnecting
    case completed
    case failed(String)
}

/// Parses cfgutil's newline-delimited plist-like progress dictionaries. Progress is
/// stage-local: a new Step resets the active stage, and the cfgutil `-1` sentinel
/// is ignored rather than rendered as a negative percentage.
public struct CFGUtilEventParser: Sendable {
    private var buffer = ""
    private var pendingRecord = ""
    private var currentStage: String?

    public init() {}

    public mutating func consume(_ data: Data, final: Bool = false) -> [RestoreEvent] {
        buffer += String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var events: [RestoreEvent] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            events += consumeCompleteLine(line)
        }
        if final {
            if !buffer.isEmpty { events += consumeCompleteLine(buffer); buffer = "" }
            events += flushPendingRecord()
        }
        return events
    }

    private mutating func consumeCompleteLine(_ line: String) -> [RestoreEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return flushPendingRecord() }
        if pendingRecord.isEmpty, trimmed.hasPrefix("cfgutil:") { return parse(trimmed) }
        pendingRecord += pendingRecord.isEmpty ? line : "\n" + line

        let record = pendingRecord.trimmingCharacters(in: .whitespacesAndNewlines)
        if record.hasPrefix("{") {
            return trimmed == "}" ? flushPendingRecord() : []
        }
        // cfgutil's live stream does not consistently place a blank line between
        // dictionaries. `Type` is the final key in its unbraced progress record,
        // so its completed assignment is also a safe incremental boundary.
        if trimmed.range(of: #"^Type\s*=.*;\s*$"#, options: .regularExpression) != nil {
            return flushPendingRecord()
        }
        return []
    }

    private mutating func flushPendingRecord() -> [RestoreEvent] {
        guard !pendingRecord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { pendingRecord = ""; return [] }
        let record = pendingRecord
        pendingRecord = ""
        return parse(record)
    }

    private mutating func parse(_ block: String) -> [RestoreEvent] {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let type = value(named: "Type", in: trimmed)
        let step = value(named: "Step", in: trimmed)
        switch type {
        case "Step":
            guard let step else { return [.message(trimmed)] }
            currentStage = step
            if step.localizedCaseInsensitiveContains("Waiting for the device") { return [.waitingForDevice] }
            let parts = Self.stageNumbers(in: step)
            return [.stageStarted(name: Self.cleanStageName(step), index: parts?.0, total: parts?.1)]
        case "Progress":
            guard let raw = value(named: "Progress", in: trimmed), let numeric = Double(raw), numeric >= 0 else { return [] }
            let stage = step.map(Self.cleanStageName) ?? currentStage.map(Self.cleanStageName) ?? "Working"
            return [.progress(stage: stage, fraction: min(max(numeric, 0), 1))]
        case "StepComplete":
            let stage = step ?? currentStage
            return stage.map { [.stageCompleted(name: Self.cleanStageName($0))] } ?? []
        default:
            if trimmed.contains("Operation \"") && trimmed.contains("succeeded") { return [] }
            return [.message(trimmed)]
        }
    }

    private func value(named key: String, in block: String) -> String? {
        for line in block.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("\(key) =") else { continue }
            var value = text.dropFirst(key.count + 2).trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") { value.removeLast() }
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    private static func stageNumbers(in stage: String) -> (Int, Int)? {
        let pattern = #"Step\s+(\d+)\s+of\s+(\d+):"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: stage, range: NSRange(stage.startIndex..., in: stage)),
              let first = Range(match.range(at: 1), in: stage), let second = Range(match.range(at: 2), in: stage),
              let index = Int(stage[first]), let total = Int(stage[second]) else { return nil }
        return (index, total)
    }

    private static func cleanStageName(_ stage: String) -> String {
        stage.replacingOccurrences(of: #"^Step\s+\d+\s+of\s+\d+:\s*"#, with: "", options: .regularExpression)
    }
}

private final class ParserBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = CFGUtilEventParser()
    func consume(_ data: Data, final: Bool = false) -> [RestoreEvent] { lock.withLock { parser.consume(data, final: final) } }
}

public struct RestoreEngine: Sendable {
    private let discovery: any DeviceDiscovering
    private let runner: any CommandRunning
    private let cfgutil: URL?

    public init(discovery: any DeviceDiscovering = ConfiguratorDeviceDiscovery(), runner: any CommandRunning = ProcessRunner(), cfgutil: URL? = ToolLocator.executable(named: "cfgutil")) {
        self.discovery = discovery; self.runner = runner; self.cfgutil = cfgutil
    }

    public func validateIPSW(_ url: URL) throws {
        guard url.pathExtension.lowercased() == "ipsw" else { throw DFUError.invalidIPSW("expected a .ipsw file") }
        try IPSWValidator(runner: runner).validate(url, release: nil, verifyChecksum: false)
    }

    public func command(for action: RestoreAction) throws -> (URL, [String], DFUDevice) {
        guard let cfgutil else { throw DFUError.toolUnavailable("cfgutil (install Apple Configurator Automation Tools)") }
        let restoreURL: URL? = switch action { case .restore(let url), .targetedRestore(let url, _): url; default: nil }
        if let restoreURL { try validateIPSW(restoreURL) }
        let devices = try discovery.devices()
        guard !devices.isEmpty else { throw DFUError.noTarget }
        let requestedECID: String? = switch action { case .targetedRestore(_, let ecid), .targetedRevive(let ecid), .targetedReboot(let ecid): ecid; default: nil }
        let candidates = requestedECID.map { wanted in devices.filter { $0.ecid == wanted } } ?? devices
        guard candidates.count == 1 else { throw DFUError.multipleTargets(devices.count) }
        let target = candidates[0]
        if let restoreURL, (target.family == .iPhone || target.family == .iPad) {
            guard let product = target.restoreProductType else { throw DFUError.invalidIPSW("the selected mobile target does not expose a product type") }
            let platform: RestorePlatform = target.family == .iPhone ? .iOS : .iPadOS
            let compatibility = IPSWRelease(platform: platform, version: "Local", build: "Local", downloadURL: restoreURL, supportedDevices: [product])
            try IPSWValidator(runner: runner).validate(restoreURL, release: compatibility, verifyChecksum: false)
        }
        switch action {
        case .restore, .targetedRestore:
            try RestoreTargetStatePolicy.validateRestore(target)
        case .revive, .targetedRevive:
            let valid = target.family == .mac ? (target.state == .dfu || target.state == .recovery) : target.state == .recovery
            guard valid else { throw DFUError.targetNotInDFU }
        case .reboot, .targetedReboot: break
        }
        var arguments = ["--progress", "--verbose", "--timeout", "30"]
        if let ecid = target.ecid, !ecid.isEmpty { arguments += ["--ecid", ecid] }
        switch action { case .restore(let url), .targetedRestore(let url, _): arguments += ["restore", "--ipsw", url.path]; case .revive, .targetedRevive: arguments += ["revive"]; case .reboot, .targetedReboot: arguments += ["restart"] }
        return (cfgutil, arguments, target)
    }

    public func perform(_ action: RestoreAction) throws {
        let (tool, arguments, _) = try command(for: action)
        let result = try runner.runStreaming(tool, arguments: arguments)
        guard result.status == 0 else { throw DFUError.commandFailed(command: "cfgutil \(arguments.joined(separator: " "))", status: result.status, output: result.combinedOutput) }
    }

    public func events(for action: RestoreAction) -> AsyncThrowingStream<RestoreEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                continuation.yield(.preparing)
                do {
                    let (tool, arguments, _) = try command(for: action)
                    let parser = ParserBox()
                    let result = try runner.runStreaming(tool, arguments: arguments) { data in
                        for event in parser.consume(data) { continuation.yield(event) }
                    }
                    for event in parser.consume(Data(), final: true) { continuation.yield(event) }
                    guard result.status == 0 else {
                        let error = DFUError.commandFailed(command: "cfgutil \(arguments.joined(separator: " "))", status: result.status, output: result.combinedOutput)
                        continuation.yield(.failed(error.localizedDescription)); throw error
                    }
                    continuation.yield(.completed); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
