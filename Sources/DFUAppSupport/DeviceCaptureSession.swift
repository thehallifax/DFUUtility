import DFUCore
import Foundation

public struct DeviceCaptureRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public var family: AppleDeviceFamily
    public var displayName: String?
    public var productIdentifier: String?
    public var serialNumber: String?
    public var ecid: String?
    public var udid: String?
    public var state: DeviceState
    public var assetTag: String?

    public init(id: UUID = UUID(), capturedAt: Date = Date(), device: DFUDevice, assetTag: String? = nil) {
        self.id = id; self.capturedAt = capturedAt; self.family = device.family
        self.displayName = device.friendlyName; self.productIdentifier = device.restoreProductType
        self.serialNumber = Self.clean(device.serialNumber); self.ecid = Self.clean(device.ecid)
        self.udid = Self.clean(device.identifier); self.state = device.state
        self.assetTag = Self.clean(assetTag)
    }

    public var stableIdentities: [String] {
        [ecid, udid, serialNumber].compactMap { value in
            guard let value else { return nil }
            return value.lowercased()
        }
    }

    public var shortECID: String? { Self.short(ecid) }
    public var shortSerial: String? { Self.short(serialNumber) }
    public var shortUDID: String? { Self.short(udid) }

    public mutating func enrich(with device: DFUDevice) {
        family = device.family
        displayName = displayName ?? device.friendlyName
        productIdentifier = productIdentifier ?? device.restoreProductType
        serialNumber = serialNumber ?? Self.clean(device.serialNumber)
        ecid = ecid ?? Self.clean(device.ecid)
        udid = udid ?? Self.clean(device.identifier)
        state = device.state
    }

    public func copyAllText() -> String {
        var lines = ["Device: \(displayName ?? family.displayName)"]
        if let productIdentifier { lines.append("Product: \(productIdentifier)") }
        if let serialNumber { lines.append("Serial: \(serialNumber)") }
        if let ecid { lines.append("ECID: \(ecid)") }
        if let udid { lines.append("UDID: \(udid)") }
        lines.append("State: \(state.rawValue)")
        if let assetTag { lines.append("Asset Tag: \(assetTag)") }
        return lines.joined(separator: "\n")
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    private static func short(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.count > 8 ? "…" + value.suffix(8) : value
    }
}

public enum DeviceCaptureQRCode {
    public static func payload(for record: DeviceCaptureRecord) -> String? { record.serialNumber }
}

@MainActor
public final class DeviceCaptureSession: ObservableObject {
    @Published public private(set) var records: [DeviceCaptureRecord] = []
    @Published public var isAutomaticCaptureEnabled = false

    public init() {}

    @discardableResult
    public func capture(_ device: DFUDevice, assetTag: String? = nil) -> DeviceCaptureRecord {
        if let index = matchingIndex(for: device) {
            var record = records[index]
            record.enrich(with: device)
            if let assetTag { record.assetTag = clean(assetTag) }
            records[index] = record
            return record
        }
        let record = DeviceCaptureRecord(device: device, assetTag: assetTag)
        records.append(record)
        return record
    }

    public func observe(_ devices: [DFUDevice]) {
        guard isAutomaticCaptureEnabled else { return }
        for device in devices where !deviceStableIdentities(device).isEmpty { capture(device) }
    }

    public func updateAssetTag(_ tag: String?, for id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].assetTag = clean(tag)
    }

    public func clear() { records.removeAll() }

    public func csvString() -> String {
        let header = ["Captured At", "Asset Tag", "Family", "Display Name", "Product Identifier", "Serial Number", "ECID", "UDID", "State"]
        let formatter = ISO8601DateFormatter()
        return ([header] + records.map { record in
            [formatter.string(from: record.capturedAt), record.assetTag ?? "", record.family.displayName,
             record.displayName ?? "", record.productIdentifier ?? "", record.serialNumber ?? "",
             record.ecid ?? "", record.udid ?? "", record.state.rawValue]
        }).map { $0.map(Self.csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    public func copyAllText(for id: UUID) -> String? { records.first(where: { $0.id == id })?.copyAllText() }

    private func matchingIndex(for device: DFUDevice) -> Int? {
        let identities = deviceStableIdentities(device)
        guard !identities.isEmpty else { return nil }
        return records.firstIndex { !$0.stableIdentities.isEmpty && !Set($0.stableIdentities).isDisjoint(with: identities) }
    }

    private func deviceStableIdentities(_ device: DFUDevice) -> Set<String> {
        Set([device.ecid, device.identifier, device.serialNumber].compactMap { value in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed.lowercased()
        })
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\r") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
