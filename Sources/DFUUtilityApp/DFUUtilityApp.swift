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
            _model = StateObject(wrappedValue: AppModel(ipswService: DemoIPSWService(), discovery: DemoDiscovery(), cache: cache, diagnostics: DemoDiagnostics(), restoreEngine: DemoRestoreEngine(), dfuController: DemoDFUController(), isDemoMode: true))
        } else { _model = StateObject(wrappedValue: AppModel()) }
    }

    var body: some Scene {
        WindowGroup("DFUUtility") { ContentView(model: model).frame(minWidth: 590, minHeight: 620) }
            .windowResizability(.contentMinSize)
        Settings { DiagnosticsView(report: model.doctorReport, privilegeMode: model.privilegeMode, helperState: model.privilegedHelperState, registrationErrorDetails: model.helperRegistrationErrorDetails) }
    }
}
