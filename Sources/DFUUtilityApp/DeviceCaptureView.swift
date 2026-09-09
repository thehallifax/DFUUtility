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
        GeometryReader { proxy in
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Device Capture").font(.largeTitle.bold())
                    Text("Capture device identifiers without modifying connected devices.").foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(title: model.captureSession.isAutomaticCaptureEnabled ? "Automatic capture active" : "Manual capture", tint: model.captureSession.isAutomaticCaptureEnabled ? .green : .secondary, systemImage: model.captureSession.isAutomaticCaptureEnabled ? "dot.radiowaves.left.and.right" : "pause.circle")
            }
            controls
            Text("Captured records · \(model.captureSession.records.count)").font(.headline)
            if proxy.size.width >= 1120 {
                HStack(alignment: .top, spacing: 16) {
                    captureTable(availableWidth: proxy.size.width - 356)
                    if let record = selectedRecord { detailPanel(record) }
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    captureTable(availableWidth: proxy.size.width)
                    if let record = selectedRecord { detailPanel(record) }
                }
            }
            if let copyConfirmation { Text(copyConfirmation).font(.caption).foregroundStyle(.secondary) }
        }
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 8) {
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
            Button("Export CSV…") { exportCSV() }.disabled(model.captureSession.records.isEmpty)
            Button("Clear Session", role: .destructive) { showingClearConfirmation = true }.disabled(model.captureSession.records.isEmpty)
        }
    }

    private func captureTable(availableWidth: CGFloat) -> some View {
        let tableHeight = min(CGFloat(520), max(CGFloat(190), CGFloat(model.captureSession.records.count + 1) * 54))
        return WorkspacePanel("Captured Devices", systemImage: "list.bullet.rectangle") {
            GeometryReader { proxy in
                let showFullIdentifiers = availableWidth >= 760
                let minimumWidth: CGFloat = showFullIdentifiers ? 760 : 680
                ScrollView([.horizontal, .vertical]) {
                    tableContents(showFullIdentifiers: showFullIdentifiers, width: max(proxy.size.width, minimumWidth))
                }
            }.frame(height: tableHeight)
        }.frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder private func tableContents(showFullIdentifiers: Bool, width: CGFloat) -> some View {
        let assetWidth: CGFloat = 60
        let deviceWidth: CGFloat = 140
        let productWidth: CGFloat = 95
        let serialWidth: CGFloat = showFullIdentifiers ? 140 : 95
        let ecidWidth: CGFloat = showFullIdentifiers ? 140 : 95
        let stateWidth: CGFloat = 65
        // Reserve the row's horizontal insets so the flexible Captured column
        // does not force the scroll view into a slightly offset state.
        let capturedWidth = max(90, width - assetWidth - deviceWidth - productWidth - serialWidth - ecidWidth - stateWidth - 32)
        LazyVStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Asset").frame(width: assetWidth, alignment: .leading)
                Text("Device").frame(width: deviceWidth, alignment: .leading)
                Text("Product").frame(width: productWidth, alignment: .leading)
                Text("Serial").frame(width: serialWidth, alignment: .leading)
                Text("ECID").frame(width: ecidWidth, alignment: .leading)
                Text("State").frame(width: stateWidth, alignment: .leading)
                Text("Captured").frame(width: capturedWidth, alignment: .leading)
            }.font(.caption.bold()).foregroundStyle(.secondary).padding(8)
            ForEach(model.captureSession.records) { record in
                Button { selectedID = record.id } label: {
                    HStack(spacing: 0) {
                        Text(record.assetTag ?? "—").frame(width: assetWidth, alignment: .leading)
                        Text(record.displayName ?? record.family.displayName).frame(width: deviceWidth, alignment: .leading).lineLimit(1)
                        Text(record.productIdentifier ?? "—").frame(width: productWidth, alignment: .leading).lineLimit(1)
                        identifierCell(showFullIdentifiers ? record.serialNumber : record.shortSerial, fallback: "—", width: serialWidth, help: record.serialNumber ?? "Serial number unavailable")
                        identifierCell(showFullIdentifiers ? record.ecid : record.shortECID, fallback: "—", width: ecidWidth, help: record.ecid ?? "ECID unavailable")
                        Text(record.state.rawValue).frame(width: stateWidth, alignment: .leading)
                        Text(record.capturedAt, format: .dateTime.hour().minute().second()).frame(width: capturedWidth, alignment: .leading)
                    }
                    .font(.caption).padding(8).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(selectedID == record.id ? Color.accentColor.opacity(0.12) : .clear)
                .contextMenu { identifierContextMenu(for: record) }
                Divider()
            }
            if model.captureSession.records.isEmpty {
                ContentUnavailableView("No captured devices", systemImage: "qrcode.viewfinder", description: Text("Capture a connected device or start automatic capture"))
                    .frame(width: width).padding(24)
            }
        }.frame(width: width, alignment: .leading)
    }

    private func identifierCell(_ value: String?, fallback: String, width: CGFloat, help: String) -> some View {
        Text(value ?? fallback)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width, alignment: .leading)
            .help(help)
    }

    private func detailPanel(_ record: DeviceCaptureRecord) -> some View {
        WorkspacePanel("Selected Device", systemImage: deviceFamilySymbol(record.family)) {
            VStack(alignment: .leading, spacing: 10) {
                Text(record.displayName ?? record.family.displayName).font(.headline)
                LabeledContent("Family", value: record.family.displayName)
                LabeledContent("State", value: record.state.rawValue)
                if let product = record.productIdentifier { LabeledContent("Product", value: product) }
                GroupBox("Identifiers") {
                    VStack(alignment: .leading, spacing: 10) {
                        identifierBlock("Serial Number", value: record.serialNumber, copyTitle: "Copy Serial")
                        identifierBlock("ECID", value: record.ecid, copyTitle: "Copy ECID")
                        identifierBlock("UDID", value: record.udid, copyTitle: "Copy UDID")
                        Button("Copy All") { copy(record.copyAllText(), message: "Identifiers copied.") }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                WorkspacePanel("Asset Tag", systemImage: "tag") {
                    HStack {
                        TextField("Optional asset label", text: $assetTag)
                            .onSubmit { model.captureSession.updateAssetTag(assetTag, for: record.id) }
                        Button("Save") { model.captureSession.updateAssetTag(assetTag, for: record.id) }
                    }
                }
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
        }.frame(width: 340)
    }

    @ViewBuilder private func identifierContextMenu(for record: DeviceCaptureRecord) -> some View {
        if let serial = record.serialNumber { Button("Copy Serial") { copy(serial, message: "Serial copied.") } }
        if let ecid = record.ecid { Button("Copy ECID") { copy(ecid, message: "ECID copied.") } }
        if let udid = record.udid { Button("Copy UDID") { copy(udid, message: "UDID copied.") } }
        Button("Copy All Identifiers") { copy(record.copyAllText(), message: "Identifiers copied.") }
    }

    @ViewBuilder private func identifierBlock(_ label: String, value: String?, copyTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(value)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Button(copyTitle) { copy(value, message: "(label) copied.") }
                        .controlSize(.small)
                }
            } else {
                Text("Not available").foregroundStyle(.secondary)
            }
        }
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
