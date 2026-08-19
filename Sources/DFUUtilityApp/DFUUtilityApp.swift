import DFUAppSupport
import DFUCore
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--demo"),
           let index = CommandLine.arguments.firstIndex(of: "--capture-screenshot"),
           CommandLine.arguments.indices.contains(index + 1) {
            let destination = CommandLine.arguments[index + 1]
            let scenario = CommandLine.arguments.firstIndex(of: "--screenshot").flatMap {
                CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil
            } ?? "normal"
            Task { @MainActor in
                await self.captureDemoScreenshot(scenario: scenario, at: destination)
            }
        }
    }

    @MainActor private func captureDemoScreenshot(scenario: String, at path: String) async {
        let cache = IPSWCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("DFUUtility-Screenshot-Cache"))
        let model = AppModel(ipswService: DemoIPSWService(), discovery: DemoDiscovery(), cache: cache, diagnostics: DemoDiagnostics(), restoreEngine: DemoRestoreEngine(), dfuController: DemoDFUController(), isDemoMode: true, screenshotScenario: scenario)
        await model.load()
        let root: AnyView
        let size: NSSize
        if scenario == "chooser" {
            model.beginChoosingVersion()
            root = AnyView(VersionPicker(model: model, isPresented: .constant(true)))
            size = NSSize(width: 620, height: 450)
        } else {
            root = AnyView(ContentView(model: model))
            size = NSSize(width: 700, height: 700)
        }
        let rendered = root
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.light)
        let view = NSHostingView(rootView: rendered)
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSApp.terminate(nil); return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            do { try png.write(to: URL(fileURLWithPath: path), options: .atomic) }
            catch { FileHandle.standardError.write(Data("Unable to write demo screenshot: \(error)\n".utf8)) }
        }
        NSApp.terminate(nil)
    }
}

@main
struct DFUUtilityApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        if CommandLine.arguments.contains("--register-helper-diagnostic") {
            let client = PrivilegedDFUClient()
            print("Before: \(client.state().description)")
            do { print("After: \(try client.setUp().description)"); exit(0) }
            catch {
                print("After: \(client.state().description)")
                let details: String
                if case .registrationFailed(let value) = error as? PrivilegedDFUClientError { details = value }
                else { details = NSErrorDiagnostics.describe(error) }
                FileHandle.standardError.write(Data("Registration error: \(details)\n".utf8)); exit(1)
            }
        }
        if CommandLine.arguments.contains("--unregister-helper") {
            do { try PrivilegedDFUClient().unregister(); print("Privileged helper unregistered."); exit(0) }
            catch { FileHandle.standardError.write(Data("Failed to unregister privileged helper: \(error.localizedDescription)\n".utf8)); exit(1) }
        }
        let demo = ProcessInfo.processInfo.environment["DFUUTILITY_DEMO"] == "1" || CommandLine.arguments.contains("--demo")
        if demo {
            let cache = IPSWCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("DFUUtility-Demo-Cache"))
            let scenario = CommandLine.arguments.firstIndex(of: "--screenshot").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
            _model = StateObject(wrappedValue: AppModel(ipswService: DemoIPSWService(), discovery: DemoDiscovery(), cache: cache, diagnostics: DemoDiagnostics(), restoreEngine: DemoRestoreEngine(), dfuController: DemoDFUController(), isDemoMode: true, screenshotScenario: scenario))
        } else { _model = StateObject(wrappedValue: AppModel()) }
    }

    var body: some Scene {
        WindowGroup("DFUUtility") { ContentView(model: model).frame(minWidth: 590, minHeight: 620) }
            .windowResizability(.contentMinSize)
        Settings { DiagnosticsView(report: model.doctorReport, privilegeMode: model.privilegeMode, helperState: model.privilegedHelperState, registrationErrorDetails: model.helperRegistrationErrorDetails) }
    }
}
