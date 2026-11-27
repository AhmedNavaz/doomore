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
    /// Work-context gating for the behavioral engine. Remembered between launches.
    @Published var workContextMode: WorkContextMode = DiagnosticsModel.savedWorkContextMode() {
        didSet {
            UserDefaults.standard.set(workContextMode.rawValue, forKey: Self.workContextModeKey)
            refreshBehaviorContext()
        }
    }
    /// How readily reminders fire. Remembered between launches.
    @Published var sensitivity: Sensitivity = DiagnosticsModel.savedSensitivity() {
        didSet {
            UserDefaults.standard.set(sensitivity.rawValue, forKey: Self.sensitivityKey)
            // A guided check always runs on the tested default rules.
            if !isGuiding { behaviorEngine.rules = sensitivity.rules }
        }
    }
    /// Bundle identifiers that count as work in "Selected work apps" mode. Remembered.
    @Published private(set) var workBundleIDs: [String] = DiagnosticsModel.savedWorkApps()
    /// Shown once, on first launch.
    @Published var showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingSeen")
    @Published private(set) var launchAtLogin = LaunchAtLogin.isEnabled
    @Published private(set) var launchAtLoginError: String?
    /// Milestone 2: the person chose Start monitoring in the menu bar. Monitoring then runs with
    /// this window closed or behind other apps, never uses the microphone, and shows no preview
    /// unless the window is open. Off at every launch (spec §6.2).
    @Published private(set) var wantsMonitoring = false
    /// Paused from the menu bar: the camera is off until Resume.
    @Published private(set) var monitoringPaused = false
    /// Why monitoring stopped on its own (permission, camera failure, thermal pressure).
    @Published private(set) var monitoringProblem: String?
    @Published private(set) var breakSecondsLeft = 0.0
    @Published private(set) var notificationPermission: NotificationPermission = .unknown
    /// Manual pause for the behavioral engine without releasing settings.
    @Published var isUserPaused = false { didSet { refreshBehaviorContext() } }
    @Published private(set) var metrics = CaptureMetrics()
    @Published private(set) var estimate: ActivityEstimate?
    @Published private(set) var behavior: BehaviorSnapshot = .initial()
    /// Dry-run in-window reminder emitted by `BehaviorEngine` (Milestone 1).
    /// Real macOS notifications are deferred to Milestone 2.
    @Published private(set) var activeReminder: InterventionEvent? {
        didSet {
            // Live monitoring only: a guided check must not be changed by an overlay.
            if let reminder = activeReminder, alertStyle == .screenAndSound, !isGuiding {
                if oldValue?.episodeID != reminder.episodeID {
                    alerts.show(reminder, challenge: alertChallenge, showQuote: showQuote, hideOtherApps: hideOtherApps)
                }
            } else if activeReminder == nil, alerts.isShowing {
                alerts.dismiss()
            }
        }
    }
    /// How loudly reminders are delivered. Remembered.
    @Published var alertStyle: AlertStyle = AlertStyle(rawValue: UserDefaults.standard.string(forKey: "alertStyle") ?? "") ?? .screenAndSound {
        didSet {
            UserDefaults.standard.set(alertStyle.rawValue, forKey: "alertStyle")
            if alertStyle == .notificationOnly { alerts.dismiss() }
        }
    }
    /// What must be done before the warning lets go. Remembered.
    @Published var alertChallenge: AlertChallenge = AlertChallenge(rawValue: UserDefaults.standard.string(forKey: "alertChallenge") ?? "") ?? .wait {
        didSet { UserDefaults.standard.set(alertChallenge.rawValue, forKey: "alertChallenge") }
    }
    /// Show a motivational line on the warning. Remembered.
    @Published var showQuote: Bool = UserDefaults.standard.object(forKey: "showQuote") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showQuote, forKey: "showQuote") }
    }
    /// Hide (not quit) every other app when the warning appears. Remembered.
    @Published var hideOtherApps: Bool = UserDefaults.standard.bool(forKey: "hideOtherApps") {
        didSet { UserDefaults.standard.set(hideOtherApps, forKey: "hideOtherApps") }
    }
    private let alerts = AlertPresenter(breakSeconds: BehaviorEngine.Rules().defaultBreakSeconds)
    /// Display-only name of the frontmost app in the local window. Never logged.
    @Published private(set) var frontmostAppName = ""
    @Published private(set) var frontmostIsWorkApp = false
    @Published private(set) var frontmostIsMeetingApp = false
    @Published private(set) var sound: SoundReading?
    @Published private(set) var soundStatus = SoundStatus.off
    /// What the guided check asks for right now; nil when no check is running.
    @Published private(set) var guidedInstruction: String?
    @Published private(set) var guidedSecondsLeft = 0
    @Published private(set) var activeGuidedSuite: GuidedCheck.Suite = .phoneSignals
    @Published private(set) var lastGuidedReport: GuidedReport?

    /// Nil for a normal launch. Set by `--selftest`, see `SelfTestPlan`.
    let selfTest = SelfTestPlan.parse(ProcessInfo.processInfo.arguments)
    private var selfTestStarted = false
    private var selfTestEnded = false
    private var selfTestRunning: Bool { selfTest != nil && selfTestStarted && !selfTestEnded }
    /// 0 waiting for permission, 1 starting the camera, 2 running. Each phase has its own time limit.
    private var selfTestPhase = 0

    private let clock: any MonotonicClock = SystemMonotonicClock()
    private var token = RunToken()
    private var estimator = ActivityEstimator()
    private var behaviorEngine = BehaviorEngine()
    private var foregroundMonitor: ForegroundAppMonitor?
    private let mediaMonitor = MacMediaMonitor()
    private var frontmostBundleID: String?
    @Published private(set) var sessionActive = true
    private var behaviorTimer: Timer?
    private var lastLoggedBehaviorState: BehaviorState?
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
    private var guidedSuite: GuidedCheck.Suite = .phoneSignals
    private var guidedSummary = GuidedSummary()
    private var behaviorGuidedSummary = BehaviorGuidedSummary()
    private var guidedSavedContext: (mode: WorkContextMode, userPaused: Bool)?
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

    private func updatePreview() { camera.setPreview(enabled: showPreview && windowVisible, mirrored: mirrored) }

    private let notifier: ReminderNotifier
    /// The diagnostics window is on screen; the camera preview is drawn only then.
    private var windowVisible = false
    /// Monotonic end of a break taken while monitoring; the camera restarts when it passes.
    private var breakEndsAt: Double?
    /// The camera may keep running when this window is not in front.
    private var runsInBackground: Bool { keepRunningInBackground || wantsMonitoring || isGuiding }
    /// Monitoring never opens the microphone (spec §1.3, §13.1); only the diagnostics window can.
    private var soundsWanted: Bool { listenForSounds && !wantsMonitoring }

    private static let sensitivityKey = "sensitivity"
    private static let workAppsKey = "workBundleIDs"
    private static func savedSensitivity() -> Sensitivity {
        UserDefaults.standard.string(forKey: sensitivityKey).flatMap(Sensitivity.init(rawValue:)) ?? .balanced
    }
    private static func savedWorkApps() -> [String] {
        guard let saved = UserDefaults.standard.stringArray(forKey: workAppsKey) else {
            return WorkAppList.normalized(WorkContextConfig.defaultWorkBundleIDs)
        }
        return WorkAppList.normalized(saved)
    }

    func addWorkApp(_ bundleID: String) { setWorkApps(WorkAppList.adding(bundleID, to: workBundleIDs)) }
    func removeWorkApp(_ bundleID: String) { setWorkApps(WorkAppList.removing(bundleID, from: workBundleIDs)) }
    func resetWorkApps() { setWorkApps(WorkAppList.normalized(WorkContextConfig.defaultWorkBundleIDs)) }

    private func setWorkApps(_ ids: [String]) {
        workBundleIDs = ids
        UserDefaults.standard.set(ids, forKey: Self.workAppsKey)
        refreshBehaviorContext()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = LaunchAtLogin.set(enabled)
        launchAtLogin = LaunchAtLogin.isEnabled || LaunchAtLogin.needsApproval
    }

    /// Shows the full-screen warning now, for a look at it. Its buttons only close it.
    func previewAlert() {
        alerts.show(InterventionEvent(episodeID: UUID(), kind: .sustainedEpisode, timestamp: clock.now(),
                                      evidenceDuration: 0, recentPickupCount: 0, reasons: []),
                    challenge: alertChallenge, showQuote: showQuote, hideOtherApps: false,
                    onAction: { [weak self] _ in self?.alerts.dismiss() })
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingSeen")
        showOnboarding = false
    }

    private static let workContextModeKey = "workContextMode"
    private static func savedWorkContextMode() -> WorkContextMode {
        UserDefaults.standard.string(forKey: workContextModeKey).flatMap(WorkContextMode.init(rawValue:)) ?? .manualWork
    }

    var monitoringStatus: MonitoringStatus {
        MonitoringStatus.make(.init(
            wantsMonitoring: wantsMonitoring,
            userPaused: monitoringPaused,
            breakSecondsLeft: breakSecondsLeft,
            cameraRequested: isRequested,
            cameraCapturing: isCapturing,
            sessionActive: sessionActive,
            behavior: behavior.state,
            reasons: behavior.reasons,
            problem: monitoringProblem,
            remindersOff: workContextMode == .inactive))
    }

    init() {
        notifier = ReminderNotifier(breakSeconds: BehaviorEngine.Rules().defaultBreakSeconds)
        let now = clock.now()
        behaviorEngine = BehaviorEngine(rules: DiagnosticsModel.savedSensitivity().rules, startTime: now)
        behavior = behaviorEngine.snapshot

        let monitor = ForegroundAppMonitor { [weak self] identity in
            self?.receiveFrontmostApp(identity)
        }
        foregroundMonitor = monitor
        applyFrontmostIdentity(monitor.current)
        notifier.onAction = { [weak self] action in self?.handleNotificationAction(action) }
        alerts.onAction = { [weak self] action in self?.handleNotificationAction(action) }
        notifier.onPermissionChange = { [weak self] value in self?.notificationPermission = value }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willPowerOffNotification] {
            observe(workspace, name) { [weak self] in
                guard let self else { return }
                self.sessionActive = false
                self.activeReminder = nil
                self.tickBehaviorEngine()
                self.stop(reason: "Session inactive — Start again when ready")
            }
        }
        // Screen wake is included: a display that slept without a lock or system sleep posts
        // neither of the other two, which left the session inactive until the next Start.
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification] {
            observe(workspace, name) { [weak self] in
                guard let self else { return }
                self.sessionActive = true
                self.tickBehaviorEngine()
                // Give the camera a moment after wake before reopening it (spec §6.1).
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.resumeMonitoringIfWanted()
                }
            }
        }
        // Default policy: the camera runs only while this window is in front. Ticking
        // "Keep running when I switch apps" lifts that for app switches, hiding and
        // minimizing, and so does a guided check, which lasts under a few minutes and turns the
        // camera off when it ends. Sleep, lock, screen sleep and closing the window always stop it.
        for name in [NSApplication.didResignActiveNotification, NSApplication.didHideNotification,
                     NSWindow.didMiniaturizeNotification] {
            observe(.default, name) { [weak self] in
                guard let self, self.isRequested, !self.runsInBackground else { return }
                self.stop(reason: "Window not in front — camera off")
            }
        }
        observe(.default, NSWindow.willCloseNotification) { [weak self] in
            // An unattended self-test must not be ended by an unrelated window closing.
            guard let self, self.isRequested, !self.selfTestRunning, !self.wantsMonitoring else { return }
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

    deinit {
        behaviorTimer?.invalidate()
        observers.forEach { $0.0.removeObserver($0.1) }
    }

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

    // MARK: Behavior & work context

    private func currentWorkContext() -> WorkContextSnapshot {
        WorkContextSnapshot(
            monitoringEnabled: isCapturing,
            cameraAvailable: isCapturing,
            cameraUnavailableReason: isCapturing ? nil : status,
            sessionActive: sessionActive,
            userPaused: isUserPaused,
            breakUntil: nil,
            frontmostBundleID: frontmostBundleID,
            config: WorkContextConfig(mode: workContextMode, workBundleIDs: Set(workBundleIDs))
        )
    }

    private func receiveFrontmostApp(_ identity: ForegroundAppMonitor.AppIdentity) {
        applyFrontmostIdentity(identity)
        refreshBehaviorContext()
    }

    private func applyFrontmostIdentity(_ identity: ForegroundAppMonitor.AppIdentity) {
        frontmostBundleID = identity.bundleID
        frontmostAppName = identity.localizedName ?? identity.bundleID ?? "Unknown"
        let context = currentWorkContext()
        frontmostIsWorkApp = context.isWorkAppActive
        frontmostIsMeetingApp = context.isMeetingActive
    }

    private func refreshBehaviorContext() {
        let context = currentWorkContext()
        frontmostIsWorkApp = context.isWorkAppActive
        frontmostIsMeetingApp = context.isMeetingActive
        tickBehaviorEngine()
    }

    private func tickBehaviorEngine() {
        let now = clock.now()
        if let ends = breakEndsAt {
            breakSecondsLeft = max(0, ends - now)
            if breakSecondsLeft <= 0 {
                breakEndsAt = nil
                resumeMonitoringIfWanted()
            }
        } else if breakSecondsLeft != 0 {
            breakSecondsLeft = 0
        }
        let updated = behaviorEngine.tick(at: now, context: currentWorkContext())
        publishBehavior(updated)
    }

    private func publishBehavior(_ updated: BehaviorSnapshot) {
        behavior = updated
        if let reminder = updated.pendingIntervention {
            activeReminder = reminder
            if notificationPermission == .allowed { notifier.deliver(reminder) }
            if shareReadings {
                SharedLog.write("EVENT behavior_reminder kind=\(reminder.kind.rawValue) duration=\(ReadingText.unit(reminder.evidenceDuration, 1, "s")) pickups=\(reminder.recentPickupCount)")
            }
        } else if updated.state == .disabled || updated.state == .unavailable || updated.state == .paused {
            activeReminder = nil
        }
        if shareReadings, updated.state != lastLoggedBehaviorState {
            lastLoggedBehaviorState = updated.state
            let reasons = updated.reasons.map(\.rawValue).joined(separator: ",")
            SharedLog.write("EVENT behavior state=\(updated.state.rawValue) reasons=\(reasons.isEmpty ? "none" : reasons)")
        }
        updateBehaviorTimer()
    }

    private func updateBehaviorTimer() {
        let needsTimer = isCapturing || breakEndsAt != nil || behavior.breakRemaining > 0 || behavior.cooldownRemaining > 0
        if needsTimer, behaviorTimer == nil {
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tickBehaviorEngine()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            behaviorTimer = timer
        } else if !needsTimer, let timer = behaviorTimer {
            timer.invalidate()
            behaviorTimer = nil
        }
    }

    func acknowledgeBackToWork() {
        confirmedCount += 1
        UserDefaults.standard.set(confirmedCount, forKey: "confirmedCount")
        falseAlarmStreak = 0
        activeReminder = nil
        notifier.clearDelivered()
        let updated = behaviorEngine.apply(.backToWork, at: clock.now(), context: currentWorkContext())
        publishBehavior(updated)
    }

    /// False alarms and confirmed reminders, remembered. Three "not a distraction" answers in a
    /// row make reminders one step less sensitive, and the Settings screen says so.
    @Published private(set) var falseAlarmCount = UserDefaults.standard.integer(forKey: "falseAlarmCount")
    @Published private(set) var confirmedCount = UserDefaults.standard.integer(forKey: "confirmedCount")
    @Published var sensitivityNotice: String?
    private var falseAlarmStreak = 0

    func apply(_ style: CoachStyle) {
        sensitivityNotice = nil
        switch style {
        case .gentle: sensitivity = .relaxed; alertStyle = .notificationOnly; alertChallenge = .none; showQuote = true; hideOtherApps = false
        case .standard: sensitivity = .balanced; alertStyle = .screenAndSound; alertChallenge = .wait; showQuote = true; hideOtherApps = false
        case .strict: sensitivity = .sensitive; alertStyle = .screenAndSound; alertChallenge = .math; showQuote = true; hideOtherApps = true
        }
    }

    func matches(_ style: CoachStyle) -> Bool {
        switch style {
        case .gentle: return sensitivity == .relaxed && alertStyle == .notificationOnly
        case .standard: return sensitivity == .balanced && alertStyle == .screenAndSound && alertChallenge == .wait && !hideOtherApps
        case .strict: return sensitivity == .sensitive && alertStyle == .screenAndSound && alertChallenge == .math && hideOtherApps
        }
    }

    func markNotADistraction() {
        falseAlarmCount += 1
        UserDefaults.standard.set(falseAlarmCount, forKey: "falseAlarmCount")
        falseAlarmStreak += 1
        if falseAlarmStreak >= 3 {
            falseAlarmStreak = 0
            switch sensitivity {
            case .sensitive:
                sensitivity = .balanced
                sensitivityNotice = "Three false alarms in a row, so reminders were set to Balanced."
            case .balanced:
                sensitivity = .relaxed
                sensitivityNotice = "Three false alarms in a row, so reminders were set to Relaxed."
            case .relaxed:
                break
            }
        }
        activeReminder = nil
        notifier.clearDelivered()
        let updated = behaviorEngine.apply(.notADistraction, at: clock.now(), context: currentWorkContext())
        publishBehavior(updated)
    }

    /// Starts an intentional break (default 5 min) and releases the camera (spec §5.3).
    func takeBreak() {
        activeReminder = nil
        notifier.clearDelivered()
        let duration = behaviorEngine.rules.defaultBreakSeconds
        let now = clock.now()
        if wantsMonitoring {
            // Monitoring restarts the camera by itself when the break ends (spec §5.3).
            breakEndsAt = now + duration
            breakSecondsLeft = duration
        }
        let updated = behaviorEngine.apply(.takingABreak(duration: duration), at: now, context: currentWorkContext())
        publishBehavior(updated)
        if isRequested {
            stop(reason: "Taking a \(Int(duration / 60)) min break — camera off")
        }
    }

    func endBreakEarly() {
        let wasMonitoringBreak = breakEndsAt != nil
        breakEndsAt = nil
        breakSecondsLeft = 0
        let updated = behaviorEngine.endBreak(at: clock.now(), context: currentWorkContext())
        publishBehavior(updated)
        if wasMonitoringBreak { resumeMonitoringIfWanted() }
    }

    private func handleNotificationAction(_ action: InterventionAction) {
        switch action {
        case .backToWork: acknowledgeBackToWork()
        case .notADistraction: markNotADistraction()
        case .takingABreak: takeBreak()
        }
    }

    // MARK: Monitoring (menu bar)

    /// Explicit opt-in from the menu bar. Asks for notification permission the first time only.
    func startMonitoring() {
        guard !wantsMonitoring, !isGuiding else { return }
        monitoringProblem = nil
        monitoringPaused = false
        breakEndsAt = nil
        breakSecondsLeft = 0
        wantsMonitoring = true
        notifier.requestPermissionIfNeeded()
        if isRequested {
            // Already running from this window: keep the camera, drop the microphone.
            if soundStatus == .listening || soundStatus == .starting {
                soundMonitor.stop()
                soundStatus = .off
            }
            return
        }
        guard !isStopping else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.resumeMonitoringIfWanted() }
            return
        }
        start()
        if !isRequested { endMonitoring(problem: status) }
    }

    func stopMonitoring() {
        guard wantsMonitoring || monitoringProblem != nil else { return }
        wantsMonitoring = false
        monitoringPaused = false
        monitoringProblem = nil
        breakEndsAt = nil
        breakSecondsLeft = 0
        activeReminder = nil
        notifier.clearDelivered()
        if isRequested { stop(reason: "Monitoring stopped — camera off") }
        tickBehaviorEngine()
    }

    func pauseMonitoring() {
        guard wantsMonitoring, !monitoringPaused else { return }
        monitoringPaused = true
        activeReminder = nil
        notifier.clearDelivered()
        if isRequested { stop(reason: "Paused — camera off") }
    }

    func resumeMonitoring() {
        guard wantsMonitoring else { return }
        monitoringPaused = false
        if breakEndsAt != nil {
            endBreakEarly()
        } else {
            resumeMonitoringIfWanted()
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshNotificationPermission() { notifier.refreshPermission() }

    func diagnosticsWindowAppeared() {
        windowVisible = true
        updatePreview()
    }

    func diagnosticsWindowClosed() {
        windowVisible = false
        updatePreview()
        if !wantsMonitoring { stop(reason: "Window closed — camera off") }
    }

    /// Restarts the camera after a break, a pause or wake, only if the person still wants
    /// monitoring and camera permission is already granted (never prompts on its own).
    private func resumeMonitoringIfWanted() {
        guard wantsMonitoring, !monitoringPaused, breakEndsAt == nil, sessionActive, !isRequested, !isGuiding else { return }
        guard !isStopping else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.resumeMonitoringIfWanted() }
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            endMonitoring(problem: "Camera permission needed — choose Start monitoring again")
            return
        }
        start()
        if !isRequested { endMonitoring(problem: status) }
    }

    private func endMonitoring(problem: String) {
        wantsMonitoring = false
        monitoringPaused = false
        breakEndsAt = nil
        breakSecondsLeft = 0
        monitoringProblem = problem
        activeReminder = nil
        notifier.clearDelivered()
    }

    /// The camera went off. Monitoring keeps going only through stops it chose: pause, break,
    /// lock or sleep. Anything else (permission refused, camera failure, thermal pressure)
    /// ends monitoring and says why, rather than retrying in a loop (spec §6.1).
    private func noteCameraOff(reason: String) {
        guard wantsMonitoring, !monitoringPaused, breakEndsAt == nil, sessionActive, !isRequested else { return }
        endMonitoring(problem: reason)
    }

    func dismissGuidedReport() {
        lastGuidedReport = nil
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
        sessionActive = true
        if wantsMonitoring {
            // Starting the camera by hand while monitoring is paused or on break resumes it.
            monitoringPaused = false
            breakEndsAt = nil
            breakSecondsLeft = 0
        }
        isUserPaused = false
        activeReminder = nil
        metrics = CaptureMetrics()
        estimate = nil
        sound = nil
        soundStatus = .off
        estimator.reset()
        _ = behaviorEngine.endBreak(at: clock.now(), context: currentWorkContext())
        summary = RunSummary()
        lastReadingLogTime = 0
        lastLoggedState = ""
        lastLoggedBehaviorState = nil
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
        guard soundsWanted else { beginCapture(id: id); return }
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
        guard token.accepts(id), NSApp.isActive || runsInBackground else {
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
                self.noteCameraOff(reason: reason)
                self.tickBehaviorEngine()
            }
            completion?()
        }
    }

    func shutdown(completion: @escaping () -> Void) {
        token.cancel()
        cancelGuided()
        behaviorTimer?.invalidate()
        behaviorTimer = nil
        isRequested = false
        isCapturing = false
        activeReminder = nil
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
        activeReminder = nil
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
            guard NSApp.isActive || runsInBackground else { stop(reason: "Window not in front — camera off"); return }
            isCapturing = true
            runActive = true
            runStartTime = ProcessInfo.processInfo.systemUptime
            foregroundMonitor?.refresh()
            tickBehaviorEngine()
            status = (selfTest != nil ? "Self-test · " : "") + (previewAttached
                ? "Camera active · \(name)"
                : "Camera active · \(name) · preview unavailable (frames still processed)")
            if shareReadings { SharedLog.write("EVENT started camera=\"\(name)\" preview=\(previewAttached) sounds=\(soundsWanted) monitoring=\(wantsMonitoring)") }
            if soundsWanted, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
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
            noteCameraOff(reason: reason)
            tickBehaviorEngine()
            if selfTestRunning { endSelfTest(failure: reason) }
        }
    }

    private func consume(_ snapshot: SignalSnapshot) {
        let result = estimator.update(snapshot)
        estimate = result
        summary.add(snapshot, result)

        let media = mediaMonitor.current()
        let evidence = BehaviorEvidence(snapshot: snapshot, estimate: result, media: media)
        let behaviorUpdate = behaviorEngine.step(context: currentWorkContext(), evidence: evidence)
        publishBehavior(behaviorUpdate)

        var phase: String?
        if let begin = guidedStart {
            let suitePhases = GuidedCheck.phases(for: guidedSuite)
            let elapsed = snapshot.time - begin
            if let index = GuidedCheck.phaseIndex(at: elapsed, suite: guidedSuite) {
                let phaseObj = suitePhases[index]
                let phaseStart = suitePhases[..<index].reduce(0) { $0 + $1.seconds }
                let phaseElapsed = max(0, elapsed - phaseStart)
                phase = phaseObj.name
                guidedSummary.add(phase: phaseObj.name,
                                  scored: GuidedCheck.isScored(at: elapsed, suite: guidedSuite),
                                  snapshot: snapshot, estimate: result)
                if guidedSuite == .behaviorEngine {
                    behaviorGuidedSummary.add(phase: phaseObj.name,
                                              phaseElapsed: phaseElapsed,
                                              snapshot: snapshot,
                                              estimate: result,
                                              behavior: behaviorUpdate)
                }
            }
        }
        // One line per second, plus one whenever the estimate changes. Every sample during a guided check.
        guard shareReadings,
              phase != nil || result.key != lastLoggedState || snapshot.time - lastReadingLogTime >= 1 else { return }
        lastReadingLogTime = snapshot.time
        lastLoggedState = result.key
        SharedLog.write(ReadingText.line(elapsed: max(0, snapshot.time - runStartTime), snapshot: snapshot, estimate: result,
                                         sound: currentSound(at: snapshot.time), soundStatus: soundStatus,
                                         latencyMS: metrics.lastLatencyMS, phase: phase,
                                         media: media, behavior: behaviorUpdate))
    }

    // MARK: Guided check

    /// Starts the camera if needed, then speaks the steps of the chosen `GuidedCheck.Suite` and labels the readings.
    func startGuidedCheck(_ suite: GuidedCheck.Suite = .phoneSignals) {
        guard !isGuiding, !isStopping else { return }
        guidedSuite = suite
        activeGuidedSuite = suite
        lastGuidedReport = nil
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
        guidedSummary = GuidedSummary(suite: guidedSuite)
        behaviorGuidedSummary = BehaviorGuidedSummary()
        if guidedSuite == .behaviorEngine {
            if guidedSavedContext == nil {
                guidedSavedContext = (workContextMode, isUserPaused)
            }
            workContextMode = .manualWork
            isUserPaused = false
            behaviorEngine = BehaviorEngine(startTime: clock.now())
            lastLoggedBehaviorState = nil
            activeReminder = nil
            publishBehavior(behaviorEngine.snapshot)
        }
        let run = UUID()
        guidedRun = run
        estimator.recalibrate() // The first screen phase sets straight-ahead.
        if shareReadings {
            let total = ReadingText.number(GuidedCheck.totalSeconds(for: guidedSuite), 0)
            if guidedSuite == .phoneSignals {
                SharedLog.write("GUIDED begin seconds=\(total)")
            } else {
                SharedLog.write("GUIDED begin suite=\(guidedSuite.rawValue) seconds=\(total)")
            }
        }
        tickGuided(run)
    }

    private func tickGuided(_ run: UUID) {
        guard run == guidedRun, let begin = guidedStart else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - begin
        let suitePhases = GuidedCheck.phases(for: guidedSuite)
        guard let index = GuidedCheck.phaseIndex(at: elapsed, suite: guidedSuite) else {
            finishGuided()
            return
        }
        let phase = suitePhases[index]
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
        let phaseEnd = suitePhases[...index].reduce(0) { $0 + $1.seconds }
        guidedSecondsLeft = max(0, Int((phaseEnd - elapsed).rounded(.up)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.tickGuided(run) }
    }

    private func finishGuided() {
        let suite = guidedSuite
        var lines = guidedSummary.lines()
        if suite == .behaviorEngine {
            lines.append(contentsOf: behaviorGuidedSummary.lines())
            lastGuidedReport = behaviorGuidedSummary.report()
        } else {
            lastGuidedReport = guidedSummary.report()
        }
        let b = estimator.baseline
        lines.insert("GUIDED end straight_ahead_pitch=\(ReadingText.signed(b?.pitch, 1)) straight_ahead_yaw=\(ReadingText.signed(b?.yaw, 1))", at: 0)
        clearGuided()
        restoreGuidedContextIfNeeded()
        if shareReadings { lines.forEach(SharedLog.write) }
        speak(GuidedCheck.finishedCue)
        if selfTestRunning {
            endSelfTest(failure: nil)
        } else if wantsMonitoring, !monitoringPaused, breakEndsAt == nil {
            status = "\(suite.title) finished — monitoring continues"
        } else {
            stop(reason: "\(suite.title) finished — camera off")
        }
    }

    /// Ends a check that has not finished, for example because the camera stopped.
    private func cancelGuided() {
        guard isGuiding else { return }
        let wasRunning = guidedStart != nil
        clearGuided()
        restoreGuidedContextIfNeeded()
        speech.stopSpeaking(at: .immediate)
        if wasRunning, shareReadings { SharedLog.write("GUIDED cancelled") }
    }

    private func restoreGuidedContextIfNeeded() {
        guard let saved = guidedSavedContext else { return }
        guidedSavedContext = nil
        workContextMode = saved.mode
        isUserPaused = saved.userPaused
        behaviorEngine.rules = sensitivity.rules
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
        guidedSuite = plan.guidedSuite
        activeGuidedSuite = plan.guidedSuite
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
