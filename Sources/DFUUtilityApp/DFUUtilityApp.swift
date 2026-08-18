import DFUAppSupport
import DFUCore
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct DFUUtilityApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        let demo = ProcessInfo.processInfo.environment["DFUUTILITY_DEMO"] == "1" || CommandLine.arguments.contains("--demo")
        if demo {
            let cache = IPSWCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("DFUUtility-Demo-Cache"))
            _model = StateObject(wrappedValue: AppModel(ipswService: DemoIPSWService(), discovery: DemoDiscovery(), cache: cache, diagnostics: DemoDiagnostics(), restoreEngine: DemoRestoreEngine(), dfuController: DemoDFUController(), isDemoMode: true))
        } else { _model = StateObject(wrappedValue: AppModel()) }
    }

    var body: some Scene {
        WindowGroup("DFUUtility") { ContentView(model: model).frame(minWidth: 590, minHeight: 620) }
            .windowResizability(.contentMinSize)
        Settings { DiagnosticsView(report: model.doctorReport) }
    }
}
