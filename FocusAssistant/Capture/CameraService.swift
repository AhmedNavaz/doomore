import AVFoundation
import Foundation
import CoreMedia
import os

private let logger = Logger(subsystem: "com.local.FocusAssistant", category: "capture")

/// All mutable capture/detector state belongs to `queue`. AVFoundation invokes
/// sample callbacks on that SAME serial queue. Buffers are borrowed synchronously
/// and never captured in a Task or sent to the UI. Late frames are discarded by AVF.
/// Swift 5 language mode is intentional for this classic delegate/queue boundary;
/// no unchecked Sendable conformance is used to bypass buffer ownership.
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session: AVCaptureSession
    let previewLayer: AVCaptureVideoPreviewLayer // UI owns geometry only, never session/connection.
    private let queue = DispatchQueue(label: "com.local.FocusAssistant.capture", qos: .userInitiated)
    // Only this tiny command token crosses queues, protected by a lock. No buffers do.
    private let commandLock = NSLock()
    private var requestedID: UUID?
    private let output = AVCaptureVideoDataOutput()
    private var runID: UUID?
    private var device: AVCaptureDevice?
    private var mode = CaptureMode.captureOnly
    private var probe: VisionSignalProbe?
    private var previewEnabled = true
    private var previewMirrored = true
    private var metrics = CaptureMetrics()
    private var startTime = 0.0
    private var lastFrameTime = 0.0
    /// Two analysed frames per second: enough to follow head movement, far below the camera's frame rate.
    private var inferenceSchedule = InferenceSchedule(minimumInterval: 0.5)
    private var lastPublishTime = 0.0
    private var latencies: [Double] = [] // Bounded diagnostic rolling window; no image data.
    private var watchdog: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private let onEvent: (UUID, CaptureEvent) -> Void

    init(onEvent: @escaping (UUID, CaptureEvent) -> Void) {
        let session = AVCaptureSession()
        self.session = session
        previewLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        previewLayer.videoGravity = .resizeAspect
        self.onEvent = onEvent
        super.init()
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                guard let self, let id = self.requestedRun() else { return }
                self.queue.async { [weak self] in
                    guard let self, self.runID == id else { return }
                    self.fail("Camera interrupted or runtime failure. Stop, resolve the conflict, then Start again.")
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let disconnectedID = (notification.object as? AVCaptureDevice)?.uniqueID else { return }
            self?.queue.async { [weak self] in
                guard let self, self.device?.uniqueID == disconnectedID else { return }
                self.fail("Selected camera disconnected. Reconnect it and refresh cameras.")
            }
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func discover(completion: @escaping ([CameraChoice]) -> Void) {
        queue.async {
            let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
            let choices = devices.filter { !$0.isContinuityCamera }.map {
                CameraChoice(id: $0.uniqueID, name: $0.localizedName, builtIn: $0.deviceType == .builtInWideAngleCamera)
            }.sorted { $0.builtIn && !$1.builtIn }
            DispatchQueue.main.async { completion(choices) }
        }
    }

    func start(id: UUID, cameraID: String, mode: CaptureMode) {
        setRequestedRun(id)
        queue.async { [self] in
            guard requestedRun() == id else { return }
            stopOnQueue()
            runID = id
            self.mode = mode
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                fail("Camera permission is unavailable. Enable it in System Settings → Privacy & Security → Camera.")
                return
            }
            let discovered = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
            guard let camera = discovered.first(where: { $0.uniqueID == cameraID && !$0.isContinuityCamera }) else {
                fail("Selected camera unavailable. Continuity Camera is excluded from this experiment.")
                return
            }
            guard !camera.isInUseByAnotherApplication, !camera.isSuspended else {
                fail("Camera is busy or suspended. Close the conflicting camera app, then try again.")
                return
            }
            do {
                probe = mode == .signals ? try VisionSignalProbe() : nil
                try probe?.warmUp() // Model loading takes seconds; do it while the camera is still off.
                guard requestedRun() == id else { stopOnQueue(); return }
                let (input, format) = try configure(camera)
                logger.notice("Format after configure: \(Self.describe(camera.activeFormat), privacy: .public)")
                let previewAttached = attachPreview(input: input)
                logger.notice("Format after preview attach (\(previewAttached, privacy: .public)): \(Self.describe(camera.activeFormat), privacy: .public)")
                device = camera
                metrics = CaptureMetrics(inferenceConfigured: probe != nil)
                latencies.removeAll(keepingCapacity: true)
                startTime = ProcessInfo.processInfo.systemUptime
                lastFrameTime = startTime
                inferenceSchedule.reset()
                lastPublishTime = 0
                guard requestedRun() == id else { stopOnQueue(); return }
                session.startRunning() // Blocking call confined to serial worker queue.
                guard requestedRun() == id else { stopOnQueue(); return }
                guard session.isRunning else { fail("Camera did not start."); return }
                logger.notice("Format after startRunning: \(Self.describe(camera.activeFormat), privacy: .public)")
                if camera.activeFormat != format {
                    // In the app, startRunning reset the camera from 1280×720 to 1920×1080 even though
                    // configure and preview attach both left it at 1280×720 (log, 25 Nov 2026 20:51).
                    // A bare session without a preview did not reset it; the cause is unknown.
                    // Setting it again on the running session holds 1280×720.
                    try applyFormat(format, to: camera)
                }
                logger.notice("Capture running; device active format \(Self.describe(camera.activeFormat), privacy: .public), requested \(CaptureFormatChoice.width, privacy: .public)×\(CaptureFormatChoice.height, privacy: .public)")
                publish(.started(camera.localizedName, previewAttached: previewAttached))
                startWatchdog()
            } catch SetupFailure.resolution {
                fail("This camera has no native 1280 × 720 mode, which this experiment requires.")
            } catch let failure as SetupFailure {
                fail("Camera setup failed at step: \(failure). Stop, then Start again; report this step if it repeats.")
            } catch {
                fail("Camera or Vision setup failed (\(String(describing: type(of: error)))). Stop, then Start again; report this text if it repeats.")
            }
        }
    }

    private static func describe(_ format: AVCaptureDevice.Format) -> String {
        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return "\(d.width)×\(d.height)"
    }

    private func applyFormat(_ format: AVCaptureDevice.Format, to camera: AVCaptureDevice) throws {
        do {
            try camera.lockForConfiguration()
        } catch {
            throw SetupFailure.formatLock
        }
        camera.activeFormat = format // Frame duration is left at the format's default.
        camera.unlockForConfiguration()
    }

    /// Adds input and data output inside one committed configuration; the preview is attached afterwards.
    /// Returns the input and the 1280×720 format that was applied.
    private func configure(_ camera: AVCaptureDevice) throws -> (AVCaptureDeviceInput, AVCaptureDevice.Format) {
        dispatchPrecondition(condition: .onQueue(queue))
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw SetupFailure.input }
        session.addInput(input)
        // Frame size comes from the device's native mode: on this Mac the 640×480 preset alone
        // was accepted but the output still delivered 1920×1080 (25 Nov 2026).
        // The format and the output are applied together when the configuration commits.
        let formats = camera.formats
        let candidates = formats.map { format -> CaptureFormatChoice.Candidate in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return CaptureFormatChoice.Candidate(
                width: Int(dimensions.width),
                height: Int(dimensions.height),
                maxFrameRate: format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0,
                isVideoRange420: CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        }
        guard let index = CaptureFormatChoice.select(from: candidates) else { throw SetupFailure.resolution }
        // macOS has no .inputPriority preset; ask for the matching preset as well as the format.
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        try applyFormat(formats[index], to: camera)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw SetupFailure.output }
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false // Detector always sees unmirrored pixels.
        }
        return (input, formats[index])
    }

    /// The preview is optional diagnostics, so failing to attach it must not stop capture.
    /// Called after the configuration is committed: an explicit connection on the data output's
    /// video port, then on any other video port. On macOS 27 / FaceTime HD Camera an explicit
    /// connection added inside the input's configuration block was rejected as "media types are
    /// incompatible", and accepted once added after the commit (25 Nov 2026). If none is
    /// accepted, capture continues without a preview. Logs only port media/format types.
    private func attachPreview(input: AVCaptureDeviceInput) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        if previewLayer.connection != nil {
            configurePreviewConnection()
            return true
        }
        let outputPorts = output.connection(with: .video)?.inputPorts ?? []
        let candidates = outputPorts + input.ports.filter { port in
            port.mediaType == .video && !outputPorts.contains { $0 === port }
        }
        for port in candidates {
            let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: previewLayer)
            if session.canAddConnection(connection) {
                session.addConnection(connection)
                configurePreviewConnection()
                return true
            }
        }
        let described = input.ports.map { port -> String in
            let subtype = port.formatDescription.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
            return "\(port.mediaType.rawValue)/\(subtype)"
        }.joined(separator: ", ")
        logger.error("Preview unavailable: explicit connection rejected for \(candidates.count, privacy: .public) candidate ports; input ports: \(described, privacy: .public)")
        return false
    }

    func stop(completion: (() -> Void)? = nil) {
        setRequestedRun(nil) // Cancel queued start before blocking setup/inference finishes.
        queue.async { [self] in
            stopOnQueue()
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    func setPreview(enabled: Bool, mirrored: Bool) {
        queue.async { [self] in
            previewEnabled = enabled
            previewMirrored = mirrored
            configurePreviewConnection()
        }
    }

    private func configurePreviewConnection() {
        guard let connection = previewLayer.connection else { return }
        connection.isEnabled = previewEnabled
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = previewMirrored
        }
    }

    private func setRequestedRun(_ id: UUID?) {
        commandLock.lock()
        defer { commandLock.unlock() }
        requestedID = id
    }

    private func requestedRun() -> UUID? {
        commandLock.lock()
        defer { commandLock.unlock() }
        return requestedID
    }

    private func stopOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        watchdog?.cancel()
        watchdog = nil
        runID = nil
        if session.isRunning { session.stopRunning() }
        output.setSampleBufferDelegate(nil, queue: nil)
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        device = nil
        probe = nil
    }

    private func fail(_ reason: String) {
        guard let id = runID else { return }
        stopOnQueue()
        DispatchQueue.main.async { [onEvent] in onEvent(id, .failed(reason)) }
    }

    private func publish(_ event: CaptureEvent) {
        guard let id = runID else { return }
        DispatchQueue.main.async { [onEvent] in onEvent(id, event) }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.runID != nil else { return }
            if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
                self.fail("Camera permission was revoked.")
            } else if self.device?.isSuspended != false {
                self.fail("Camera suspended or unavailable.")
            } else if ProcessInfo.processInfo.systemUptime - self.lastFrameTime > 5 {
                self.fail("Camera frames are stale. Capture stopped; Start again when ready.")
            }
        }
        watchdog = timer
        timer.resume()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let runID, requestedRun() == runID,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        autoreleasepool {
            let now = ProcessInfo.processInfo.systemUptime
            lastFrameTime = now
            metrics.deliveredFrames += 1
            metrics.imageSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            var newSample = false
            if probe == nil {
                // Capture only: no analysis is configured, so nothing is skipped.
            } else if let probe, metrics.deliveredFrames > Self.settlingFrames, inferenceSchedule.shouldProcess(at: now) {
                do {
                    let begin = ProcessInfo.processInfo.systemUptime
                    metrics.signals = try probe.analyze(buffer)
                    let latency = (ProcessInfo.processInfo.systemUptime - begin) * 1_000
                    metrics.input = InputIdle.current() // Elapsed seconds only; no event content.
                    metrics.sampleTime = now
                    metrics.inferenceCount += 1
                    metrics.lastLatencyMS = latency
                    latencies.append(latency)
                    if latencies.count > 300 { latencies.removeFirst() }
                    metrics.meanLatencyMS = latencies.reduce(0, +) / Double(latencies.count)
                    let sorted = latencies.sorted()
                    metrics.p95LatencyMS = sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
                    newSample = true
                } catch {
                    // Unwind the borrowed sample callback before blocking teardown.
                    queue.async { [weak self] in
                        guard let self, self.runID == runID else { return }
                        self.fail("Vision analysis failed, so the readings are unknown. Stop, then Start again.")
                    }
                    return
                }
            } else {
                metrics.skippedFrames += 1 // Analysis configured; the schedule declined this frame.
            }
            let elapsed = max(now - startTime, 0.001)
            metrics.captureFPS = Double(metrics.deliveredFrames) / elapsed
            metrics.inferenceFPS = Double(metrics.inferenceCount) / elapsed
            // The watchdog measures time without frames, so a slow analysis must not count as a stalled camera.
            lastFrameTime = ProcessInfo.processInfo.systemUptime
            // Every analysed frame is published once; counters alone at most twice per second.
            if newSample || now - lastPublishTime >= 0.5 {
                lastPublishTime = now
                publish(.metrics(metrics))
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        if runID != nil { metrics.droppedFrames += 1 }
    }

    /// Frames ignored after the camera starts (about half a second). In the first live run
    /// the very first frame showed no face and unrelated labels, and early frames can still
    /// be 1920×1080 before the format is set again.
    private static let settlingFrames = 15

    private enum SetupFailure: Error { case input, output, resolution, formatLock }
}
