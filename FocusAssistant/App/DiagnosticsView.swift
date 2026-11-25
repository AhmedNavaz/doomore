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

                Text("Press Start. The app watches your head position, your eyes, your hands, whether the keyboard or mouse is in use and, if ticked, the kind of sound nearby. It then shows its guess about what you are doing. A phone held below the camera cannot be seen, so the guess relies on your head or eyes being away from the screen while the keyboard and mouse are idle. Guided phone check speaks three short steps (about 47 s) so the readings can be compared; it keeps running if you switch apps and turns the camera off when it ends. Pictures and audio are never saved or uploaded. No reminders are implemented.")
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
                HStack(spacing: 14) {
                    Button("Start", action: model.start)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRequested || model.isStopping || model.selectedCameraID.isEmpty)
                    Button("Guided phone check", action: model.startGuidedCheck)
                        .disabled(model.isGuiding || model.isStopping || model.selectedCameraID.isEmpty
                                  || (model.isRequested && !model.isCapturing))
                        .help("Starts the camera if needed and speaks four steps: look at the screen, shift position while moving the mouse, use your phone, look at the screen again. About 62 seconds. Keeps running if you switch apps.")
                    Button("Stop") { model.stop() }.disabled(!model.isRequested)
                    Toggle("Listen for sounds (microphone)", isOn: $model.listenForSounds).disabled(model.isRequested)
                    Toggle("Keep running when I switch apps", isOn: $model.keepRunningInBackground)
                }.toggleStyle(.checkbox)
                Text(model.status).font(.callout).accessibilityIdentifier("captureStatus")

                if let instruction = model.guidedInstruction {
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.wave.2.fill").font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Guided phone check").font(.caption).foregroundStyle(.secondary)
                            Text(instruction).font(.title3.bold())
                        }
                        Spacer()
                        Text("\(model.guidedSecondsLeft) s").font(.title2.monospacedDigit())
                    }
                    .padding(12)
                    .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("guidedInstruction")
                }

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
