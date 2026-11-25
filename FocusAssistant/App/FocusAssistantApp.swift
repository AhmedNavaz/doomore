import SwiftUI
import AppKit

@main
struct FocusAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = DiagnosticsModel()

    var body: some Scene {
        Window("FocusAssistant — Focus signals (test build)", id: "diagnostics") {
            DiagnosticsView(model: model)
                .onAppear { appDelegate.model = model }
                .onDisappear { model.stop(reason: "Window closed — camera off") }
        }
        .defaultSize(width: 920, height: 760)
        MenuBarExtra("FocusAssistant", systemImage: model.isCapturing ? "camera.fill" : "camera") {
            Text(model.status)
            Button("Stop camera") { model.stop() }.disabled(!model.isRequested)
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: DiagnosticsModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // When the camera is already off, quit at once. Waiting for a main-queue reply here
        // hung the self-test: `terminate` called from a main-queue block runs a nested run
        // loop that does not drain the main queue, so the reply never arrived (25 Nov 2026).
        guard let model, model.cameraMayBeOn else { return .terminateNow }
        model.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
