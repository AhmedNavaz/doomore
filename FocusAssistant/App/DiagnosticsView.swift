import SwiftUI
import AVFoundation

struct DiagnosticsView: View {
    @ObservedObject var model: DiagnosticsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Focus signals").font(.largeTitle.bold())
                        Text("Test build · everything runs on this Mac").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(model.isStopping ? "Stopping camera" : (model.isCapturing ? "Camera active" : "Camera off"),
                          systemImage: model.isCapturing ? "video.fill" : "video.slash")
                        .foregroundStyle(model.isCapturing ? .green : .secondary)
                }

                Text("Press Start, or run a spoken Guided test. The app watches your head position, your eyes, your hands, whether the keyboard or mouse is in use and, if ticked, the kind of sound nearby. It feeds those signals into the Milestone 1 behavioral engine (45 s grace period, rolling short-pickup counter, and work-app gating). Pictures and audio are never saved or uploaded.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Picker("Camera", selection: $model.selectedCameraID) {
                        Text("Select a camera").tag("")
                        ForEach(model.cameras) { camera in
                            Text(camera.name + (camera.builtIn ? " (built-in)" : " (external)")).tag(camera.id)
                        }
                    }.disabled(model.isRequested)
                    Button("Refresh", action: model.refreshCameras).disabled(model.isRequested)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Button("Start", action: model.start)
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isRequested || model.isStopping || model.selectedCameraID.isEmpty)
                        Button("Guided behavior test") { model.startGuidedCheck(.behaviorEngine) }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                            .disabled(model.isGuiding || model.isStopping || model.selectedCameraID.isEmpty
                                      || (model.isRequested && !model.isCapturing))
                            .help("Speaks 6 steps (~2.5 min) to test idle screen, keyboard typing, quick reply grace, short pickup count, and the 45 s sustained phone reminder.")
                        Button("Guided phone check") { model.startGuidedCheck(.phoneSignals) }
                            .disabled(model.isGuiding || model.isStopping || model.selectedCameraID.isEmpty
                                      || (model.isRequested && !model.isCapturing))
                            .help("Starts the camera if needed and speaks four steps: look at the screen, shift position while moving the mouse, use your phone, look at the screen again. About 62 seconds.")
                        Button("Stop") { model.wantsMonitoring ? model.stopMonitoring() : model.stop() }.disabled(!model.isRequested)
                    }
                    HStack(spacing: 16) {
                        Toggle("Listen for sounds (microphone)", isOn: $model.listenForSounds).disabled(model.isRequested)
                        Toggle("Keep running when I switch apps", isOn: $model.keepRunningInBackground)
                    }.toggleStyle(.checkbox)
                }
                Text(model.status).font(.callout).accessibilityIdentifier("captureStatus")

                if let instruction = model.guidedInstruction {
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.wave.2.fill").font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.activeGuidedSuite.title).font(.caption).foregroundStyle(.secondary)
                            Text(instruction).font(.title3.bold())
                        }
                        Spacer()
                        Text("\(model.guidedSecondsLeft) s").font(.title2.monospacedDigit())
                    }
                    .padding(12)
                    .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("guidedInstruction")
                }

                if let reminder = model.activeReminder {
                    reminderBanner(reminder)
                }

                if let report = model.lastGuidedReport {
                    guidedReportView(report)
                }

                behaviorView

                estimateView

                if model.showPreview && model.isCapturing {
                    ZStack {
                        CameraPreview(preview: model.previewLayer)
                        DetectionOverlay(phones: model.metrics.phones, imageSize: model.metrics.imageSize, mirrored: model.mirrored)
                    }
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Live local camera preview")
                } else {
                    RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.9))
                        .overlay {
                            VStack(spacing: 10) {
                                Image(systemName: model.isCapturing ? "eye.slash" : "video.slash").font(.largeTitle)
                                Text(model.isCapturing ? "Preview hidden · camera still on" : "Camera is off")
                            }.foregroundStyle(.white.opacity(0.8))
                        }.frame(height: 120)
                }
                HStack {
                    Toggle("Show preview", isOn: $model.showPreview)
                    Toggle("Mirror preview", isOn: $model.mirrored)
                    Spacer()
                    Text("Continuity Camera excluded").font(.caption).foregroundStyle(.secondary)
                }.toggleStyle(.checkbox)

                signalsView

                DisclosureGroup("Technical counters") { metricsView.padding(.top, 6) }

                Divider()
                Toggle("Share readings with the coding agent", isOn: $model.shareReadings).toggleStyle(.checkbox)
                Text("While ticked, the numbers and label names shown above are also written to this Mac’s system log about once a second, so the agent can read what the app saw. No pictures, audio, key presses or app names are written.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(24)
        }.frame(minWidth: 760, minHeight: 650)
    }

    // MARK: Guided test result

    private func guidedReportView(_ report: GuidedReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(report.suite.title + " result",
                      systemImage: report.allPassed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(report.allPassed ? .green : .orange)
                Spacer()
                Button("Dismiss", action: model.dismissGuidedReport).controlSize(.small)
            }
            ForEach(report.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: iconName(for: item.status))
                        .foregroundStyle(color(for: item.status))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.callout.weight(.semibold))
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((report.allPassed ? Color.green : Color.orange).opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("guidedReport")
    }

    private func iconName(for status: GuidedReport.CheckItem.Status) -> String {
        switch status {
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func color(for status: GuidedReport.CheckItem.Status) -> Color {
        switch status {
        case .pass: return .green
        case .fail: return .red
        case .info: return .orange
        }
    }

    // MARK: Behavioral engine (Milestone 1)

    private func reminderBanner(_ reminder: InterventionEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gentle focus reminder (Milestone 1 in-window preview)").font(.caption).foregroundStyle(.secondary)
                    Text(reminder.kind.headline).font(.headline)
                }
            }
            HStack(spacing: 10) {
                Button("Back to work", action: model.acknowledgeBackToWork)
                    .buttonStyle(.borderedProminent)
                Button("Taking a break (5 min)", action: model.takeBreak)
                Button("Quick reply / Not a distraction", action: model.markNotADistraction)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("behaviorReminderBanner")
    }

    private var behaviorView: some View {
        let b = model.behavior
        return GroupBox("Behavioral engine (Milestone 1)") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(b.state.displayName)
                        .font(.title3.bold())
                        .accessibilityIdentifier("behaviorState")
                    Spacer()
                    Picker("Work context", selection: $model.workContextMode) {
                        ForEach(WorkContextMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    Toggle("Pause", isOn: $model.isUserPaused).toggleStyle(.checkbox)
                }

                if !b.reasons.isEmpty {
                    Text("Reasons: " + b.reasons.map(\.label).joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if b.state == .candidate || b.state == .sustainedPhoneUse {
                    ProgressView(value: b.graceProgress) {
                        Text("Sustained evidence: \(Self.duration(b.evidenceDuration)) / 45 s grace")
                            .font(.caption.monospacedDigit())
                    }
                }

                if b.idleStretchSeconds > 0 {
                    ProgressView(value: min(1, b.idleStretchSeconds / 90)) {
                        Text("No keyboard or mouse: \(Self.duration(b.idleStretchSeconds)) / 90 s · looking elsewhere \(Int((b.idleStretchCueShare * 100).rounded()))% / 50%")
                            .font(.caption.monospacedDigit())
                    }
                }

                HStack(spacing: 18) {
                    Text("Short pickups (12 min): \(b.recentPickupCount) / 4")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if b.cooldownRemaining > 0 {
                        Text("Cooldown: \(Self.duration(b.cooldownRemaining))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if b.breakRemaining > 0 {
                        Text("Break: \(Self.duration(b.breakRemaining))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.orange)
                        Button("End break", action: model.endBreakEarly).controlSize(.small)
                    }
                    Spacer()
                    Text(frontmostSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private var frontmostSummary: String {
        let app = model.frontmostAppName.isEmpty ? "Unknown app" : model.frontmostAppName
        if model.frontmostIsMeetingApp { return "Frontmost: \(app) (meeting suppressor)" }
        if model.workContextMode == .selectedApps {
            return "Frontmost: \(app) (\(model.frontmostIsWorkApp ? "work app" : "non-work"))"
        }
        return "Frontmost: \(app)"
    }

    // MARK: The guess

    private var estimateView: some View {
        GroupBox("What the app thinks you are doing") {
            VStack(alignment: .leading, spacing: 8) {
                if let estimate = model.estimate {
                    Text(estimate.headline).font(.title2.bold()).accessibilityIdentifier("activityHeadline")
                    Text("for \(Self.duration(estimate.secondsInState))").foregroundStyle(.secondary).monospacedDigit()
                    if estimate.possiblePhoneUse {
                        Label("Possible phone use", systemImage: "iphone")
                            .font(.headline).foregroundStyle(.orange)
                            .accessibilityIdentifier("possiblePhoneUse")
                    }
                    Button("Set straight-ahead again", action: model.recalibrate)
                        .help("Look at the screen, then press this. The app learns that head position as straight-ahead.")
                } else if model.isCapturing {
                    Text("Waiting for the first reading…").foregroundStyle(.secondary)
                } else {
                    Text("Not running").font(.title3).foregroundStyle(.secondary)
                    Text("Look at the screen for the first three seconds after Start. The app learns that head position as straight-ahead.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("A guess from simple rules that have not been checked for accuracy. Head or eyes away from the screen with idle keyboard and mouse can also mean reading paper, writing, eating or talking to someone.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    // MARK: Raw signals

    private var signalsView: some View {
        let signals = model.metrics.signals
        let input = model.metrics.input
        return GroupBox("Signals") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                signal("Head", headText(signals))
                signal("Person in the picture", signals.map { "\(Int(($0.personCoverage * 100).rounded()))% of the picture" } ?? "—")
                signal("Hands in view", signals.map { "\($0.handCount)" } ?? "—")
                signal("Keyboard", input.map { "last key \(Self.ago($0.keyboard))" } ?? "—")
                signal("Mouse or trackpad", input.map { "last used \(Self.ago($0.pointer))" } ?? "—")
                signal("Sound", soundText)
                signal("Phone in the picture", phoneText(signals?.classifier))
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private func signal(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }

    private func headText(_ signals: VisionSignals?) -> String {
        guard let signals else { return "—" }
        guard let head = signals.head else {
            return "No face found · \(Int((signals.personCoverage * 100).rounded()))% of the picture is a person"
        }
        var parts: [String] = []
        // Which way a tilt goes is not settled yet (see HeadPose.pitch), so only its size is shown.
        if let tilt = model.estimate?.tilt { parts.append("tilted \(Self.degrees(abs(tilt)))") }
        if let off = model.estimate?.yawOff { parts.append("turned \(Self.degrees(off))") }
        if let eyes = model.estimate?.eyeRatio { parts.append("eyes \(Int((eyes * 100).rounded()))% as open as straight-ahead") }
        let raw = "raw pitch \(ReadingText.signed(head.pitch, 0))°, yaw \(ReadingText.signed(head.yaw, 0))°, roll \(ReadingText.signed(head.roll, 0))°"
        return (parts.isEmpty ? "Face found" : parts.joined(separator: " · ")) + " (\(raw))"
    }

    private var soundText: String {
        guard model.isCapturing else { return model.soundStatus == .off ? "—" : model.soundStatus.text }
        guard model.soundStatus == .listening else { return model.soundStatus.text }
        guard let sound = model.sound, !sound.top.isEmpty else { return "Listening — first result takes about three seconds" }
        return sound.top.map { "\($0.label) \(ReadingText.number(Double($0.confidence), 2))" }.joined(separator: " · ")
    }

    /// The whole-image `phone` label is shown as a raw number only. It scored 0.03 with a
    /// phone held in plain view (25 Nov 2026), so the guess above does not use it.
    private func phoneText(_ reading: ClassifierReading?) -> String {
        guard let reading else { return "—" }
        guard let confidence = reading.phoneConfidence, let above = reading.labelsAbovePhone else {
            return "not reported by this classifier"
        }
        let top = reading.topLabels.prefix(3).map { "\($0.label) \(ReadingText.number(Double($0.confidence), 2))" }.joined(separator: ", ")
        return "phone label \(ReadingText.number(Double(confidence), 4)), \(above) of \(reading.labelCount) labels higher · top: \(top) (weak signal, not used in the guess)"
    }

    private static func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }

    private static func ago(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "not seen" }
        return seconds < 1 ? "just now" : "\(duration(seconds)) ago"
    }

    private static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        let whole = Int(seconds)
        return whole < 60 ? "\(whole) s" : "\(whole / 60) min \(whole % 60) s"
    }

    // MARK: Counters

    private var metricsView: some View {
        let m = model.metrics
        return GroupBox("Reset on Start · not saved") {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                GridRow {
                    metric("Frames delivered", "\(m.deliveredFrames)")
                    metric("Frames dropped", "\(m.droppedFrames)")
                    metric("Frames not analysed", m.inferenceConfigured ? "\(m.skippedFrames)" : "n/a")
                    metric("Frames analysed", "\(m.inferenceCount)")
                }
                GridRow {
                    metric("Frame size", "\(Int(m.imageSize.width)) × \(Int(m.imageSize.height))")
                    metric("Delivered fps", String(format: "%.1f", m.captureFPS))
                    metric("Analysed per second", String(format: "%.2f", m.inferenceFPS))
                    metric("Latest analysis", String(format: "%.1f ms", m.lastLatencyMS))
                }
                GridRow {
                    metric("Mean analysis", String(format: "%.1f ms", m.meanLatencyMS))
                    metric("p95 analysis", String(format: "%.1f ms", m.p95LatencyMS))
                    Text("Analysis times cover the last 300 samples.\nCPU, memory and power are not measured here.")
                        .font(.caption).foregroundStyle(.secondary).gridCellColumns(2)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }
}

private struct CameraPreview: NSViewRepresentable {
    let preview: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> PreviewView { PreviewView(preview: preview) }
    func updateNSView(_ view: PreviewView, context: Context) { }
    static func dismantleNSView(_ view: PreviewView, coordinator: ()) { view.preview.removeFromSuperlayer() }
}

private final class PreviewView: NSView {
    let preview: AVCaptureVideoPreviewLayer

    init(preview: AVCaptureVideoPreviewLayer) {
        self.preview = preview
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); preview.frame = bounds }

}

/// Ready for real localized observations only. No classifier label is converted
/// into a box and no synthetic rectangle is shown in the running app.
private struct DetectionOverlay: View {
    let phones: [PhoneDetection]
    let imageSize: CGSize
    let mirrored: Bool

    var body: some View {
        GeometryReader { geometry in
            ForEach(Array(phones.enumerated()), id: \.offset) { _, phone in
                if let rect = PreviewGeometry.rect(for: phone.boundingBox, imageSize: imageSize, viewSize: geometry.size, mirrored: mirrored) {
                    Rectangle().stroke(.green, lineWidth: 2)
                        .overlay(alignment: .topLeading) {
                            Text("\(phone.label) \(phone.confidence, specifier: "%.2f")")
                                .font(.caption.monospaced()).padding(3).background(.black.opacity(0.7))
                        }
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }.allowsHitTesting(false)
    }
}
