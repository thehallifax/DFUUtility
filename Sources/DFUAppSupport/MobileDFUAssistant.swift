import Combine
import DFUCore
import Foundation

public enum MobileDFUInstructionFamily: String, Equatable, Sendable { case physicalHome, hapticHome, noHome }

public struct MobileDFUInstructionProfile: Equatable, Sendable {
    public struct Timing: Equatable, Sendable {
        public let postResetBothHold: Duration
        public let homeHoldTimeout: Duration
        public let dfuDetectionTimeout: Duration

        public init(postResetBothHold: Duration, homeHoldTimeout: Duration, dfuDetectionTimeout: Duration) {
            self.postResetBothHold = postResetBothHold
            self.homeHoldTimeout = homeHoldTimeout
            self.dfuDetectionTimeout = dfuDetectionTimeout
        }
    }

    public let family: MobileDFUInstructionFamily
    public let title: String
    public let deviceDescription: String
    public let productType: String
    public let powerButtonName: String
    public let secondaryButtonName: String
    public let releaseButtonName: String
    public let timing: Timing
    public let hardwareValidated: Bool
    public let cableAdvice: String?
    public let cableAdviceRecoveryThreshold: Int
    public var holdButtonsText: String { "\(powerButtonName.uppercased()) + \(secondaryButtonName.uppercased())" }
    public var releaseCueText: String { "RELEASE \(releaseButtonName.uppercased()) NOW" }

    public static func profile(for device: DFUDevice) -> Self? {
        switch (device.family, device.restoreProductType) {
        case (.iPhone, "iPhone7,2"): .iPhone6
        case (.iPad, "iPad7,11"): .iPad7thGeneration
        default: nil
        }
    }

    public static let iPhone6 = Self(
        family: .physicalHome,
        title: "Enter DFU — iPhone 6",
        deviceDescription: "iPhone 6",
        productType: "iPhone7,2",
        powerButtonName: "Side/Power",
        secondaryButtonName: "Home",
        releaseButtonName: "Power",
        timing: Timing(postResetBothHold: .seconds(1), homeHoldTimeout: .seconds(12), dfuDetectionTimeout: .seconds(20)),
        hardwareValidated: true,
        cableAdvice: "On some older Lightning devices, a direct USB-C to Lightning connection may repeatedly enter Recovery instead of DFU. If that happens, try a USB-A to Lightning cable. If your Mac only has USB-C ports, use a USB-A to USB-C adapter or hub.",
        cableAdviceRecoveryThreshold: 2
    )

    public static let iPad7thGeneration = Self(
        family: .physicalHome,
        title: "Enter DFU — iPad (7th generation)",
        deviceDescription: "iPad (7th generation)",
        productType: "iPad7,11",
        powerButtonName: "Top",
        secondaryButtonName: "Home",
        releaseButtonName: "Top",
        timing: Timing(postResetBothHold: .seconds(1), homeHoldTimeout: .seconds(12), dfuDetectionTimeout: .seconds(20)),
        hardwareValidated: true,
        cableAdvice: "This iPad uses Lightning. If repeated attempts enter Recovery, trying USB-A to Lightning through an adapter or hub is a troubleshooting option—not a requirement.",
        cableAdviceRecoveryThreshold: 2
    )
}

public enum MobileDFUAssistantState: Equatable, Sendable {
    case ready
    case waitingForButtonHold
    case waitingForReset
    case postResetHoldBoth
    case releasePowerNow
    case holdingHome
    case waitingForDFU
    case detectedDFU
    case detectedRecovery
    case detectedNormal
    case disconnectedUnexpectedly
    case targetMismatch
    case timedOut
    case cancelled

    public var description: String {
        switch self {
        case .ready: "Ready"
        case .waitingForButtonHold: "Waiting for button hold"
        case .waitingForReset: "Waiting for reset transition"
        case .postResetHoldBoth: "Reset detected; briefly holding both"
        case .releasePowerNow: "Release power now"
        case .holdingHome: "Holding Home"
        case .waitingForDFU: "Waiting for DFU"
        case .detectedDFU: "DFU detected"
        case .detectedRecovery: "Recovery detected"
        case .detectedNormal: "Normal reboot detected"
        case .disconnectedUnexpectedly: "Device disconnected unexpectedly"
        case .targetMismatch: "Different device detected"
        case .timedOut: "Timed out"
        case .cancelled: "Cancelled"
        }
    }
}

public struct MobileDFUTimingTelemetry: Equatable, Sendable {
    public var start: Duration?
    public var firstDisappearance: Duration?
    public var releaseCue: Duration?
    public var reappearance: Duration?
    public var recoveryAppearance: Duration?
    public var dfuAppearance: Duration?
    public var normalAppearance: Duration?

    public init() {}
}

public protocol MobileRecoveryResetting: Sendable {
    var isAvailable: Bool { get }
    func resetRecoveryDevice(ecid: String) async throws
}

public enum MobileRecoveryResetError: LocalizedError, Equatable, Sendable {
    case unavailable
    public var errorDescription: String? { "Synchronized Recovery reset is unavailable in this build." }
}

public struct UnavailableMobileRecoveryResetter: MobileRecoveryResetting {
    public let isAvailable = false
    public init() {}
    public func resetRecoveryDevice(ecid: String) async throws { throw MobileRecoveryResetError.unavailable }
}

@MainActor
public final class MobileDFUAssistantModel: ObservableObject {
    @Published public private(set) var state: MobileDFUAssistantState = .ready
    @Published public private(set) var observedDevice: DFUDevice?
    @Published public private(set) var isMonitoring = false
    @Published public private(set) var timing = MobileDFUTimingTelemetry()
    @Published public private(set) var lastAttemptSummary: String?
    @Published public private(set) var resetError: String?
    @Published public private(set) var recoveryOutcomeCount = 0

    public let profile: MobileDFUInstructionProfile
    public let target: DFUDevice
    public let expectedECID: String
    public let startedInRecovery: Bool
    public let isDemoMode: Bool
    public var synchronizedResetAvailable: Bool { startedInRecovery && recoveryResetter.isAvailable }
    public var shouldProminentlyShowCableAdvice: Bool { profile.cableAdvice != nil && recoveryOutcomeCount >= profile.cableAdviceRecoveryThreshold }

    private let discovery: any DeviceDiscovering
    private let operationLogger: any OperationLogging
    private let recoveryResetter: any MobileRecoveryResetting
    private let pollingInterval: Duration
    private let releaseCueDuration: Duration
    private let now: @Sendable () -> UInt64
    private let onDFUDetected: (DFUDevice) -> Void
    private let onLogCreated: (URL) -> Void
    private var monitorTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var logURL: URL?
    private var attemptInProgress = false
    private var sawExpectedTargetThisAttempt = false
    private var resetDetected = false
    private var startTick: UInt64?

    public init(
        target: DFUDevice,
        profile: MobileDFUInstructionProfile,
        discovery: any DeviceDiscovering,
        operationLogger: any OperationLogging = OperationLogger(),
        recoveryResetter: any MobileRecoveryResetting = UnavailableMobileRecoveryResetter(),
        isDemoMode: Bool = false,
        pollingInterval: Duration = .milliseconds(150),
        releaseCueDuration: Duration = .milliseconds(650),
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        onDFUDetected: @escaping (DFUDevice) -> Void = { _ in },
        onLogCreated: @escaping (URL) -> Void = { _ in }
    ) {
        self.target = target; self.profile = profile; self.discovery = discovery
        self.operationLogger = operationLogger; self.recoveryResetter = recoveryResetter
        self.isDemoMode = isDemoMode; self.pollingInterval = pollingInterval; self.releaseCueDuration = releaseCueDuration
        self.now = now; self.onDFUDetected = onDFUDetected; self.onLogCreated = onLogCreated
        expectedECID = target.ecid ?? ""; startedInRecovery = target.state == .recovery; observedDevice = target
    }

    deinit { monitorTask?.cancel(); releaseTask?.cancel(); timeoutTask?.cancel() }

    public func activate() {
        guard !isMonitoring else { return }
        logURL = try? operationLogger.start(operation: "Guided Mobile DFU", target: target, release: nil)
        if let logURL {
            onLogCreated(logURL)
            log("Instruction profile: \(profile.family.rawValue); initial state: \(target.state.rawValue); active polling: \(pollingInterval)")
        }
        guard !isDemoMode else { return }
        isMonitoring = true
        monitorTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let discovery = self.discovery
                let devices = (try? await Task.detached { try discovery.devices() }.value) ?? []
                guard !Task.isCancelled else { break }
                self.consume(devices: devices)
                try? await Task.sleep(for: self.pollingInterval)
            }
        }
    }

    public func start() {
        guard [.ready, .detectedRecovery, .detectedNormal, .disconnectedUnexpectedly, .targetMismatch, .timedOut].contains(state) else { return }
        beginAttempt()
        transition(to: .waitingForButtonHold)
        transition(to: .waitingForReset)
    }

    public func startSynchronizedRecoveryReset() async {
        guard startedInRecovery, recoveryResetter.isAvailable else { resetError = "Synchronized Recovery reset is unavailable in this build."; return }
        beginAttempt(); transition(to: .waitingForButtonHold); transition(to: .waitingForReset)
        do { try await recoveryResetter.resetRecoveryDevice(ecid: expectedECID); log("Explicit synchronized Recovery reset requested") }
        catch { resetError = error.localizedDescription; attemptInProgress = false; transition(to: .timedOut) }
    }

    public func retry() { finishTasks(); attemptInProgress = false; resetDetected = false; transition(to: .ready) }
    public func cancel() { attemptInProgress = false; transition(to: .cancelled); stopMonitoring() }
    public func deactivate() { if state != .detectedDFU && state != .cancelled { transition(to: .cancelled) }; stopMonitoring() }

    public func consume(devices: [DFUDevice]) {
        let mobile = devices.filter { $0.family == .iPhone || $0.family == .iPad }
        if mobile.contains(where: { $0.ecid.map { !Self.sameECID($0, expectedECID) } == true }) {
            fail(.targetMismatch); return
        }
        guard let matched = mobile.first(where: { $0.ecid.map { Self.sameECID($0, expectedECID) } == true }) else {
            observedDevice = nil
            if attemptInProgress && sawExpectedTargetThisAttempt && !resetDetected {
                resetDetected = true; timing.firstDisappearance = elapsed(); logTiming("first disappearance", timing.firstDisappearance)
                transition(to: .postResetHoldBoth); scheduleReleaseCue()
            } else if !attemptInProgress {
                transition(to: .disconnectedUnexpectedly)
            }
            return
        }

        let wasMissing = observedDevice == nil
        observedDevice = matched
        if attemptInProgress { sawExpectedTargetThisAttempt = true }
        if wasMissing && resetDetected && timing.reappearance == nil { timing.reappearance = elapsed(); logTiming("reappearance", timing.reappearance) }

        if matched.state == .dfu, attemptInProgress { timing.dfuAppearance = elapsed(); logTiming("DFU appearance", timing.dfuAppearance); succeed(matched); return }
        guard attemptInProgress, resetDetected else {
            if state == .disconnectedUnexpectedly { transition(to: .ready) }
            return
        }
        switch matched.state {
        case .recovery:
            recoveryOutcomeCount += 1; timing.recoveryAppearance = elapsed(); logTiming("Recovery appearance", timing.recoveryAppearance); fail(.detectedRecovery)
        case .normal:
            timing.normalAppearance = elapsed(); logTiming("Normal appearance", timing.normalAppearance); fail(.detectedNormal)
        case .dfu, .unknown: break
        }
    }

    public func setDemoState(_ value: MobileDFUAssistantState) {
        guard isDemoMode else { return }
        attemptInProgress = false; finishTasks()
        if value == .detectedDFU {
            let dfu = DFUDevice(family: target.family, state: .dfu, model: target.model, identifier: target.identifier, ecid: expectedECID, productType: target.productType, modelIdentifier: target.modelIdentifier)
            observedDevice = dfu; transition(to: value); onDFUDetected(dfu); stopMonitoring()
        } else { transition(to: value) }
    }

    /// Deterministic test hook for the same terminal transition used by the
    /// monotonic timeout task. It never performs a device operation.
    public func expireAttempt() { guard attemptInProgress else { return }; fail(.timedOut) }

    /// Deterministic test hook representing expiry of the profile-owned post-reset delay.
    public func fireReleaseCue() {
        guard attemptInProgress, resetDetected, state == .postResetHoldBoth else { return }
        timing.releaseCue = elapsed(); logTiming("release cue", timing.releaseCue)
        transition(to: .releasePowerNow)
        scheduleTimeout(after: profile.timing.homeHoldTimeout)
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            guard let self else { return }; try? await Task.sleep(for: self.releaseCueDuration)
            guard !Task.isCancelled, self.attemptInProgress, self.state == .releasePowerNow else { return }
            self.transition(to: .holdingHome); self.transition(to: .waitingForDFU)
        }
    }

    private func beginAttempt() {
        finishTasks(); resetError = nil; timing = MobileDFUTimingTelemetry(); startTick = now(); timing.start = .zero
        attemptInProgress = true; sawExpectedTargetThisAttempt = observedDevice.map { $0.ecid.map { Self.sameECID($0, expectedECID) } == true } ?? false
        resetDetected = false; log("Attempt started (monotonic t=0)")
        scheduleTimeout(after: profile.timing.dfuDetectionTimeout)
    }

    private func scheduleTimeout(after duration: Duration) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            guard let self else { return }; try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }; self.expireAttempt()
        }
    }

    private func scheduleReleaseCue() {
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            guard let self else { return }; try? await Task.sleep(for: self.profile.timing.postResetBothHold)
            guard !Task.isCancelled else { return }; self.fireReleaseCue()
        }
    }

    private func succeed(_ device: DFUDevice) { attemptInProgress = false; finishTasks(); transition(to: .detectedDFU); onDFUDetected(device); stopMonitoring() }
    private func fail(_ value: MobileDFUAssistantState) {
        attemptInProgress = false; finishTasks(); transition(to: value)
        if let disappearance = timing.firstDisappearance {
            let outcome = timing.recoveryAppearance ?? timing.normalAppearance ?? timing.dfuAppearance
            if let outcome { lastAttemptSummary = "Reset detected. Outcome appeared \(Self.seconds(outcome - disappearance)) s later." }
            else { lastAttemptSummary = "Reset detected; no conclusive device state appeared before the attempt ended." }
        }
    }
    private func finishTasks() { releaseTask?.cancel(); releaseTask = nil; timeoutTask?.cancel(); timeoutTask = nil }
    private func stopMonitoring() { monitorTask?.cancel(); finishTasks(); isMonitoring = false }

    /// Waits for an in-flight read-only discovery call to finish after
    /// cancellation. This is also useful to callers that must not observe a
    /// late callback after teardown.
    public func waitForMonitoringStop() async {
        if let task = monitorTask { await task.value }
        monitorTask = nil
    }
    private func transition(to value: MobileDFUAssistantState) { guard state != value else { return }; state = value; log("State: \(value.description)") }
    private func elapsed() -> Duration { guard let startTick else { return .zero }; return .nanoseconds(Int64(clamping: now() &- startTick)) }
    private func logTiming(_ label: String, _ value: Duration?) { if let value { log("Timing: \(label) at +\(Self.seconds(value)) s") } }
    private func log(_ message: String) { if let logURL { try? operationLogger.append(message, to: logURL) } }
    private static func seconds(_ value: Duration) -> String { String(format: "%.3f", Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18) }
    private static func sameECID(_ lhs: String, _ rhs: String) -> Bool { lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}
