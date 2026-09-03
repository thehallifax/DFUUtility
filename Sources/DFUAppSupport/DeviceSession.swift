import Combine
import DFUCore
import Foundation

public struct DeviceSessionID: Hashable, Sendable, CustomStringConvertible {
    public let value: String
    public init(_ value: String) { self.value = value }
    public var description: String { value }
}

public enum SessionFirmwareState: Equatable, Sendable {
    case unselected
    case selected
    case validated
    case incompatible(String)
    case invalid(String)
}

public enum SessionOperationState: Equatable, Sendable {
    case idle
    case queued(position: Int, total: Int)
    case running(stage: String, fraction: Double?)
    case reconnecting
    case completed(String)
    case failed(String)
    case cancelled
}

public struct DeviceSession: Identifiable, Equatable, Sendable {
    public let id: DeviceSessionID
    public var device: DFUDevice
    public var isConnected: Bool
    public var isSelected: Bool
    public var selectedRelease: IPSWRelease?
    public var selectedImageURL: URL?
    public var firmwareState: SessionFirmwareState
    public var operationState: SessionOperationState
    public var operationLogURL: URL?
    public var generation: UInt64

    public init(id: DeviceSessionID, device: DFUDevice, isConnected: Bool = true, isSelected: Bool = false, selectedRelease: IPSWRelease? = nil, selectedImageURL: URL? = nil, firmwareState: SessionFirmwareState = .unselected, operationState: SessionOperationState = .idle, operationLogURL: URL? = nil, generation: UInt64 = 0) {
        self.id = id; self.device = device; self.isConnected = isConnected; self.isSelected = isSelected
        self.selectedRelease = selectedRelease; self.selectedImageURL = selectedImageURL; self.firmwareState = firmwareState
        self.operationState = operationState; self.operationLogURL = operationLogURL; self.generation = generation
    }

    public var ecid: String? { device.ecid?.isEmpty == false ? device.ecid : nil }
    public var hasSafeBatchIdentity: Bool { ecid != nil }
    public var restoreEligibilityFailure: String? {
        guard isConnected else { return "Device is disconnected." }
        guard hasSafeBatchIdentity else { return "A stable ECID is required for a multi-device operation." }
        guard RestoreTargetStatePolicy.allowsRestore(device) else {
            return device.family == .iPhone || device.family == .iPad
                ? "Restore requires Recovery or DFU mode."
                : "Restore requires DFU mode."
        }
        switch firmwareState {
        case .unselected: return "No firmware is assigned to this device."
        case .selected: return "The assigned firmware has not been downloaded and validated."
        case .incompatible(let reason), .invalid(let reason): return reason
        case .validated: break
        }
        guard selectedImageURL != nil else { return "The validated firmware file is unavailable." }
        return nil
    }
    public var canRestore: Bool { restoreEligibilityFailure == nil }
    public var reviveEligibilityFailure: String? {
        guard isConnected else { return "Device is disconnected." }
        guard hasSafeBatchIdentity else { return "A stable ECID is required for a multi-device operation." }
        let valid = device.family == .mac ? (device.state == .dfu || device.state == .recovery) : device.state == .recovery
        return valid ? nil : "Revive is not available in the current device state."
    }
    public var restartEligibilityFailure: String? {
        guard isConnected else { return "Device is disconnected." }
        guard hasSafeBatchIdentity else { return "A stable ECID is required for a multi-device operation." }
        return nil
    }
    public var shortIdentity: String {
        guard let value = ecid ?? device.identifier ?? device.serialNumber else { return "Identity unavailable" }
        return value.count > 8 ? "…" + value.suffix(8) : value
    }

    public var shortECID: String? { Self.privateSuffix(ecid) }
    public var shortSerial: String? { Self.privateSuffix(device.serialNumber) }

    private static func privateSuffix(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value.count > 4 ? "…" + value.suffix(4) : value
    }
}

public enum BatchMembershipPresentation: Equatable, Sendable {
    case none
    case active
    case queued
    case currentBatch
    case notInCurrentBatch
}

public struct DeviceSessionPresentation: Equatable, Sendable {
    public let firmware: String?
    public let firmwareReadiness: String?
    public let capability: String
    public let identity: String?
    public let batchMembership: BatchMembershipPresentation

    public init(session: DeviceSession, activeBatchIDs: [DeviceSessionID], currentBatchID: DeviceSessionID?, batchIsRunning: Bool) {
        firmware = session.selectedRelease.map { "\($0.platform.displayName) \($0.version) (\($0.build))" }
        firmwareReadiness = switch session.firmwareState {
        case .validated: "Validated"
        case .selected: "Not downloaded"
        case .incompatible: "Incompatible"
        case .invalid: "Invalid"
        case .unselected: nil
        }
        let identities = [("ECID", session.shortECID), ("Serial", session.shortSerial)].compactMap { label, value in value.map { "\(label) \($0)" } }
        identity = identities.isEmpty ? nil : identities.joined(separator: " · ")
        if batchIsRunning {
            if currentBatchID == session.id { batchMembership = .currentBatch }
            else if activeBatchIDs.contains(session.id) {
                if case .queued = session.operationState { batchMembership = .queued } else { batchMembership = .active }
            } else { batchMembership = .notInCurrentBatch }
        } else { batchMembership = .none }
        capability = Self.capabilityText(session)
    }

    private static func capabilityText(_ session: DeviceSession) -> String {
        switch session.operationState {
        case .idle:
            if session.canRestore { return "Ready to Restore" }
            if session.reviveEligibilityFailure == nil { return "Revive available · \(session.restoreEligibilityFailure ?? "Restore unavailable")" }
            return session.restoreEligibilityFailure ?? "Not ready"
        case .queued(let position, let total): return "Queued — device \(position) of \(total)"
        case .running(let stage, let fraction): return fraction.map { "\(stage) — \(Int($0 * 100))%" } ?? stage
        case .reconnecting: return "Waiting for restart…"
        case .completed(let result): return "✓ \(result)"
        case .failed(let result): return "✗ \(result)"
        case .cancelled: return "Not Started — batch stopped"
        }
    }
}

public struct SessionWorkspaceSummary: Equatable, Sendable {
    public let connected: Int
    public let restoreReady: Int
    public let selected: Int
    public init(sessions: [DeviceSession]) {
        connected = sessions.filter(\.isConnected).count
        restoreReady = sessions.filter { $0.isConnected && $0.canRestore }.count
        selected = sessions.filter(\.isSelected).count
    }
}

public struct RestorePreflightPresentation: Equatable, Sendable {
    public let selected: Int
    public let connected: Int
    public let excluded: Int
    public let hasMixedFamilies: Bool
    public init(sessions: [DeviceSession]) {
        let chosen = sessions.filter(\.isSelected)
        selected = chosen.count
        connected = sessions.filter(\.isConnected).count
        excluded = sessions.filter { $0.isConnected && !$0.isSelected }.count
        hasMixedFamilies = Set(chosen.map(\.device.family)).count > 1
    }
}

@MainActor
public final class DeviceSessionManager: ObservableObject {
    @Published public private(set) var sessions: [DeviceSession] = []
    @Published public private(set) var activeBatchIDs: [DeviceSessionID] = []
    private var activeBatchFirmwareBySession: [DeviceSessionID: URL] = [:]

    public init() {}

    public func reconcile(_ devices: [DFUDevice], preservingDeviceStateFor protectedIDs: Set<DeviceSessionID> = []) {
        var unmatched = sessions
        var updated: [DeviceSession] = []
        for device in devices {
            if let index = unmatched.firstIndex(where: { Self.matches($0.device, device) }) {
                var session = unmatched.remove(at: index)
                if !protectedIDs.contains(session.id) {
                    session.device = Self.merge(device, with: session.device)
                    session.isConnected = true
                }
                updated.append(session)
            } else {
                updated.append(DeviceSession(id: Self.identity(for: device), device: device))
            }
        }
        for var session in unmatched where activeBatchIDs.contains(session.id) || protectedIDs.contains(session.id) {
            if !protectedIDs.contains(session.id) { session.isConnected = false }
            updated.append(session)
        }
        sessions = updated.sorted { $0.id.value < $1.id.value }
    }

    public func select(_ id: DeviceSessionID, selected: Bool) {
        update(id) { $0.isSelected = selected }
    }
    public func clearSelection() { mutateAll { $0.isSelected = false } }
    public func selectAllRestoreEligible() { mutateAll { $0.isSelected = $0.canRestore } }
    public func selectFailed(for kind: BatchOperationKind?) {
        mutateAll { session in
            guard case .failed = session.operationState else { session.isSelected = false; return }
            session.isSelected = session.isConnected && Self.isEligible(session, for: kind)
        }
    }
    public func selectNotStarted(for kind: BatchOperationKind?) {
        mutateAll { session in
            guard case .cancelled = session.operationState else { session.isSelected = false; return }
            session.isSelected = session.isConnected && Self.isEligible(session, for: kind)
        }
    }
    public func hasFailedCandidate(for kind: BatchOperationKind?) -> Bool {
        sessions.contains { session in
            if case .failed = session.operationState { return session.isConnected && Self.isEligible(session, for: kind) }
            return false
        }
    }
    public func hasNotStartedCandidate(for kind: BatchOperationKind?) -> Bool {
        sessions.contains { session in
            session.operationState == .cancelled && session.isConnected && Self.isEligible(session, for: kind)
        }
    }
    public var selectedSessions: [DeviceSession] { sessions.filter(\.isSelected) }

    public func setFirmware(for id: DeviceSessionID, release: IPSWRelease?, url: URL?, validation: SessionFirmwareState) {
        update(id) { session in
            session.selectedRelease = release; session.selectedImageURL = url; session.firmwareState = validation
        }
    }

    public func applySharedFirmware(release: IPSWRelease?, url: URL?, to ids: Set<DeviceSessionID>) {
        mutateAll { session in
            guard ids.contains(session.id) else { return }
            guard let product = session.device.restoreProductType, let release, release.supportedDevices.contains(product) else {
                session.selectedRelease = nil; session.selectedImageURL = nil
                session.firmwareState = .incompatible("The selected IPSW is not compatible with \(session.device.restoreProductType ?? "this product").")
                return
            }
            session.selectedRelease = release; session.selectedImageURL = url
            session.firmwareState = url == nil ? .selected : .validated
        }
    }

    public func freezeSelectedBatch() -> [DeviceSession] {
        let frozen = selectedSessions
        activeBatchIDs = frozen.map(\.id)
        activeBatchFirmwareBySession = Dictionary(uniqueKeysWithValues: frozen.compactMap { session in
            session.selectedImageURL.map { (session.id, $0.standardizedFileURL) }
        })
        return frozen
    }
    public func finishBatchWork(for id: DeviceSessionID) {
        activeBatchFirmwareBySession[id] = nil
    }
    public func isFirmwareInUseByBatch(_ url: URL) -> Bool {
        activeBatchFirmwareBySession.values.contains(url.standardizedFileURL)
    }
    public func finishBatch() {
        activeBatchIDs = []
        activeBatchFirmwareBySession = [:]
    }

    public func update(_ id: DeviceSessionID, _ change: (inout DeviceSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[index])
    }
    @discardableResult public func update(_ id: DeviceSessionID, generation: UInt64, _ change: (inout DeviceSession) -> Void) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].generation == generation else { return false }
        change(&sessions[index]); return true
    }

    public func configureDemo() {
        let macImage = URL(fileURLWithPath: "/demo/cache/macOS.ipsw"), phoneImage = URL(fileURLWithPath: "/demo/cache/iOS.ipsw")
        sessions = [
            DeviceSession(id: .init("ecid:demo-mac"), device: DFUDevice(family: .mac, state: .dfu, ecid: "DEMO-MAC-0001", productType: "Mac14,2"), isSelected: true, selectedImageURL: macImage, firmwareState: .validated),
            DeviceSession(id: .init("ecid:demo-phone"), device: DFUDevice(family: .iPhone, state: .recovery, ecid: "DEMO-PHONE-0002", productType: "iPhone15,2"), isSelected: true, selectedImageURL: phoneImage, firmwareState: .validated),
            DeviceSession(id: .init("ecid:demo-pad"), device: DFUDevice(family: .iPad, state: .recovery, ecid: "DEMO-PAD-0003", productType: "iPad13,18"), firmwareState: .unselected),
            DeviceSession(id: .init("ecid:demo-not-ready"), device: DFUDevice(family: .mac, state: .recovery, ecid: "DEMO-MAC-0004", productType: "Mac15,3"), firmwareState: .incompatible("Mac Restore requires DFU mode."))
        ]
    }

    private func mutateAll(_ change: (inout DeviceSession) -> Void) {
        for index in sessions.indices { change(&sessions[index]) }
    }
    private static func isEligible(_ session: DeviceSession, for kind: BatchOperationKind?) -> Bool {
        switch kind {
        case .restore: session.restoreEligibilityFailure == nil
        case .revive: session.reviveEligibilityFailure == nil
        case .restart: session.restartEligibilityFailure == nil
        case nil: false
        }
    }
    private static func identity(for device: DFUDevice) -> DeviceSessionID {
        if let ecid = normalized(device.ecid) { return .init("ecid:\(ecid)") }
        if let udid = normalized(device.identifier) { return .init("udid:\(udid)") }
        if let serial = normalized(device.serialNumber) { return .init("serial:\(serial)") }
        // Unaddressable devices intentionally get a new identity after discovery;
        // this prevents firmware/progress state moving to a different physical device.
        return .init("ephemeral:\(UUID().uuidString.lowercased())")
    }
    private static func matches(_ lhs: DFUDevice, _ rhs: DFUDevice) -> Bool {
        if let left = normalized(lhs.ecid), let right = normalized(rhs.ecid) { return left == right }
        if let left = normalized(lhs.identifier), let right = normalized(rhs.identifier) { return left == right }
        if let left = normalized(lhs.serialNumber), let right = normalized(rhs.serialNumber) { return left == right }
        return false
    }
    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value.lowercased()
    }
    private static func merge(_ fresh: DFUDevice, with prior: DFUDevice) -> DFUDevice {
        DFUDevice(family: fresh.family == .unknown ? prior.family : fresh.family, state: fresh.state, model: fresh.model ?? prior.model, identifier: fresh.identifier ?? prior.identifier, ecid: fresh.ecid ?? prior.ecid, productType: fresh.productType ?? prior.productType, modelIdentifier: fresh.modelIdentifier ?? prior.modelIdentifier, serialNumber: fresh.serialNumber ?? prior.serialNumber)
    }
}

public struct BatchSummary: Equatable, Sendable {
    public let total: Int
    public let succeeded: Int
    public let failed: Int
    public let cancelled: Int
    public init(total: Int, succeeded: Int, failed: Int, cancelled: Int) {
        self.total = total; self.succeeded = succeeded; self.failed = failed; self.cancelled = cancelled
    }
}

public enum BatchOperationKind: String, Equatable, Sendable { case restore = "Restore", revive = "Revive", restart = "Restart" }

public protocol BatchTargetOperating: Sendable {
    func events(for action: RestoreAction) -> AsyncThrowingStream<RestoreEvent, Error>
    func reconnect(expectedECID: String?) async -> ReconnectResult
}

public struct DefaultBatchTargetOperator: BatchTargetOperating {
    private let restore: any RestoreOperating
    private let discovery: any DeviceDiscovering
    private let reconnectAttempts: Int
    private let reconnectInterval: Duration
    public init(restore: any RestoreOperating, discovery: any DeviceDiscovering, reconnectAttempts: Int = 10, reconnectInterval: Duration = .seconds(2)) {
        self.restore = restore; self.discovery = discovery; self.reconnectAttempts = reconnectAttempts; self.reconnectInterval = reconnectInterval
    }
    public func events(for action: RestoreAction) -> AsyncThrowingStream<RestoreEvent, Error> { restore.events(for: action) }
    public func reconnect(expectedECID: String?) async -> ReconnectResult { await ReconnectVerifier(discovery: discovery).wait(expectedECID: expectedECID, attempts: reconnectAttempts, interval: reconnectInterval) }
}

@MainActor
public final class BatchCoordinator: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var currentIndex: Int?
    @Published public private(set) var summary: BatchSummary?
    @Published public private(set) var operationKind: BatchOperationKind?
    @Published public private(set) var stopRequested = false
    private let sessions: DeviceSessionManager
    private let operatorService: any BatchTargetOperating
    private let logger: any OperationLogging
    private var task: Task<Void, Never>?

    public init(sessions: DeviceSessionManager, operatorService: any BatchTargetOperating, logger: any OperationLogging) {
        self.sessions = sessions; self.operatorService = operatorService; self.logger = logger
    }

    public var frozenTargetIDs: [DeviceSessionID] { sessions.activeBatchIDs }
    public var currentTargetID: DeviceSessionID? {
        guard let currentIndex, frozenTargetIDs.indices.contains(currentIndex) else { return nil }
        return frozenTargetIDs[currentIndex]
    }
    public func selectedEligibilityFailures(for kind: BatchOperationKind) -> [String] {
        sessions.selectedSessions.compactMap { session in
            switch kind { case .restore: session.restoreEligibilityFailure; case .revive: session.reviveEligibilityFailure; case .restart: session.restartEligibilityFailure }
        }
    }
    public func canStart(_ kind: BatchOperationKind) -> Bool { !isRunning && !sessions.selectedSessions.isEmpty && selectedEligibilityFailures(for: kind).isEmpty }
    public var canStartRestore: Bool { canStart(.restore) }
    public var overallFraction: Double {
        guard isRunning, let currentIndex, !frozenTargetIDs.isEmpty else { return summary == nil ? 0 : 1 }
        let local: Double = sessions.sessions.first(where: { $0.id == frozenTargetIDs[currentIndex] }).flatMap {
            if case .running(_, let fraction) = $0.operationState { return fraction }
            return nil
        } ?? 0
        // This is target-count progress with the current stage-local fraction as
        // a visual hint; it is not presented as linear restore-byte completion.
        return min(1, (Double(currentIndex) + local) / Double(frozenTargetIDs.count))
    }

    public func startRestore() {
        start(.restore)
    }
    public func start(_ kind: BatchOperationKind) {
        guard canStart(kind) else { return }
        let frozen = sessions.freezeSelectedBatch()
        isRunning = true; stopRequested = false; summary = nil; operationKind = kind
        for (index, session) in frozen.enumerated() { sessions.update(session.id) { $0.operationState = .queued(position: index + 1, total: frozen.count) } }
        task = Task { [weak self] in await self?.run(frozen, kind: kind) }
    }

    public func stopAfterCurrentTarget() { guard isRunning else { return }; stopRequested = true }

    private func run(_ frozen: [DeviceSession], kind: BatchOperationKind) async {
        var succeeded = 0, failed = 0, cancelled = 0
        for (index, snapshot) in frozen.enumerated() {
            if stopRequested {
                for remaining in frozen[index...] {
                    sessions.update(remaining.id) { $0.operationState = .cancelled }
                    sessions.finishBatchWork(for: remaining.id)
                    cancelled += 1
                }
                break
            }
            currentIndex = index
            guard let current = sessions.sessions.first(where: { $0.id == snapshot.id }), current.isConnected else {
                sessions.update(snapshot.id) { $0.operationState = .failed("Device disconnected before its queued operation began.") }
                sessions.finishBatchWork(for: snapshot.id); failed += 1; continue
            }
            let currentFailure: String? = switch kind {
            case .restore: current.restoreEligibilityFailure
            case .revive: current.reviveEligibilityFailure
            case .restart: current.restartEligibilityFailure
            }
            if let currentFailure { sessions.update(snapshot.id) { $0.operationState = .failed(currentFailure) }; sessions.finishBatchWork(for: snapshot.id); failed += 1; continue }
            guard let ecid = snapshot.ecid else { sessions.update(snapshot.id) { $0.operationState = .failed("Target identity became unavailable.") }; sessions.finishBatchWork(for: snapshot.id); failed += 1; continue }
            if kind == .restore, snapshot.selectedImageURL == nil { sessions.update(snapshot.id) { $0.operationState = .failed("The validated IPSW became unavailable.") }; sessions.finishBatchWork(for: snapshot.id); failed += 1; continue }
            let generation = snapshot.generation &+ 1
            let log = try? logger.start(operation: "Batch \(kind.rawValue)", target: snapshot.device, release: snapshot.selectedRelease)
            sessions.update(snapshot.id) { $0.generation = generation; $0.operationLogURL = log; $0.operationState = .running(stage: "Preparing", fraction: nil) }
            do {
                let action: RestoreAction = switch kind {
                case .restore: .targetedRestore(snapshot.selectedImageURL!, ecid: ecid)
                case .revive: .targetedRevive(ecid: ecid)
                case .restart: .targetedReboot(ecid: ecid)
                }
                for try await event in operatorService.events(for: action) {
                    guard sessions.sessions.first(where: { $0.id == snapshot.id })?.generation == generation else { continue }
                    if let log { try? logger.append(String(describing: event), to: log) }
                    apply(event, to: snapshot.id)
                }
                sessions.update(snapshot.id) { $0.operationState = .reconnecting }
                let reconnect = await operatorService.reconnect(expectedECID: ecid)
                guard sessions.sessions.first(where: { $0.id == snapshot.id })?.generation == generation else { continue }
                switch reconnect {
                case .restarted(let device):
                    guard device.ecid?.caseInsensitiveCompare(ecid) == .orderedSame else { throw DFUError.targetChanged(expected: ecid, actual: device.ecid) }
                    sessions.update(snapshot.id) { $0.device = device; $0.isConnected = true; $0.operationState = .completed("\(kind.rawValue) complete; target restarted.") }
                case .unverified: sessions.update(snapshot.id) { $0.operationState = .completed("\(kind.rawValue) complete; restart could not be verified.") }
                }
                succeeded += 1
            } catch {
                sessions.update(snapshot.id) { $0.operationState = .failed(error.localizedDescription) }
                if let log { try? logger.append("FAILED: \(error.localizedDescription)", to: log) }
                failed += 1
            }
            sessions.finishBatchWork(for: snapshot.id)
        }
        summary = BatchSummary(total: frozen.count, succeeded: succeeded, failed: failed, cancelled: cancelled)
        currentIndex = nil; isRunning = false; sessions.finishBatch(); task = nil
    }

    private func apply(_ event: RestoreEvent, to id: DeviceSessionID) {
        sessions.update(id) { session in
            switch event {
            case .preparing: session.operationState = .running(stage: "Preparing", fraction: nil)
            case .waitingForDevice: session.operationState = .running(stage: "Waiting for the device", fraction: nil)
            case .stageStarted(let name, _, _): session.operationState = .running(stage: name, fraction: nil)
            case .progress(let stage, let fraction): session.operationState = .running(stage: stage, fraction: min(max(fraction, 0), 1))
            case .stageCompleted(let name): session.operationState = .running(stage: name, fraction: 1)
            case .reconnecting: session.operationState = .reconnecting
            case .failed(let message): session.operationState = .failed(message)
            case .completed, .message: break
            }
        }
    }
}
