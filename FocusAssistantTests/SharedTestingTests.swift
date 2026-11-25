import XCTest
@testable import FocusAssistant

/// Text formatting and argument parsing only. Nothing here opens a camera or writes a log.
final class SharedTestingTests: XCTestCase {
    func testNormalLaunchHasNoSelfTest() {
        XCTAssertNil(SelfTestPlan.parse(["/path/FocusAssistant"]))
        XCTAssertNil(SelfTestPlan.parse(["/path/FocusAssistant", "--sound", "15"]))
    }

    func testSelfTestArguments() {
        XCTAssertEqual(SelfTestPlan.parse(["app", "--selftest"]),
                       SelfTestPlan(seconds: 12, sound: false, captureOnly: false))
        XCTAssertEqual(SelfTestPlan.parse(["app", "--selftest", "20", "--sound"]),
                       SelfTestPlan(seconds: 20, sound: true, captureOnly: false))
        XCTAssertEqual(SelfTestPlan.parse(["app", "--capture-only", "--selftest", "30"]),
                       SelfTestPlan(seconds: 30, sound: false, captureOnly: true))
    }

    func testGuidedSelfTestRunsForTheWholeCheckWithAnalysis() {
        XCTAssertEqual(SelfTestPlan.parse(["app", "--selftest", "5", "--guided", "--capture-only", "--sound"]),
                       SelfTestPlan(seconds: GuidedCheck.totalSeconds, sound: true, captureOnly: false, guided: true))
    }

    func testNoPreviewOptionHidesThePicture() {
        XCTAssertEqual(SelfTestPlan.parse(["app", "--selftest", "60", "--no-preview"])?.preview, false)
        XCTAssertEqual(SelfTestPlan.parse(["app", "--selftest", "60"])?.preview, true)
    }

    func testSelfTestSecondsAreClampedAndBadValuesUseTheDefault() {
        XCTAssertEqual(SelfTestPlan.parse(["app", "--selftest", "1"])?.seconds, 3)
        XCTAssertEqual(SelfTestPlan.parse(["app", "--selftest", "99999"])?.seconds, 900)
        XCTAssertEqual(SelfTestPlan.parse(["app", "--selftest", "soon"])?.seconds, 12)
        XCTAssertEqual(SelfTestPlan.parse(["app", "--selftest", "nan"])?.seconds, 12)
        XCTAssertEqual(SelfTestPlan.parse(["app", "--selftest", "--sound"]),
                       SelfTestPlan(seconds: 12, sound: true, captureOnly: false))
    }

    func testNumbersAreFormattedAndMissingValuesAreMarked() {
        XCTAssertEqual(ReadingText.number(1.26, 1), "1.3")
        XCTAssertEqual(ReadingText.number(nil), "n/a")
        XCTAssertEqual(ReadingText.number(.infinity), "n/a")
        XCTAssertEqual(ReadingText.signed(4.06, 1), "+4.1")
        XCTAssertEqual(ReadingText.signed(-4.06, 1), "-4.1")
        XCTAssertEqual(ReadingText.signed(.nan), "n/a")
        XCTAssertEqual(ReadingText.unit(84.6, 0, "ms"), "85ms")
        XCTAssertEqual(ReadingText.unit(nil, 0, "ms"), "n/a")
    }

    func testReadingLineCarriesEverySignal() {
        var vision = VisionSignals()
        vision.faceCount = 1
        vision.personCoverage = 0.416
        vision.handCount = 2
        vision.head = HeadPose(pitch: 31.24, yaw: -4.1, roll: 1)
        vision.eyeOpenness = 0.2114
        vision.classifier = ClassifierReading.summarize([
            Classification(label: "adult", confidence: 0.934),
            Classification(label: "phone", confidence: 0.0293)
        ])
        let snapshot = SignalSnapshot(time: 100, vision: vision, input: InputIdle(keyboard: 14.2, pointer: 9.8))
        let estimate = ActivityEstimate(posture: .down, inputActive: false, secondsInState: 6.5,
                                        possiblePhoneUse: true, tilt: -19.8, yawOff: 4.1, eyeRatio: 0.684, awayShare: 0.63)
        let sound = SoundReading(top: [Classification(label: "speech", confidence: 0.82)], time: 99)

        let line = ReadingText.line(elapsed: 12.5, snapshot: snapshot, estimate: estimate,
                                    sound: sound, soundStatus: .listening, latencyMS: 41.26, phase: "phone")

        XCTAssertEqual(line, "READING t=12.5 phase=phone state=down-idle for=6.5s phone_guess=yes away_share=0.63"
            + " face=1 person=0.42 hands=2"
            + " pitch=+31.2 yaw=-4.1 roll=+1.0 eye_open=0.211 tilt=-19.8 turn=4.1 eyes=0.68"
            + " key=14.2s ptr=9.8s sound=speech:0.82 phone=0.0293 top=adult:0.93 analysis=41.3ms")
    }

    func testReadingLineWithoutFaceOrSoundSaysSo() {
        let snapshot = SignalSnapshot(time: 5, vision: VisionSignals(), input: InputIdle(keyboard: .infinity, pointer: 2))
        let estimate = ActivityEstimate(posture: .nobody, inputActive: true, secondsInState: 1,
                                        possiblePhoneUse: false, tilt: nil, yawOff: nil, eyeRatio: nil)

        let line = ReadingText.line(elapsed: 1, snapshot: snapshot, estimate: estimate,
                                    sound: nil, soundStatus: .denied, latencyMS: 20)

        XCTAssertEqual(line, "READING t=1.0 state=nobody-active for=1.0s phone_guess=no away_share=0.00 face=0 person=0.00 hands=0"
            + " key=n/a ptr=2.0s sound=denied analysis=20.0ms")
    }

    func testSummaryTotalsStatesAndSounds() {
        var summary = RunSummary()
        func snapshot(_ time: Double, pitch: Double, hands: Int) -> SignalSnapshot {
            var vision = VisionSignals()
            vision.faceCount = 1
            vision.personCoverage = pitch > 20 ? 0.5 : 0.3
            vision.handCount = hands
            vision.head = HeadPose(pitch: pitch, yaw: 2, roll: 0)
            return SignalSnapshot(time: time, vision: vision, input: InputIdle(keyboard: time, pointer: 30))
        }
        let facing = ActivityEstimate(posture: .facing, inputActive: false, secondsInState: 0,
                                      possiblePhoneUse: false, tilt: 0, yawOff: 0, eyeRatio: nil)
        let down = ActivityEstimate(posture: .down, inputActive: false, secondsInState: 6,
                                    possiblePhoneUse: true, tilt: 20, yawOff: 0, eyeRatio: nil)
        summary.add(snapshot(10.0, pitch: 4, hands: 0), facing)
        summary.add(snapshot(10.5, pitch: 6, hands: 0), facing)
        summary.add(snapshot(11.0, pitch: 26, hands: 1), down)
        summary.add(snapshot(20.0, pitch: 24, hands: 0), down) // A 9 s gap counts as 2 s.
        summary.add(sound: SoundReading(top: [Classification(label: "speech", confidence: 0.9)], time: 10))
        summary.add(sound: SoundReading(top: [Classification(label: "speech", confidence: 0.8)], time: 12))
        summary.add(sound: SoundReading(top: [Classification(label: "music", confidence: 0.7)], time: 14))

        var metrics = CaptureMetrics(inferenceConfigured: true)
        metrics.deliveredFrames = 300
        metrics.imageSize = CGSize(width: 1280, height: 720)
        metrics.captureFPS = 29.96
        metrics.meanLatencyMS = 40
        metrics.p95LatencyMS = 55.5
        let lines = summary.lines(metrics: metrics, baseline: ActivityEstimator.Baseline(pitch: 5, yaw: 2, eyeOpenness: 0.3123),
                                  soundStatus: .listening, reason: "Stopped — camera off", stopMilliseconds: 84.6)

        XCTAssertEqual(lines, [
            "SUMMARY end=\"Stopped — camera off\" frames=300 size=1280x720 fps=30.0 drops=0 samples=4"
                + " analysis_mean=40.0ms analysis_p95=55.5ms stop=85ms",
            "SUMMARY face=4/4 hands=1/4 person_cover_min_mean_max=0.30/0.40/0.50 pitch_min_mean_max=+4.0/+15.0/+26.0"
                + " yaw_min_mean_max=+2.0/+2.0/+2.0 straight_ahead_pitch=+5.0 straight_ahead_yaw=+2.0"
                + " straight_ahead_eye_open=0.312",
            "SUMMARY keyboard_idle=10.0s..20.0s pointer_idle=30.0s..30.0s",
            "SUMMARY states down-idle=2.5s facing-idle=0.5s phone_guess=2.5s",
            "SUMMARY sound=listening windows=3 top=speech:2,music:1"
        ])
    }

    func testSummaryOfARunWithoutSamplesIsOneLine() {
        let lines = RunSummary().lines(metrics: CaptureMetrics(), baseline: nil, soundStatus: .off,
                                       reason: "Camera did not start.", stopMilliseconds: nil)
        XCTAssertEqual(lines, [
            "SUMMARY end=\"Camera did not start.\" frames=0 size=0x0 fps=0.0 drops=0 samples=0"
                + " analysis_mean=0.0ms analysis_p95=0.0ms stop=n/a"
        ])
    }
}
