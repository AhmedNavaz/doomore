import AppKit
import AVFoundation
import Combine

@MainActor
final class DiagnosticsModel: ObservableObject {
    @Published private(set) var status = "Stopped — camera off"
    @Published private(set) var isRequested = false
    @Published private(set) var isCapturing = false
    @Published private(set) var isStopping = false
    @Published private(set) var cameras: [CameraChoice] = []
    @Published var selectedCameraID = ""
    @Published var showPreview = true { didSet { updatePreview() } }
    @Published var mirrored = true { didSet { updatePreview() } }
    /// Ticked by default because sound is one of the requested signals. The microphone is
    /// opened only by Start, and only after macOS permission.
    @Published var listenForSounds = true
    /// Off by default: the camera then stops as soon as this window is not in front.
    @Published var keepRunningInBackground = false
    /// Writes text readings to the macOS log for shared testing. See `SharedLog`.
    @Published var shareReadings = true
    @Published private(set) var metrics = CaptureMetrics()
    @Published private(set) var estimate: ActivityEstimate?
    @Published private(set) var sound: SoundReading?
    @Published private(set) var soundStatus = SoundStatus.off
    /// What the guided check asks for right now; nil when no check is running.
    @Published private(set) var guidedInstruction: String?
    @Published private(set) var guidedSecondsLeft = 0

    /// Nil for a normal launch. Set by `--selftest`, see `SelfTestPlan`.
    let selfTest = SelfTestPlan.parse(ProcessInfo.processInfo.arguments)
    private var selfTestStarted = false
    private var selfTestEnded = false
    private var selfTestRunning: Bool { selfTest != nil && selfTestStarted && !selfTestEnded }
    /// 0 waiting for permission, 1 starting the camera, 2 running. Each phase has its own time limit.
    private var selfTestPhase = 0

    private var token = RunToken()
    private var estimator = ActivityEstimator()
    private var summary = RunSummary()
    /// True from the camera's start until the run's summary has been logged.
    private var runActive = false
    private var runStartTime = 0.0
    private var lastReadingLogTime = 0.0
    private var lastLoggedState = ""
    /// Guided check: requested and waiting for the camera, or running since `guidedStart`.
    private var guidedPending = false
    private var guidedStart: Double?
    private var guidedPhaseIndex: Int?
    private var guidedRun = UUID()
    private var guidedSummary = GuidedSummary()
    private let speech = AVSpeechSynthesizer()
    var isGuiding: Bool { guidedPending || guidedStart != nil }
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private lazy var camera = CameraService { [weak self] id, event in
        // CameraService delivers only copied metadata, exclusively on the main queue.
        self?.receive(id: id, event: event)
    }
    private lazy var soundMonitor = SoundMonitor(
        onReading: { [weak self] reading in self?.receive(sound: reading) },
        onStatus: { [weak self] status in self?.receive(soundStatus: status) })

    var previewLayer: AVCaptureVideoPreviewLayer { camera.previewLayer }

    /// False once the camera is fully released; quitting then needs no asynchronous shutdown.
    var cameraMayBeOn: Bool { isRequested || isCapturing || isStopping }

    private func updatePreview() { camera.setPreview(enabled: showPreview, mirrored: mirrored) }

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willPowerOffNotification] {
            observe(workspace, name) { [weak self] in self?.stop(reason: "Session inactive — Start again when ready") }
        }
        // Default policy: the camera runs only while this window is in front. Ticking
        // "Keep running when I switch apps" lifts that for app switches, hiding and
        // minimizing, and so does a guided check, which lasts under a minute and turns the
        // camera off when it ends. Sleep, lock, screen sleep and closing the window always stop it.
        for name in [NSApplication.didResignActiveNotification, NSApplication.didHideNotification,
                     NSWindow.didMiniaturizeNotification] {
            observe(.default, name) { [weak self] in
                guard let self, self.isRequested, !self.keepRunningInBackground, !self.isGuiding else { return }
                self.stop(reason: "Window not in front — camera off")
            }
        }
        observe(.default, NSWindow.willCloseNotification) { [weak self] in
            // An unattended self-test must not be ended by an unrelated window closing.
            guard let self, self.isRequested, !self.selfTestRunning else { return }
            self.stop(reason: "Window closed — camera off")
        }
        observe(.default, ProcessInfo.thermalStateDidChangeNotification) { [weak self] in
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .serious || thermal == .critical {
                self?.stop(reason: "Thermal pressure — camera off")
            }
        }
        refreshCameras()
    }

    deinit { observers.forEach { $0.0.removeObserver($0.1) } }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping () -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in action() }
        observers.append((center, observer))
    }

    func refreshCameras() {
        guard !isRequested else { return }
        camera.discover { [weak self] choices in
            guard let self else { return }
            self.cameras = choices
            if !choices.contains(where: { $0.id == self.selectedCameraID }) {
                // External cameras require an explicit selection; no automatic fallback.
                self.selectedCameraID = choices.first(where: \.builtIn)?.id ?? ""
            }
            self.beginSelfTestIfRequested()
        }
    }

    // MARK: Start

    func start() {
        guard !isRequested, !isStopping, !selectedCameraID.isEmpty else { return }
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal != .serious, thermal != .critical else {
            status = "Thermal pressure — wait before starting"
            return
        }
        let id = token.begin()
        isRequested = true
        metrics = CaptureMetrics()
        estimate = nil
        sound = nil
        soundStatus = .off
        estimator.reset()
        summary = RunSummary()
        lastReadingLogTime = 0
        lastLoggedState = ""
        status = "Checking camera permission…"
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            prepareMicrophone(id: id)
        case .notDetermined:
            // Permission prompts are raised only by Start: the visible button, or a self-test,
            // which then waits for the answer. macOS asks again after every rebuild of an
            // ad-hoc signed app, because the stored answer is tied to the exact build.
            status = "Waiting for your answer to the camera prompt…"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.token.accepts(id) else {
                        // The system prompt can deactivate this window, which cancels the
                        // request. Show the answer, but never start capture from it.
                        self.reportAnswerToCancelledRequest("Camera", granted: granted)
                        return
                    }
                    if granted { self.prepareMicrophone(id: id) }
                    else { self.stop(reason: "Camera permission denied — enable it in System Settings → Privacy & Security → Camera") }
                }
            }
        case .denied, .restricted:
            stop(reason: "Camera permission unavailable — check System Settings → Privacy & Security → Camera")
        @unknown default:
            stop(reason: "Unknown permission state — camera off")
        }
    }

    /// Settles microphone permission before the camera opens, so a prompt never interrupts a
    /// running capture. A missing or refused microphone turns sound off; it never blocks Start.
    private func prepareMicrophone(id: UUID) {
        guard listenForSounds else { beginCapture(id: id); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginCapture(id: id)
        case .notDetermined:
            status = "Waiting for your answer to the microphone prompt…"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.token.accepts(id) else {
                        self.reportAnswerToCancelledRequest("Microphone", granted: granted)
                        return
                    }
                    if !granted { self.soundStatus = .denied }
                    self.beginCapture(id: id)
                }
            }
        default:
            soundStatus = .denied
            beginCapture(id: id)
        }
    }

    private func reportAnswerToCancelledRequest(_ device: String, granted: Bool) {
        // A newer request or an unfinished teardown owns the status line.
        guard !isRequested, !isStopping else { return }
        status = granted
            ? "\(device) permission granted — camera still off. Press Start to begin."
            : "\(device) permission denied — enable it in System Settings → Privacy & Security → \(device)"
    }

    private func beginCapture(id: UUID) {
        guard token.accepts(id), NSApp.isActive || keepRunningInBackground || isGuiding else {
            stop(reason: "Return to this window and press Start")
            return
        }
        status = "Starting camera… (the first start loads the vision models and can take several seconds)"
        if selfTestRunning {
            selfTestPhase = 1
            selfTestLimit(30) { "camera did not start within 30 s" }
        }
        camera.start(id: id, cameraID: selectedCameraID, mode: selfTest?.captureOnly == true ? .captureOnly : .signals)
    }

    // MARK: Stop

    func stop(reason: String = "Stopped — camera off") {
        if selfTestRunning {
            endSelfTest(failure: reason) // Anything that stops an unattended run ends it as a failure.
            return
        }
        performStop(reason: reason, completion: nil)
    }

    private func performStop(reason: String, completion: (() -> Void)?) {
        token.cancel() // Invalidate delayed permission and frame results immediately.
        cancelGuided()
        isRequested = false
        isStopping = true
        let soundAtStop = soundStatus // Cleared below; the summary reports what ran.
        clearLiveReadings()
        status = "Stopping camera…"
        soundMonitor.stop()
        let began = ProcessInfo.processInfo.systemUptime
        camera.stop { [weak self] in
            guard let self else { return }
            self.finishRun(reason: reason, stopMilliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1_000,
                           soundStatus: soundAtStop)
            if !self.isRequested {
                self.isCapturing = false
                self.isStopping = false
                self.status = reason
            }
            completion?()
        }
    }

    func shutdown(completion: @escaping () -> Void) {
        token.cancel()
        cancelGuided()
        isRequested = false
        isCapturing = false
        soundMonitor.stop()
        let began = ProcessInfo.processInfo.systemUptime
        camera.stop { [weak self] in
            self?.finishRun(reason: "App quit", stopMilliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1_000)
            completion()
        }
    }

    private func clearLiveReadings() {
        metrics.signals = nil
        metrics.input = nil
        metrics.phones = []
        estimate = nil
        sound = nil
        if soundStatus == .listening || soundStatus == .starting { soundStatus = .off }
    }

    /// Logs the run's totals once. `stopMilliseconds` is nil when the camera stopped itself.
    private func finishRun(reason: String, stopMilliseconds: Double?, soundStatus: SoundStatus? = nil) {
        guard runActive else { return }
        runActive = false
        guard shareReadings else { return }
        summary.lines(metrics: metrics, baseline: estimator.baseline, soundStatus: soundStatus ?? self.soundStatus,
                      reason: reason, stopMilliseconds: stopMilliseconds).forEach(SharedLog.write)
    }

    /// Learns the straight-ahead head position again from the next few samples.
    func recalibrate() {
        guard isCapturing else { return }
        estimator.recalibrate()
        if shareReadings { SharedLog.write("EVENT recalibrate") }
    }

    // MARK: Events

    private func receive(id: UUID, event: CaptureEvent) {
        guard token.accepts(id) else { return }
        switch event {
        case let .started(name, previewAttached):
            guard NSApp.isActive || keepRunningInBackground || isGuiding else { stop(reason: "Window not in front — camera off"); return }
            isCapturing = true
            runActive = true
            runStartTime = ProcessInfo.processInfo.systemUptime
            status = (selfTest != nil ? "Self-test · " : "") + (previewAttached
                ? "Camera active · \(name)"
                : "Camera active · \(name) · preview unavailable (frames still processed)")
            if shareReadings { SharedLog.write("EVENT started camera=\"\(name)\" preview=\(previewAttached) sounds=\(listenForSounds)") }
            if listenForSounds, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                soundStatus = .starting
                soundMonitor.start()
            }
            if let plan = selfTest, selfTestRunning {
                selfTestPhase = 2
                // A guided self-test ends itself when the check finishes; this is only a backstop.
                DispatchQueue.main.asyncAfter(deadline: .now() + plan.seconds + (plan.guided ? 10 : 0)) { [weak self] in
                    self?.endSelfTest(failure: plan.guided ? "guided check did not finish" : nil)
                }
            }
            if guidedPending { beginGuided() }
        case let .metrics(value):
            let isNewSample = value.sampleTime != metrics.sampleTime
            metrics = value
            if isNewSample, let signals = value.signals, let input = value.input {
                consume(SignalSnapshot(time: value.sampleTime, vision: signals, input: input))
            }
        case let .stopped(reason), let .failed(reason):
            token.cancel()
            cancelGuided()
            isRequested = false
            isCapturing = false
            isStopping = false
            soundMonitor.stop()
            finishRun(reason: reason, stopMilliseconds: nil)
            clearLiveReadings()
            status = reason
            if selfTestRunning { endSelfTest(failure: reason) }
        }
    }

    private func consume(_ snapshot: SignalSnapshot) {
        let result = estimator.update(snapshot)
        estimate = result
        summary.add(snapshot, result)
        var phase: String?
        if let begin = guidedStart, let index = GuidedCheck.phaseIndex(at: snapshot.time - begin) {
            phase = GuidedCheck.phases[index].name
            guidedSummary.add(phase: GuidedCheck.phases[index].name,
                              scored: GuidedCheck.isScored(at: snapshot.time - begin),
                              snapshot: snapshot, estimate: result)
        }
        // One line per second, plus one whenever the estimate changes. Every sample during a guided check.
        guard shareReadings,
              phase != nil || result.key != lastLoggedState || snapshot.time - lastReadingLogTime >= 1 else { return }
        lastReadingLogTime = snapshot.time
        lastLoggedState = result.key
        SharedLog.write(ReadingText.line(elapsed: max(0, snapshot.time - runStartTime), snapshot: snapshot, estimate: result,
                                         sound: currentSound(at: snapshot.time), soundStatus: soundStatus,
                                         latencyMS: metrics.lastLatencyMS, phase: phase))
    }

    // MARK: Guided check

    /// Starts the camera if needed, then speaks the steps of `GuidedCheck` and labels the readings.
    func startGuidedCheck() {
        guard !isGuiding, !isStopping else { return }
        if isCapturing {
            beginGuided()
        } else if !isRequested {
            guidedPending = true
            start()
            if !isRequested { guidedPending = false } // Start refused.
        }
    }

    private func beginGuided() {
        guidedPending = false
        guidedStart = ProcessInfo.processInfo.systemUptime
        guidedPhaseIndex = nil
        guidedSummary = GuidedSummary()
        let run = UUID()
        guidedRun = run
        estimator.recalibrate() // The first screen phase sets straight-ahead.
        if shareReadings { SharedLog.write("GUIDED begin seconds=\(ReadingText.number(GuidedCheck.totalSeconds, 0))") }
        tickGuided(run)
    }

    private func tickGuided(_ run: UUID) {
        guard run == guidedRun, let begin = guidedStart else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - begin
        guard let index = GuidedCheck.phaseIndex(at: elapsed) else {
            finishGuided()
            return
        }
        let phase = GuidedCheck.phases[index]
        if index != guidedPhaseIndex {
            guidedPhaseIndex = index
            guidedInstruction = phase.instruction
            speak(phase.cue)
            if shareReadings {
                let b = estimator.baseline
                SharedLog.write("GUIDED phase=\(phase.name) begins straight_ahead_pitch=\(ReadingText.signed(b?.pitch, 1))"
                    + " straight_ahead_yaw=\(ReadingText.signed(b?.yaw, 1))")
            }
        }
        let phaseEnd = GuidedCheck.phases[...index].reduce(0) { $0 + $1.seconds }
        guidedSecondsLeft = max(0, Int((phaseEnd - elapsed).rounded(.up)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.tickGuided(run) }
    }

    private func finishGuided() {
        var lines = guidedSummary.lines()
        let b = estimator.baseline
        lines.insert("GUIDED end straight_ahead_pitch=\(ReadingText.signed(b?.pitch, 1)) straight_ahead_yaw=\(ReadingText.signed(b?.yaw, 1))", at: 0)
        clearGuided()
        if shareReadings { lines.forEach(SharedLog.write) }
        speak(GuidedCheck.finishedCue)
        if selfTestRunning { endSelfTest(failure: nil) } else { stop(reason: "Guided check finished — camera off") }
    }

    /// Ends a check that has not finished, for example because the camera stopped.
    private func cancelGuided() {
        guard isGuiding else { return }
        let wasRunning = guidedStart != nil
        clearGuided()
        speech.stopSpeaking(at: .immediate)
        if wasRunning, shareReadings { SharedLog.write("GUIDED cancelled") }
    }

    private func clearGuided() {
        guidedPending = false
        guidedStart = nil
        guidedPhaseIndex = nil
        guidedRun = UUID()
        guidedInstruction = nil
        guidedSecondsLeft = 0
    }

    private func speak(_ text: String) {
        speech.stopSpeaking(at: .immediate)
        speech.speak(AVSpeechUtterance(string: text))
    }

    /// The latest sound window, unless it is too old to describe the present.
    private func currentSound(at time: Double) -> SoundReading? {
        guard let sound, time - sound.time <= 6 else { return nil }
        return sound
    }

    private func receive(sound reading: SoundReading) {
        guard isCapturing else { return } // A window that finished after Stop.
        sound = reading
        summary.add(sound: reading)
    }

    private func receive(soundStatus newStatus: SoundStatus) {
        guard isCapturing else { return }
        soundStatus = newStatus
        if shareReadings { SharedLog.write("EVENT sound \(newStatus.key)") }
    }

    // MARK: Self-test

    /// Runs once, after the first camera discovery, when the app was launched with `--selftest`.
    private func beginSelfTestIfRequested() {
        guard let plan = selfTest, !selfTestStarted else { return }
        selfTestStarted = true
        SharedLog.write("SELFTEST begin seconds=\(ReadingText.number(plan.seconds)) sound=\(plan.sound) capture_only=\(plan.captureOnly) guided=\(plan.guided) preview=\(plan.preview)")
        keepRunningInBackground = true // Nobody is asked to keep this window in front.
        listenForSounds = plan.sound
        showPreview = plan.preview
        shareReadings = true
        guard !selectedCameraID.isEmpty else {
            endSelfTest(failure: "no built-in camera found")
            return
        }
        selfTestLimit(Self.selfTestPromptSeconds) { "no answer to the macOS permission prompt within \(Int(Self.selfTestPromptSeconds)) s" }
        guidedPending = plan.guided
        start()
        if !isRequested, !selfTestEnded { endSelfTest(failure: status) } // Start refused, for example thermal pressure.
    }

    /// How long a self-test waits for someone to answer a permission prompt.
    private static let selfTestPromptSeconds = 90.0

    /// Ends the self-test as failed if it is still in the same phase after `seconds`.
    private func selfTestLimit(_ seconds: Double, _ reason: @escaping () -> String) {
        let phase = selfTestPhase
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.selfTestRunning, self.selfTestPhase == phase else { return }
            self.endSelfTest(failure: reason())
        }
    }

    private func endSelfTest(failure: String?) {
        guard selfTestRunning else { return }
        selfTestEnded = true
        let reason = failure.map { "Self-test stopped: \($0)" } ?? "Self-test finished — camera off"
        performStop(reason: reason) {
            SharedLog.write(failure.map { "SELFTEST result=failed reason=\"\($0)\"" } ?? "SELFTEST result=ok")
            NSApp.terminate(nil)
        }
    }
}
