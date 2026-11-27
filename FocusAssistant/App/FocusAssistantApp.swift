import SwiftUI
import AppKit
import Combine

@main
struct FocusAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = DiagnosticsModel()

    var body: some Scene {
        #if DEBUG
        // Developer test window (live signals, guided checks, shared testing). Debug builds only;
        // a release build ships without it, and the welcome screen opens from the app delegate.
        Window("Doomore — Focus signals (test build)", id: "diagnostics") {
            DiagnosticsView(model: model)
                .sheet(isPresented: $model.showOnboarding) {
                    OnboardingView(finish: model.finishOnboarding)
                }
                .onAppear {
                    appDelegate.model = model
                    model.diagnosticsWindowAppeared()
                }
                .onDisappear { model.diagnosticsWindowClosed() }
        }
        .defaultSize(width: 920, height: 760)
        #endif
        Window("Doomore Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.monitoringStatus.symbol)
                .accessibilityLabel("Doomore: \(model.monitoringStatus.line)")
                .onAppear {
                    appDelegate.model = model
                    #if !DEBUG
                    appDelegate.watchWelcome()
                    #endif
                }
        }
    }
}

/// The menu bar menu (spec §1.2): status, start/stop, pause, break, notification state.
private struct MenuBarContent: View {
    @ObservedObject var model: DiagnosticsModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let status = model.monitoringStatus
        Text(status.line)
        if model.wantsMonitoring, model.notificationPermission == .denied {
            Text("Notifications are off · reminders show only in the window")
            Button("Open Notification Settings…", action: model.openNotificationSettings)
        }
        if model.workContextMode == .inactive {
            Button("Turn reminders on (manual work mode)") { model.workContextMode = .manualWork }
        }
        Divider()
        if model.wantsMonitoring {
            if model.monitoringPaused || model.breakSecondsLeft > 0 {
                Button(model.breakSecondsLeft > 0 ? "End break now" : "Resume", action: model.resumeMonitoring)
            } else {
                Button("Pause", action: model.pauseMonitoring)
                Button("Take a 5 min break", action: model.takeBreak)
            }
            Button("Stop monitoring", action: model.stopMonitoring)
        } else {
            Button("Start monitoring", action: model.startMonitoring)
                .disabled(model.isGuiding)
        }
        Divider()
        Button("Settings…") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")
        #if DEBUG
        Button("Show focus signals window…") {
            openWindow(id: "diagnostics")
            NSApp.activate(ignoringOtherApps: true)
        }
        #endif
        Button("Quit Doomore") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: DiagnosticsModel?
    private var welcomeWindow: NSWindow?
    private var welcomeWatch: AnyCancellable?

    /// Release builds have no diagnostics window to hold the welcome sheet, so the welcome
    /// screen gets its own window, shown on first launch and from Settings.
    func watchWelcome() {
        guard let model, welcomeWatch == nil else { return }
        welcomeWatch = model.$showOnboarding.removeDuplicates().sink { [weak self] show in
            Task { @MainActor in self?.setWelcome(visible: show) }
        }
    }

    private func setWelcome(visible: Bool) {
        guard let model else { return }
        if !visible { welcomeWindow?.close(); welcomeWindow = nil; return }
        guard welcomeWindow == nil else { return }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Doomore"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(finish: model.finishOnboarding))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow = window
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Picks up a change made in System Settings → Notifications.
        model?.refreshNotificationPermission()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // When the camera is already off, quit at once. Waiting for a main-queue reply here
        // hung the self-test: `terminate` called from a main-queue block runs a nested run
        // loop that does not drain the main queue, so the reply never arrived (25 Nov 2026).
        guard let model, model.cameraMayBeOn else { return .terminateNow }
        model.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
