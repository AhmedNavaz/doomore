import Foundation
import os

/// Text readings written to the macOS log, so that the person using the app and a coding
/// agent reading the log see the same numbers without screenshots. Lines hold counts,
/// angles, timings and label names only: never pixels, audio, key presses or app names.
/// Read them with `scripts/readings.sh`.
enum SharedLog {
    static let subsystem = "com.local.FocusAssistant"
    static let category = "shared"
    private static let logger = Logger(subsystem: subsystem, category: category)

    static func write(_ line: String) {
        logger.notice("\(line, privacy: .public)")
    }
}

/// Launch arguments for an unattended timed run: `--selftest <seconds> [--sound] [--capture-only] [--guided|--guided-behavior] [--no-preview]`.
/// The app starts the camera by itself, runs for that long, logs a summary and quits, so it can
/// be checked without anyone pressing buttons. `--guided` runs the spoken guided check instead
/// of a fixed time (see `GuidedCheck`); the seconds are then ignored. If macOS has no stored permission for this
/// exact build it shows its own prompt, and the run waits up to 90 s for the answer.
/// `--no-preview` hides the live picture, so resource measurements leave out drawing it.
struct SelfTestPlan: Equatable {
    var seconds: Double
    var sound: Bool
    var captureOnly: Bool
    var guided = false
    var preview = true
    var guidedSuite: GuidedCheck.Suite = .phoneSignals

    static let defaultSeconds = 12.0
    static let allowedSeconds = 3.0...900.0

    static func parse(_ arguments: [String]) -> SelfTestPlan? {
        guard let index = arguments.firstIndex(of: "--selftest") else { return nil }
        var seconds = defaultSeconds
        if index + 1 < arguments.count, let value = Double(arguments[index + 1]), value.isFinite {
            seconds = min(max(value, allowedSeconds.lowerBound), allowedSeconds.upperBound)
        }
        let guidedBehavior = arguments.contains("--guided-behavior")
        let guided = guidedBehavior || arguments.contains("--guided")
        let suite: GuidedCheck.Suite = guidedBehavior ? .behaviorEngine : .phoneSignals
        return SelfTestPlan(seconds: guided ? GuidedCheck.totalSeconds(for: suite) : seconds,
                            sound: arguments.contains("--sound"),
                            captureOnly: guided ? false : arguments.contains("--capture-only"),
                            guided: guided,
                            preview: !arguments.contains("--no-preview"),
                            guidedSuite: suite)
    }
}

enum ReadingText {
    static func number(_ value: Double?, _ digits: Int = 1) -> String {
        guard let value, value.isFinite else { return "n/a" }
        return String(format: "%.\(digits)f", value)
    }

    static func signed(_ value: Double?, _ digits: Int = 1) -> String {
        guard let value, value.isFinite else { return "n/a" }
        return String(format: "%+.\(digits)f", value)
    }

    /// A number with its unit, or a bare "n/a" when there is no value.
    static func unit(_ value: Double?, _ digits: Int, _ suffix: String) -> String {
        guard let value, value.isFinite else { return "n/a" }
        return number(value, digits) + suffix
    }

    /// One line per logged sample.
    /// `phase` is the guided-check phase, when one is running.
    static func line(elapsed: Double, snapshot: SignalSnapshot, estimate: ActivityEstimate,
                     sound: SoundReading?, soundStatus: SoundStatus, latencyMS: Double,
                     phase: String? = nil, media: MacMediaState? = nil,
                     behavior: BehaviorSnapshot? = nil) -> String {
        let vision = snapshot.vision
        var parts = ["READING", "t=\(number(elapsed))"]
        if let phase { parts.append("phase=\(phase)") }
        parts += [
            "state=\(estimate.key)",
            "for=\(unit(estimate.secondsInState, 1, "s"))",
            "phone_guess=\(estimate.possiblePhoneUse ? "yes" : "no")",
            "away_share=\(number(estimate.awayShare, 2))",
            "face=\(vision.faceCount)",
            "person=\(number(vision.personCoverage, 2))",
            "hands=\(vision.handCount)"
        ]
        if let head = vision.head {
            parts.append("pitch=\(signed(head.pitch)) yaw=\(signed(head.yaw)) roll=\(signed(head.roll))"
                + " eye_open=\(number(vision.eyeOpenness, 3))")
            if vision.pupilOffset != nil || vision.faceWidth != nil || vision.faceCenterY != nil {
                parts.append("gaze_y=\(signed(vision.pupilOffset, 3)) face_w=\(number(vision.faceWidth, 3)) face_y=\(number(vision.faceCenterY, 3))")
            }
        }
        if estimate.tilt != nil || estimate.yawOff != nil || estimate.eyeRatio != nil {
            parts.append("tilt=\(signed(estimate.tilt)) turn=\(number(estimate.yawOff)) eyes=\(number(estimate.eyeRatio, 2))")
        }
        if estimate.faceDrop != nil || estimate.softCue {
            parts.append("soft=\(estimate.softCue ? "yes" : "no") face_drop=\(signed(estimate.faceDrop, 3))")
        }
        if let face = vision.faceLuma, let frame = vision.frameLuma {
            parts.append("face_light=\(number(face, 3)) frame_light=\(number(frame, 3))")
        }
        parts.append("key=\(unit(snapshot.input.keyboard, 1, "s")) ptr=\(unit(snapshot.input.pointer, 1, "s"))")
        if let first = sound?.top.first {
            parts.append("sound=\(first.label):\(number(Double(first.confidence), 2))")
        } else {
            parts.append("sound=\(soundStatus.key)")
        }
        if let classifier = vision.classifier {
            parts.append("phone=\(number(classifier.phoneConfidence.map(Double.init), 4))")
            if let first = classifier.topLabels.first {
                parts.append("top=\(first.label):\(number(Double(first.confidence), 2))")
            }
        }
        if let media {
            parts.append("mac_video=\(MacMediaState.key(media.videoPlaying)) mac_audio=\(MacMediaState.key(media.audioPlaying))")
        }
        if let behavior {
            parts.append("idle_stretch=\(unit(behavior.idleStretchSeconds, 1, "s")) cue_share=\(number(behavior.idleStretchCueShare, 2))")
        }
        parts.append("analysis=\(unit(latencyMS, 1, "ms"))")
        return parts.joined(separator: " ")
    }
}

/// Text-only totals of one run, logged when it ends. Constant memory: running minimum,
/// maximum and sum, not a list of samples.
struct RunSummary {
    struct Spread: Equatable {
        private(set) var minimum = Double.infinity
        private(set) var maximum = -Double.infinity
        private(set) var sum = 0.0
        private(set) var count = 0

        mutating func add(_ value: Double?) {
            guard let value, value.isFinite else { return }
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            sum += value
            count += 1
        }

        var mean: Double? { count > 0 ? sum / Double(count) : nil }
        var low: Double? { count > 0 ? minimum : nil }
        var high: Double? { count > 0 ? maximum : nil }
    }

    private(set) var samples = 0
    private(set) var faceSamples = 0
    private(set) var personCoverage = Spread()
    private(set) var handSamples = 0
    private(set) var pitch = Spread()
    private(set) var yaw = Spread()
    private(set) var keyboard = Spread()
    private(set) var pointer = Spread()
    private(set) var stateSeconds: [String: Double] = [:]
    private(set) var phoneGuessSeconds = 0.0
    private(set) var soundWindows = 0
    private(set) var soundTop: [String: Int] = [:]
    private var lastTime: Double?

    mutating func add(_ snapshot: SignalSnapshot, _ estimate: ActivityEstimate) {
        samples += 1
        if snapshot.vision.faceCount > 0 { faceSamples += 1 }
        personCoverage.add(snapshot.vision.personCoverage)
        if snapshot.vision.handCount > 0 { handSamples += 1 }
        pitch.add(snapshot.vision.head?.pitch)
        yaw.add(snapshot.vision.head?.yaw)
        keyboard.add(snapshot.input.keyboard)
        pointer.add(snapshot.input.pointer)
        // Time is credited to the state held at the end of each gap; long gaps are capped.
        if let lastTime, snapshot.time > lastTime {
            let step = min(snapshot.time - lastTime, 2)
            stateSeconds[estimate.key, default: 0] += step
            if estimate.possiblePhoneUse { phoneGuessSeconds += step }
        }
        lastTime = snapshot.time
    }

    mutating func add(sound reading: SoundReading) {
        soundWindows += 1
        if let label = reading.top.first?.label { soundTop[label, default: 0] += 1 }
    }

    func lines(metrics: CaptureMetrics, baseline: ActivityEstimator.Baseline?, soundStatus: SoundStatus,
               reason: String, stopMilliseconds: Double?) -> [String] {
        let n = ReadingText.number, s = ReadingText.signed, u = ReadingText.unit
        var result = [
            "SUMMARY end=\"\(reason)\" frames=\(metrics.deliveredFrames) size=\(Int(metrics.imageSize.width))x\(Int(metrics.imageSize.height))"
                + " fps=\(n(metrics.captureFPS, 1)) drops=\(metrics.droppedFrames) samples=\(samples)"
                + " analysis_mean=\(u(metrics.meanLatencyMS, 1, "ms")) analysis_p95=\(u(metrics.p95LatencyMS, 1, "ms"))"
                + " stop=\(u(stopMilliseconds, 0, "ms"))"
        ]
        guard samples > 0 else { return result }
        result.append("SUMMARY face=\(faceSamples)/\(samples) hands=\(handSamples)/\(samples)"
            + " person_cover_min_mean_max=\(n(personCoverage.low, 2))/\(n(personCoverage.mean, 2))/\(n(personCoverage.high, 2))"
            + " pitch_min_mean_max=\(s(pitch.low, 1))/\(s(pitch.mean, 1))/\(s(pitch.high, 1))"
            + " yaw_min_mean_max=\(s(yaw.low, 1))/\(s(yaw.mean, 1))/\(s(yaw.high, 1))"
            + " straight_ahead_pitch=\(s(baseline?.pitch, 1)) straight_ahead_yaw=\(s(baseline?.yaw, 1))"
            + " straight_ahead_eye_open=\(n(baseline?.eyeOpenness, 3))")
        result.append("SUMMARY keyboard_idle=\(u(keyboard.low, 1, "s"))..\(u(keyboard.high, 1, "s"))"
            + " pointer_idle=\(u(pointer.low, 1, "s"))..\(u(pointer.high, 1, "s"))")
        let states = stateSeconds.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key)=\(u($0.value, 1, "s"))" }.joined(separator: " ")
        result.append("SUMMARY states \(states) phone_guess=\(u(phoneGuessSeconds, 1, "s"))")
        let sounds = soundTop.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }.joined(separator: ",")
        result.append("SUMMARY sound=\(soundStatus.key) windows=\(soundWindows)" + (sounds.isEmpty ? "" : " top=\(sounds)"))
        return result
    }
}
