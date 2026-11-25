import AVFoundation
import Foundation
import SoundAnalysis

/// Names the kind of sound near the Mac (speech, music, typing…) with the system sound
/// classifier. Audio is analysed in memory and never stored, transcribed or sent anywhere.
/// All mutable state belongs to `queue`; only copied label names and scores reach the main queue.
/// The microphone used is the system's default input device.
final class SoundMonitor: NSObject, SNResultsObserving {
    private let queue = DispatchQueue(label: "com.local.FocusAssistant.sound", qos: .utility)
    private var engine: AVAudioEngine?
    private var analyzer: SNAudioStreamAnalyzer?
    private var generation = 0
    private var configurationObserver: NSObjectProtocol?
    private let onReading: (SoundReading) -> Void
    private let onStatus: (SoundStatus) -> Void

    /// Both callbacks are invoked on the main queue.
    init(onReading: @escaping (SoundReading) -> Void, onStatus: @escaping (SoundStatus) -> Void) {
        self.onReading = onReading
        self.onStatus = onStatus
        super.init()
    }

    /// Never raises a permission prompt: the caller settles permission first.
    func start() {
        queue.async { [self] in
            stopOnQueue()
            generation += 1
            let run = generation
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                report(.denied)
                return
            }
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // Installing a tap with an empty format raises an Objective-C exception.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                report(.failed("no usable microphone input"))
                return
            }
            var tapInstalled = false
            do {
                let request = try SNClassifySoundRequest(classifierIdentifier: .version1) // macOS 12+.
                let analyzer = SNAudioStreamAnalyzer(format: format)
                try analyzer.add(request, withObserver: self)
                self.analyzer = analyzer
                input.installTap(onBus: 0, bufferSize: 8192, format: format) { [weak self] buffer, when in
                    // The tap thread is not this queue; analysis may block, so it runs here.
                    self?.queue.async { [weak self] in
                        guard let self, self.generation == run else { return }
                        self.analyzer?.analyze(buffer, atAudioFramePosition: when.sampleTime)
                    }
                }
                tapInstalled = true
                engine.prepare()
                try engine.start()
                self.engine = engine
                configurationObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
                ) { [weak self] _ in
                    self?.queue.async { [weak self] in
                        guard let self, self.generation == run else { return }
                        self.stopOnQueue()
                        self.report(.failed("the audio input changed; press Stop, then Start"))
                    }
                }
                report(.listening)
            } catch {
                if tapInstalled { input.removeTap(onBus: 0) }
                engine.stop()
                analyzer?.removeAllRequests()
                analyzer = nil
                report(.failed("microphone or sound classifier did not start (\(String(describing: type(of: error))))"))
            }
        }
    }

    func stop() {
        queue.async { [self] in stopOnQueue() }
    }

    private func stopOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        generation += 1 // Buffers already queued for analysis are dropped.
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        analyzer?.removeAllRequests()
        engine = nil
        analyzer = nil
    }

    private func report(_ status: SoundStatus) {
        DispatchQueue.main.async { [onStatus] in onStatus(status) }
    }

    // MARK: SNResultsObserving — called on `queue`, from inside `analyze`.

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        // The header documents `classifications` as sorted with the highest confidence first.
        let top = result.classifications.prefix(3).map {
            Classification(label: $0.identifier, confidence: Float($0.confidence))
        }
        let reading = SoundReading(top: Array(top), time: ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.async { [onReading] in onReading(reading) }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        let kind = String(describing: type(of: error))
        // Unwind the analysis call before tearing the analyzer down.
        queue.async { [self] in
            guard engine != nil else { return }
            stopOnQueue()
            report(.failed("sound analysis stopped (\(kind))"))
        }
    }

    func requestDidComplete(_ request: SNRequest) { }
}
