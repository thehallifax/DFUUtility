import DFUAppSupport
import DFUCore
import AppKit
import SwiftUI

@MainActor private final class AppKitApplicationTerminator: ApplicationTerminationRequesting {
    func requestTermination() {
        AppLifecycleTrace.write("termination request on main thread=\(Thread.isMainThread) pid=\(ProcessInfo.processInfo.processIdentifier)")
        let sheets = NSApp.windows.filter { $0.sheetParent != nil || $0.attachedSheet != nil }
        AppLifecycleTrace.write("termination request observed sheets=\(sheets.count) windows=\(NSApp.windows.count)")
        for sheet in sheets {
            sheet.sheetParent?.endSheet(sheet, returnCode: .cancel)
        }
        DispatchQueue.main.async {
            AppLifecycleTrace.write("termination request dispatch reached")
            NSApplication.shared.terminate(nil)
        }
    }
}

private enum AppLifecycleTrace {
    static func write(_ message: String) {
        FileHandle.standardError.write(Data("DFUUtility lifecycle: \(message)\n".utf8))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
#if DEBUG
    private var smokeModel: AppModel?
    private var smokeWindow: NSWindow?
#endif
    // SwiftUI's application lifecycle does not otherwise provide an explicit
    // termination reply. Returning terminateNow ensures the orderly
    // termination requested after a successful binary-installer handoff is
    // not left pending while the update sheet is being dismissed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLifecycleTrace.write("applicationShouldTerminate reply=terminateNow")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLifecycleTrace.write("applicationWillTerminate")
        NSLog("DFUUtility applicationWillTerminate reached")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
#if DEBUG
        if CommandLine.arguments.contains("--handoff-termination-smoke-success") || CommandLine.arguments.contains("--handoff-termination-smoke-failure") {
            Task { @MainActor in await self.runHandoffTerminationSmoke() }
        }
        if CommandLine.arguments.contains("--sidebar-layout-resize-smoke") {
            Task { @MainActor in await self.runSidebarLayoutResizeSmoke() }
        }
#endif
        if CommandLine.arguments.contains("--demo"),
           let index = CommandLine.arguments.firstIndex(of: "--capture-screenshot"),
           CommandLine.arguments.indices.contains(index + 1) {
            let destination = CommandLine.arguments[index + 1]
            let scenario = CommandLine.arguments.firstIndex(of: "--screenshot").flatMap {
                CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil
            } ?? "normal-mac"
            Task { @MainActor in
                await self.captureDemoScreenshot(scenario: scenario, at: destination)
            }
        }
    }

#if DEBUG
    @MainActor private func runHandoffTerminationSmoke() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DFUUtility-Handoff-Smoke-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: source.appendingPathComponent(".git"), withIntermediateDirectories: true)
            let sourceRecord = root.appendingPathComponent("update-source")
            try source.path.write(to: sourceRecord, atomically: true, encoding: .utf8)
            let failure = CommandLine.arguments.contains("--handoff-termination-smoke-failure")
            let coordinator = UpdateCoordinator(service: SmokeUpdateService(failsToSpawn: failure), sourceRecordURL: sourceRecord, resultURL: root.appendingPathComponent("result"), logURL: root.appendingPathComponent("log"), defaults: UserDefaults(suiteName: "DFUUtility-Handoff-Smoke-\(UUID().uuidString)")!, appURL: root.appendingPathComponent("DFUUtility.app"), runningVersion: SemanticVersion(tag: "v0.10.0")!)
            let model = AppModel(updateCoordinator: coordinator, applicationTerminator: AppKitApplicationTerminator(), requiresPrivilegedHelperSetup: false)
            await coordinator.check(manual: true)
            smokeModel = model
            let window = NSWindow(contentViewController: NSHostingController(rootView: ContentView(model: model)))
            window.setContentSize(NSSize(width: 700, height: 500))
            window.makeKeyAndOrderFront(nil)
            smokeWindow = window
            model.isUpdatePresentationRequested = true
            try? await Task.sleep(for: .milliseconds(500))
            let started = model.prepareUpdate()
            AppLifecycleTrace.write("synthetic handoff prepareUpdate returned=\(started)")
            AppLifecycleTrace.write(failure ? "synthetic installer spawn failed; app remains running" : "synthetic installer spawn succeeded")
        } catch {
            AppLifecycleTrace.write("synthetic handoff setup failed: \(error.localizedDescription)")
        }
    }
#endif

#if DEBUG
    /// Exercises the real AppKit split view through representative window
    /// resizes. This is intentionally a test-only command-line path: normal
    /// launches never resize the window or alter the user's divider position.
    @MainActor private func runSidebarLayoutResizeSmoke() async {
        guard let window = await waitForApplicationWindow() else {
            AppLifecycleTrace.write("sidebar resize smoke could not find application window")
            exit(1)
        }
        smokeWindow = window
        window.makeKeyAndOrderFront(nil)
        // Establish the same large launch geometry used by the acceptance
        // scenario before exercising live resize down to normal/minimum.
        window.setContentSize(NSSize(width: 1240, height: 860))
        await settleSidebarLayout(window)
        emitSidebarResizeSmoke(phase: "launch-large", window: window)
        let sizes: [(String, CGFloat, CGFloat)] = [
            ("normal", 1040, 800),
            ("minimum", 760, 500)
        ]
        for (phase, width, height) in sizes {
            window.setContentSize(NSSize(width: width, height: height))
            await settleSidebarLayout(window)
            emitSidebarResizeSmoke(phase: phase, window: window)
        }
        if let split = sidebarSplitView(in: window), split.subviews.count >= 2 {
            // Simulate a technician dragging the native divider to a valid
            // position. The production guard must leave this width alone
            // during subsequent window resizes.
            split.setPosition(320, ofDividerAt: 0)
            await settleSidebarLayout(window)
            emitSidebarResizeSmoke(phase: "manual", window: window)
        }
        window.setContentSize(NSSize(width: 1240, height: 860))
        await settleSidebarLayout(window)
        emitSidebarResizeSmoke(phase: "large-again", window: window)
        AppLifecycleTrace.write("sidebar resize smoke complete")
        NSApp.terminate(nil)
    }

    @MainActor private func waitForApplicationWindow() async -> NSWindow? {
        for _ in 0..<200 {
            if let window = NSApp.windows.first(where: { $0.contentView != nil && !$0.className.contains("Panel") }) {
                return window
            }
            await Task.yield()
        }
        return nil
    }

    @MainActor private func settleSidebarLayout(_ window: NSWindow) async {
        for _ in 0..<12 {
            window.contentView?.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @MainActor private func emitSidebarResizeSmoke(phase: String, window: NSWindow) {
        guard let split = sidebarSplitView(in: window), split.subviews.count >= 2,
              let sidebar = split.subviews.filter({ $0.frame.minX <= 1 && $0.frame.width > 100 }).max(by: { $0.frame.width < $1.frame.width }),
              let width = sidebarWidth(sidebar, in: split) else {
            AppLifecycleTrace.write("SidebarResizeSmoke phase=\(phase) window=\(Int(window.contentView?.bounds.width ?? 0))x\(Int(window.contentView?.bounds.height ?? 0)) sidebar=unavailable")
            return
        }
        AppLifecycleTrace.write("SidebarResizeSmoke phase=\(phase) window=\(Int(window.contentView?.bounds.width ?? 0))x\(Int(window.contentView?.bounds.height ?? 0)) sidebar=\(width) limits=260/280/340")
    }

    private func sidebarSplitView(in window: NSWindow) -> NSSplitView? {
        guard let root = window.contentView else { return nil }
        return sidebarSplitView(in: root)
    }

    private func sidebarSplitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView,
           split.isVertical,
           split.subviews.count >= 2,
           split.autosaveName?.contains("SidebarNavigationSplitView") == true {
            return split
        }
        for child in view.subviews {
            if let split = sidebarSplitView(in: child) { return split }
        }
        return nil
    }

    private func sidebarWidth(_ view: NSView, in split: NSSplitView) -> CGFloat? {
        guard view.frame.height > 0, view.frame.width > 0 else { return nil }
        return view.frame.width
    }
#endif

    @MainActor private func captureDemoScreenshot(scenario: String, at path: String) async {
        let cache = IPSWCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("DFUUtility-Screenshot-Cache"))
        #if DEBUG
        let screenshotUpdateCoordinator = scenario == "update" ? UpdateCoordinator.simulated() : nil
        #else
        let screenshotUpdateCoordinator: UpdateCoordinator? = nil
        #endif
        let model = AppModel(ipswService: DemoIPSWService(), discovery: DemoDiscovery(), cache: cache, diagnostics: DemoDiagnostics(), restoreEngine: DemoRestoreEngine(), dfuController: DemoDFUController(), updateCoordinator: screenshotUpdateCoordinator, isDemoMode: true, screenshotScenario: scenario)
        await model.load()
        let root: AnyView
        let size: NSSize
        if scenario == "firmware-chooser" {
            model.beginChoosingVersion()
            root = AnyView(VersionPicker(model: model, isPresented: .constant(true)))
            size = NSSize(width: 620, height: 450)
        } else if scenario == "manage-downloads" {
            root = AnyView(CacheManagerView(model: model, isPresented: .constant(true)))
            size = NSSize(width: 800, height: 800)
        } else if scenario == "iphone-guided-dfu" || scenario == "ipad-guided-dfu" {
            guard model.prepareMobileDFUAssistant(), let assistant = model.mobileDFUAssistant else { NSApp.terminate(nil); return }
            assistant.setDemoState(.detectedDFU)
            root = AnyView(MobileDFUAssistantView(model: assistant, isPresented: .constant(true)))
            size = NSSize(width: 700, height: 600)
        } else if scenario == "multiple-devices" {
            root = AnyView(ContentView(model: model))
            size = NSSize(width: 1040, height: 1000)
        } else if scenario.hasPrefix("device-capture") {
            root = AnyView(ContentView(model: model))
            if scenario.contains("narrow") {
                size = NSSize(width: 820, height: 620)
            } else if scenario.contains("default") {
                size = NSSize(width: 1040, height: 800)
            } else {
                size = NSSize(width: 1240, height: 860)
            }
        } else if scenario == "diagnostics" || scenario == "firmware-library" {
            root = AnyView(ContentView(model: model))
            size = NSSize(width: 1040, height: 800)
        } else if scenario == "about" {
            root = AnyView(AboutView())
            size = NSSize(width: 620, height: 620)
        } else if scenario == "update" {
            #if DEBUG
            await screenshotUpdateCoordinator?.check(manual: true)
            #endif
            root = AnyView(UpdateView(model: model))
            size = NSSize(width: 560, height: 420)
        } else {
            root = AnyView(ContentView(model: model))
            size = NSSize(width: 900, height: 760)
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

#if DEBUG
private struct SmokeUpdateService: UpdateServicing {
    let failsToSpawn: Bool
    func check(sourceRoot: URL) async throws -> AppUpdateState {
        .available(UpdateAvailability(currentVersion: "0.10.0", latestVersion: "0.10.1", currentCommit: "smoke-old", latestCommit: "smoke-new"))
    }

    func launch(sourceRoot: URL, oldPID: Int32, appURL: URL, resultURL: URL) throws {
        if failsToSpawn {
            AppLifecycleTrace.write("synthetic installer spawn failed")
            throw UpdateServiceError.launchFailed("synthetic installer failure")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        AppLifecycleTrace.write("synthetic installer spawn succeeded")
    }
}
#endif

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
        #if DEBUG
        let updateTest = DevelopmentUpdateAcceptance.isEnabled(arguments: CommandLine.arguments, bundleURL: Bundle.main.bundleURL)
        if updateTest {
            let cache = IPSWCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("DFUUtility-Update-Test-Cache"))
            _model = StateObject(wrappedValue: AppModel(ipswService: DemoIPSWService(), discovery: DemoDiscovery(), cache: cache, diagnostics: DemoDiagnostics(), restoreEngine: DemoRestoreEngine(), dfuController: DemoDFUController(), updateCoordinator: .simulated(), requiresPrivilegedHelperSetup: false, isUpdateTestMode: true))
        } else if demo {
            let cache = IPSWCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("DFUUtility-Demo-Cache"))
            let scenario = CommandLine.arguments.firstIndex(of: "--screenshot").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
            _model = StateObject(wrappedValue: AppModel(ipswService: DemoIPSWService(), discovery: DemoDiscovery(), cache: cache, diagnostics: DemoDiagnostics(), restoreEngine: DemoRestoreEngine(), dfuController: DemoDFUController(), isDemoMode: true, screenshotScenario: scenario))
        } else { _model = StateObject(wrappedValue: AppModel(applicationTerminator: AppKitApplicationTerminator(), targetDiscoveryAttempts: 3)) }
        #else
        if demo {
            let cache = IPSWCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("DFUUtility-Demo-Cache"))
            let scenario = CommandLine.arguments.firstIndex(of: "--screenshot").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
            _model = StateObject(wrappedValue: AppModel(ipswService: DemoIPSWService(), discovery: DemoDiscovery(), cache: cache, diagnostics: DemoDiagnostics(), restoreEngine: DemoRestoreEngine(), dfuController: DemoDFUController(), isDemoMode: true, screenshotScenario: scenario))
        } else { _model = StateObject(wrappedValue: AppModel(applicationTerminator: AppKitApplicationTerminator(), targetDiscoveryAttempts: 3)) }
        #endif
    }

    var body: some Scene {
        let window = MainWindowConfiguration.standard
        WindowGroup("DFUUtility") { ContentView(model: model).frame(minWidth: window.minimumWidth, minHeight: window.minimumHeight) }
            .defaultSize(width: window.defaultWidth, height: window.defaultHeight)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { model.requestManualUpdateCheck() }
                        .disabled(model.isDemoMode || model.isScreenshotPresentation)
                }
            }
        Settings { DiagnosticsView(report: model.doctorReport, shareableText: model.shareableDiagnosticsText, privilegeMode: model.privilegeMode, helperState: model.privilegedHelperState, registrationErrorDetails: model.helperRegistrationErrorDetails) }
    }
}
