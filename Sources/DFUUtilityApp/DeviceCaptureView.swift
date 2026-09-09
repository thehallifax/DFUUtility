import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import DFUAppSupport
import SwiftUI

struct DeviceCaptureView: View {
    @ObservedObject var model: AppModel
    @State private var selectedID: UUID?
    @State private var assetTag = ""
    @State private var showingClearConfirmation = false
    @State private var copyConfirmation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Device Capture").font(.largeTitle.bold())
            Text("Capture device identifiers without modifying connected devices.").foregroundStyle(.secondary)
            controls
            Text("Captured: \(model.captureSession.records.count)").font(.headline)
            HStack(alignment: .top, spacing: 16) {
                captureTable
                if let record = selectedRecord { detailPanel(record) }
            }
            if let copyConfirmation { Text(copyConfirmation).font(.caption).foregroundStyle(.secondary) }
        }
        .onChange(of: selectedID) { _, id in
            assetTag = id.flatMap { selected in model.captureSession.records.first(where: { $0.id == selected })?.assetTag } ?? ""
        }
        .onAppear {
            if selectedID == nil { selectedID = model.captureSession.records.first?.id }
        }
        .onChange(of: model.deviceSessions.sessions) { _, sessions in
            if model.captureSession.isAutomaticCaptureEnabled { model.captureSession.observe(sessions.filter(\.isConnected).map(\.device)) }
        }
        .confirmationDialog("Clear capture session?", isPresented: $showingClearConfirmation) {
            Button("Clear Session", role: .destructive) { model.captureSession.clear(); selectedID = nil }
        } message: {
            Text("This removes the captured records from this session only. Connected devices and Restore selections are unchanged.")
        }
    }

    private var selectedRecord: DeviceCaptureRecord? {
        selectedID.flatMap { id in model.captureSession.records.first(where: { $0.id == id }) }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button(model.captureSession.isAutomaticCaptureEnabled ? "Stop Automatic Capture" : "Start Automatic Capture") {
                model.captureSession.isAutomaticCaptureEnabled.toggle()
                if model.captureSession.isAutomaticCaptureEnabled {
                    model.captureSession.observe(model.deviceSessions.sessions.filter(\.isConnected).map(\.device))
                }
            }
            .buttonStyle(.borderedProminent)
            Button("Capture Connected Device") {
                if let record = model.captureConnectedDevice() { selectedID = record.id }
            }
            .disabled(model.target == nil)
            Spacer()
            Text(model.captureSession.isAutomaticCaptureEnabled ? "Automatic capture active" : "Automatic capture inactive")
                .font(.caption).foregroundStyle(model.captureSession.isAutomaticCaptureEnabled ? .green : .secondary)
            Button("Export CSV…") { exportCSV() }.disabled(model.captureSession.records.isEmpty)
            Button("Clear Session", role: .destructive) { showingClearConfirmation = true }.disabled(model.captureSession.records.isEmpty)
        }
    }

    private var captureTable: some View {
        GroupBox {
            ScrollView {
                LazyVStack(spacing: 0) {
                    HStack {
                        Text("Asset Tag").frame(width: 100, alignment: .leading)
                        Text("Device").frame(width: 120, alignment: .leading)
                        Text("Product").frame(width: 110, alignment: .leading)
                        Text("Serial").frame(width: 95, alignment: .leading)
                        Text("ECID").frame(width: 95, alignment: .leading)
                        Text("State").frame(width: 80, alignment: .leading)
                        Text("Captured").frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption.bold()).foregroundStyle(.secondary).padding(8)
                    ForEach(model.captureSession.records) { record in
                        Button { selectedID = record.id } label: {
                            HStack {
                                Text(record.assetTag ?? "—").frame(width: 100, alignment: .leading)
                                Text(record.displayName ?? record.family.displayName).frame(width: 120, alignment: .leading).lineLimit(1)
                                Text(record.productIdentifier ?? "—").frame(width: 110, alignment: .leading)
                                Text(record.shortSerial ?? "—").frame(width: 95, alignment: .leading)
                                Text(record.shortECID ?? "—").frame(width: 95, alignment: .leading)
                                Text(record.state.rawValue).frame(width: 80, alignment: .leading)
                                Text(record.capturedAt, format: .dateTime.hour().minute().second()).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.caption).padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain).background(selectedID == record.id ? Color.accentColor.opacity(0.12) : .clear)
                        Divider()
                    }
                    if model.captureSession.records.isEmpty {
                        ContentUnavailableView("No captured devices", systemImage: "qrcode.viewfinder", description: Text("Capture a connected device or start automatic capture."))
                            .padding(24)
                    }
                }
            }.frame(minHeight: 240)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailPanel(_ record: DeviceCaptureRecord) -> some View {
        GroupBox("Selected Device") {
            VStack(alignment: .leading, spacing: 10) {
                Text(record.displayName ?? record.family.displayName).font(.headline)
                LabeledContent("Family", value: record.family.displayName)
                LabeledContent("State", value: record.state.rawValue)
                if let product = record.productIdentifier { LabeledContent("Product", value: product) }
                GroupBox("Identifiers") {
                    VStack(alignment: .leading, spacing: 6) {
                        identifierRow("Serial Number", value: record.serialNumber)
                        identifierRow("ECID", value: record.ecid)
                        identifierRow("UDID", value: record.udid)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                TextField("Asset tag / label", text: $assetTag)
                    .onSubmit { model.captureSession.updateAssetTag(assetTag, for: record.id) }
                Button("Save Asset Tag") { model.captureSession.updateAssetTag(assetTag, for: record.id) }
                Divider()
                if let serial = record.serialNumber { Button("Copy Serial") { copy(serial, message: "Serial copied.") } }
                if let ecid = record.ecid { Button("Copy ECID") { copy(ecid, message: "ECID copied.") } }
                if let udid = record.udid { Button("Copy UDID") { copy(udid, message: "UDID copied.") } }
                Button("Copy All Identifiers") { copy(record.copyAllText(), message: "Identifiers copied.") }
                GroupBox("QR Code") {
                    if let serial = DeviceCaptureQRCode.payload(for: record), let image = makeQR(for: serial) {
                        Image(nsImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 180, height: 180)
                        Text(serial).font(.caption.monospaced())
                        Button("Copy Serial") { copy(serial, message: "Serial copied.") }
                    } else {
                        Text("Serial number unavailable for this device.").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }.frame(minWidth: 230, alignment: .leading).padding(8)
        }.frame(width: 280)
    }

    private func identifierRow(_ label: String, value: String?) -> some View {
        LabeledContent(label, value: value ?? "Not available")
            .foregroundStyle(value == nil ? .secondary : .primary)
    }

    private func copy(_ value: String, message: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string); copyConfirmation = message
    }

    private func makeQR(for serial: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(serial.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func exportCSV() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "DFUUtility-Device-Capture-\(ISO8601DateFormatter().string(from: Date()).prefix(10)).csv"; panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.captureSession.csvString().write(to: url, atomically: true, encoding: .utf8); copyConfirmation = "Capture CSV exported." }
        catch { copyConfirmation = "Unable to export capture CSV: \(error.localizedDescription)" }
    }
}
