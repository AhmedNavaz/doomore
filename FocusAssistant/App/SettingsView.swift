import SwiftUI
import AppKit

/// How firmly the app pushes back. Each style sets sensitivity and the warning in one choice.
enum CoachStyle: String, CaseIterable, Identifiable {
    case gentle, standard, strict
    var id: String { rawValue }
    var title: String { switch self { case .gentle: return "Gentle"; case .standard: return "Standard"; case .strict: return "Strict" } }
    var blurb: String {
        switch self {
        case .gentle: return "Infrequent, quiet notifications. You stay in control."
        case .standard: return "A full-screen warning that unlocks after a short pause."
        case .strict: return "Responds quickly, asks you to solve a problem, and hides other apps."
        }
    }
}

/// Settings window, in the standard macOS tabbed layout.
struct SettingsView: View {
    @ObservedObject var model: DiagnosticsModel

    private var currentStyle: CoachStyle? { CoachStyle.allCases.first { model.matches($0) } }

    var body: some View {
        TabView {
            remindersTab.tabItem { Label("Reminders", systemImage: "bell.badge") }
            workTab.tabItem { Label("Work", systemImage: "briefcase") }
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 540, height: 560)
    }

    private var remindersTab: some View {
        Form {
            Section {
                Picker("Intensity", selection: Binding(
                    get: { currentStyle },
                    set: { if let style = $0 { model.apply(style) } })) {
                    ForEach(CoachStyle.allCases) { Text($0.title).tag(Optional($0)) }
                    if currentStyle == nil { Text("Custom").tag(Optional<CoachStyle>.none) }
                }
                .pickerStyle(.segmented)
                Text(currentStyle?.blurb ?? "Custom combination from the options below.")
                    .font(.callout).foregroundStyle(.secondary)
                if let notice = model.sensitivityNotice {
                    Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.orange)
                }
            }
            Section("Activity") {
                LabeledContent("Reminders you acted on", value: "\(model.confirmedCount)")
                LabeledContent("Marked not a distraction", value: "\(model.falseAlarmCount)")
                Button("Preview warning") { model.previewAlert() }
                    .disabled(model.alertStyle != .screenAndSound)
            }
            Section("Customize") {
                Picker("Sensitivity", selection: $model.sensitivity) {
                    ForEach(Sensitivity.allCases) { Text($0.label).tag($0) }
                }
                Picker("Delivery", selection: $model.alertStyle) {
                    ForEach(AlertStyle.allCases) { Text($0.label).tag($0) }
                }
                Picker("To dismiss", selection: $model.alertChallenge) {
                    ForEach(AlertChallenge.allCases) { Text($0.label).tag($0) }
                }
                .disabled(model.alertStyle != .screenAndSound)
                Toggle("Show a motivational line", isOn: $model.showQuote)
                    .disabled(model.alertStyle != .screenAndSound)
                Toggle("Hide other apps while warning", isOn: $model.hideOtherApps)
                    .disabled(model.alertStyle != .screenAndSound)
                Text(model.sensitivity.detail).font(.callout).foregroundStyle(.secondary)
                Text("Hiding apps never closes them. Three false alarms in a row lower the sensitivity one step.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var workTab: some View {
        Form {
            Section {
                Picker("Remind me", selection: $model.workContextMode) {
                    ForEach(WorkContextMode.allCases) { Text($0.label).tag($0) }
                }
                Text("Video-call apps always pause reminders.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Work apps") {
                Text("Used by “Selected work apps”. Reminders appear only while one of these is in front.")
                    .font(.callout).foregroundStyle(.secondary)
                workAppList
            }
        }
        .formStyle(.grouped)
    }

    private var generalTab: some View {
        Form {
            Section("Startup") {
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                Text("Monitoring never starts by itself. Choose Start from the menu bar.")
                    .font(.callout).foregroundStyle(.secondary)
                if let error = model.launchAtLoginError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                if LaunchAtLogin.needsApproval {
                    Text("macOS needs your approval in System Settings → General → Login Items.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            Section("Privacy") {
                Text("The camera is analyzed on this Mac. No images are saved and nothing is sent anywhere. The microphone is never used.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Show welcome screen") { model.showOnboarding = true }
            }
        }
        .formStyle(.grouped)
    }

    private var workAppList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.workBundleIDs.isEmpty {
                Text("No work apps. Add at least one, or use Manual work mode.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.workBundleIDs, id: \.self) { id in
                HStack {
                    Text(Self.appName(for: id))
                    Text(id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button(role: .destructive) { model.removeWorkApp(id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(Self.appName(for: id))")
                }
            }
            HStack {
                Menu("Add a running app") {
                    ForEach(Self.runningApps().filter { !model.workBundleIDs.contains($0.id) }, id: \.id) { app in
                        Button(app.name) { model.addWorkApp(app.id) }
                    }
                }
                Button("Choose an app…") { chooseApp() }
                Spacer()
                Button("Reset to defaults") { model.resetWorkApps() }
            }
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        model.addWorkApp(id)
    }

    private static func runningApps() -> [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// First-launch explanation of what the app watches and what it never does.
struct OnboardingView: View {
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to Doomore").font(.title.bold())
            Text("It nudges you when you drift to your phone while you work. Everything runs on this Mac.")
            VStack(alignment: .leading, spacing: 8) {
                Label("Uses the camera to read your head and eye direction and whether your hands show. It saves no pictures and sends nothing anywhere.", systemImage: "video")
                Label("Notices whether the keyboard or mouse is in use, and the name of the app in front. It never reads what you type or any window content.", systemImage: "keyboard")
                Label("Never uses the microphone while monitoring.", systemImage: "mic.slash")
                Label("Reminders arrive as notifications. Say “Back to work”, “Taking a break” or “Not a distraction” to answer them.", systemImage: "bell")
                Label("Monitoring is off every time the app opens. Turn it on from the menu bar icon.", systemImage: "menubar.rectangle")
            }
            Text("macOS will ask for camera and notification access the first time you start monitoring. Sensitivity, work apps and open-at-login are in Settings.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Got it", action: finish).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
