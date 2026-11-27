# Milestone 0 — actual results and Gate 0 handoff

Recorded 25 November 2026. **Gate 0: NOT PASSED.** Until the evening this was the specification's camera-only fallback plus a whole-image Vision classifier experiment. In the evening the developer changed direction to reading several signals at once: head position, person, hands, keyboard and pointer activity, and sound. See [decisions](decisions.md#direction-change--25-november-2026-evening) and the [evening session](#evening-session-signals-and-shared-testing) below. No object detector is included. No phone-recognition, energy, or accuracy result is claimed.

## Observed environment

| Field | Actual observation |
|---|---|
| Device | MacBook Pro, M3 Pro (11 cores), 18 GB memory |
| Architecture | arm64 |
| OS | macOS 27.0.1 (26A434) |
| Xcode | 27.1 (27A9275) |
| SDK / compiler | macOS 27.0 / Apple Swift 6.4, project language mode Swift 5 |
| Deployment target | macOS 14.0; no macOS 14 execution test |
| App / scheme | `FocusAssistant`, `com.local.FocusAssistant` |
| Camera discovery | Diagnostics UI lists “FaceTime HD Camera (built-in)” |
| Camera authorization / live frames | Until 21:26 exercised only by the developer. From 21:26 the agent's self-test started capture itself; the developer answered the macOS prompts |

No agent has answered a permission prompt; macOS shows those to the developer. Since the evening session the agent can start a timed capture by itself with `scripts/selftest.sh` and read the app's text readings. It cannot see the camera image or the window.

## Executed checks

Commands ran from `/Users/m1/ReactProjects/doomore`. Times are PKT on 25 November 2026. Logs and result bundles are under the git-ignored `build/` folder.

### Current sources

Unit tests:

```sh
xcodebuild -project FocusAssistant.xcodeproj -scheme FocusAssistant -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData test
```

**TEST SUCCEEDED**, exit 0, at 21:34, on the sources as they are now. **61 tests executed, 0 failures.** Log: `build/test-signals.log`. The 33-test run at 20:36:16 (`build/test-720.log`, bundle `build/Milestone0-720.xcresult`) predates the signal work.

| Suite | Executed | What the result covers |
|---|---:|---|
| CaptureFormatTests | 3 | Choice of the exact 1280×720 mode from plain format descriptions, including the built-in camera's observed list; refusal when no exact mode exists; `420v`/frame-rate/order preference. Does not touch a real `AVCaptureDevice` |
| PreviewGeometryTests | 10 | Lower-left to top-left mapping, aspect fit/letterbox placement, mirroring, clipping, invalid inputs |
| ClassifierReadingTests | 7 | Ordering by score regardless of input order, exact `phone` identifier match, count of higher-scoring labels including ties, non-finite scores, empty input. Synthetic scores only |
| InferenceScheduleTests | 6 | Monotonic sampling, interval changes, invalid/out-of-order time, gaps without catch-up, reset |
| RunTokenTests | 4 | Delayed callbacks rejected after cancellation or replacement; repeat cancellation |
| PhoneDetectorTests | 3 | Fake's known result using synthetic pixel buffer; empty result distinguished from thrown failure |
| ActivityEstimatorTests | 17 | The guess rules as written: learning straight-ahead, looking down, turned away, face hidden, nobody in view, the five-second flag, keyboard or pointer use cancelling it, one odd sample being ignored, learning again. Synthetic samples only |
| SharedTestingTests | 8 | Self-test argument parsing and clamping; the exact text of the reading and summary lines |
| VisionSignalProbeTests | 3 | The real system models on a blank synthetic frame, inside the sandboxed test host: every request runs, no face, no hands, person coverage below 0.05, `phone` label reported. The probe can be reused. The idle counters are readable in the sandbox |

These tests do **not** exercise AVFoundation hardware, permission dialogs, the microphone or the sound classifier, any real face, hand or phone, real model localization, actual preview alignment, races inside the operating system, or energy. The estimator tests check the rules as written; they say nothing about whether the rules match what a person does. Model letterbox/decode/NMS tests are inapplicable until an actual model adapter is selected. No mocked phone result is presented by the app.

Release build and signature read-back. **Updated 26 Nov 2026 (19:50 PKT):** the current Release product (`build/DerivedData/Build/Products/Release/FocusAssistant.app`, built 26 Nov 02:37, newer than all Swift sources) was read back with `codesign -dv` and `codesign --display --entitlements -`: flags `adhoc,runtime` (no team identifier), entitlements `com.apple.security.app-sandbox`, `com.apple.security.device.audio-input`, `com.apple.security.device.camera`, `com.apple.security.get-task-allow`. The earlier 20:36 table below predated the microphone entitlement:

```sh
xcodebuild -project FocusAssistant.xcodeproj -scheme FocusAssistant -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
codesign --display --entitlements - build/DerivedData/Build/Products/Release/FocusAssistant.app
codesign -dv build/DerivedData/Build/Products/Release/FocusAssistant.app
codesign -d -r- build/DerivedData/Build/Products/Release/FocusAssistant.app
codesign --verify --deep --strict --verbose=2 build/DerivedData/Build/Products/Release/FocusAssistant.app
xcrun vtool -show-build build/DerivedData/Build/Products/Release/FocusAssistant.app/Contents/MacOS/FocusAssistant
find build/DerivedData/Build/Products/Release/FocusAssistant.app -type f
```

**BUILD SUCCEEDED**, exit 0, at 16:06:44. Log: `build/build-release-final.log`. Both products are newer than every source file. Read back from that app:

Current Release build: **BUILD SUCCEEDED**, exit 0, at 20:36:06, log `build/build-release-720.log`. Its flags (`adhoc,runtime`, no team identifier) and its three entitlements were read back again and match the table below; the other rows were not re-read for this build.

| Property | Observed |
|---|---|
| Signature | Ad-hoc, flags `adhoc,runtime` (hardened-runtime flag set), no team identifier |
| Verification | “valid on disk”, “satisfies its Designated Requirement”; that requirement is the code hash of this exact build |
| Entitlements | `com.apple.security.app-sandbox`, `com.apple.security.device.camera`, `com.apple.security.get-task-allow` |
| Minimum OS / SDK | 14.0 / 27.0 |
| Bundle contents | Executable, `Info.plist`, `PkgInfo`, code-signature resources. No model or other resource files |

The third entitlement is not in the source file. Xcode injects it into local builds; it is kept deliberately, and the reasoning is in [decisions](decisions.md#distribution-and-privacy). The Debug app differs: its flags are `adhoc` only, because Xcode logs “Disabling hardened runtime with ad-hoc codesigning” for that configuration, and as the test host it also carries test-runner exceptions (read-only file access to `/` and Mach lookups for `com.apple.testmanagerd`, `com.apple.dt.testmanagerd.runner`, `com.apple.coresymbolicationd`). Use the Release app for manual evaluation, not the Debug test host.

Build without the debugging entitlement, as a check of the documented switch:

```sh
xcodebuild -project FocusAssistant.xcodeproj -scheme FocusAssistant -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData-noinject CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build
```

**BUILD SUCCEEDED**, exit 0. That app was signed with sandbox and camera only and kept the `adhoc,runtime` flags. The throwaway build folder was deleted afterwards; its log is `build/build-release-noinject.log`. It was made before the last two comment-only source edits and is not the artifact used anywhere else in this document.

Log messages that are not failures:

- The SDK's AppIntents step warns that metadata extraction was skipped (the app has no AppIntents dependency).
- The test host logs connection errors for the system service `com.apple.linkd.autoShortcut`.
- The test host logs one `CMIOObjectGetPropertyData Error: 2003332927`. That number is the four-character code `'who?'`, `kCMIOHardwareUnknownPropertyError` in the SDK's `CMIOHardware.h`. It appeared as the diagnostics model listed cameras at launch. No capture session is started by the tests.

### Not seen on screen

The window was rewritten in the evening session: one Start, a “What the app thinks you are doing” box, a Signals box, and the counters folded into a disclosure. **Nobody has looked at it yet.** The agent cannot see the screen and no screenshot of the new window exists. It compiles; its layout, wrapping, checkboxes and on-screen wording are unverified.

### Earlier runs in this increment

| Time | Run | Outcome |
|---|---|---|
| 15:31 | First Debug build | Succeeded. Log: `build/build-first.log` |
| 15:33 | First test attempt | App and test bundle compiled, but the restricted execution sandbox denied `com.apple.testmanagerd.control` and Xcode failed before executing any test (recorded process exit 133). An infrastructure failure, not a test result. Log: `build/test.log` |
| 15:36 | Test rerun with test-runner access | 23 tests, 0 failures. Superseded by the 30-test run above. Log: `build/test-verified.log`; bundle: `build/Milestone0-verified.xcresult` |
| 15:38 | Release build | Succeeded. Superseded by the 16:06 build. Log: `build/build-release.log` |
| 15:52–15:53 | Tests and Release build after the `phone` row and permission-status changes | 30 tests, 0 failures; build succeeded. Rerun at 16:06 after two comment-only source edits, and the rerun overwrote these logs |

The classifier label query (revision 2, 1,303 identifiers, including exact `phone`) and the result-structure check on synthetic frames are recorded with their actual output in [model evaluation](model-evaluation.md).

### First live session (25 November 2026, developer M3 Pro, FaceTime HD Camera)

| Check | Observed |
|---|---|
| Consent after `tccutil reset` | Developer allowed the prompt. Exact status text after the prompt was not reported |
| First Start in Capture only (16:11) | **Failed.** Status: “Camera or classifier setup failed (SetupFailure)”. The system log shows the camera input and the video data output were added at 640×480. AVFoundation then rejected the manually built preview-layer connection: “source and destination media types are incompatible”. The app tore the session down, so no frames were delivered |
| Fix (16:13) | The preview is now attached by trying the data output's own input port first, then every other video port. If none is accepted, capture continues, the status line says “preview unavailable”, and the port media types are logged (subsystem `com.local.FocusAssistant`, no image data). Setup errors now name the failing step. Release build succeeded (`build/build-release-preview-fix.log`) |
| Second Start in Capture only (16:13:24–16:14:07) | **Capture worked, preview did not.** Counters from the developer's screenshot: 1,240 delivered, 0 AVF drops, **1920 × 1080** frames, 29.0 delivered fps. The 640×480 session preset was accepted but did not limit the data-output frame size. The log listed input ports `vide` (`420v`), `clcp`, `mobj`. The single video port, the one the data output uses, was still rejected for the preview layer. Leaving the window stopped capture as designed (status “Diagnostics inactive — camera off”); the log shows `stopRunning` followed by `CMIODeviceStopStream` 55 ms later. Camera indicator, mirror and orientation were not observed |
| Fix 2 (16:15) | The preview is attached after the configuration is committed. If manual connections are rejected, the layer's session is reassigned so that AVFoundation forms the connection implicitly. The path taken is logged. Release build succeeded (`build/build-release-preview-fix2.log`); unit tests not rerun |
| Third Start in Capture only (16:17:16–16:17:25) | **Preview worked.** Status: “Camera active · FaceTime HD Camera”. Developer's screenshot, taken about 8 s after Start: upright live image, aspect-fit with side bars, no overlay box; 205 delivered, 0 AVF drops, 1920 × 1080, 25.3 delivered fps. That fps figure is an average since Start and includes camera start-up; this run and the 1,240-frame run both fit about 30 fps after roughly 1.3–1.4 s of start-up (estimate from the counters, not a measurement). The log shows no connection rejection and neither fallback message, so the explicit preview connection was accepted once it was added after the configuration commit. The session-reassignment fallback did not run and is unexercised. Capture ended 9.0 s after Start through `CameraService.stop`, not a failure path; whether Stop was pressed or the window was left was not reported. `CMIODeviceStopStream` followed `stopRunning` by 21 ms and device cleanup finished about 0.1 s after it. Not reported: camera indicator, and the mirror toggle against an asymmetric object. In Capture only the “Inference skips” counter equals the delivered count, which is misleading because no inference is configured. The screenshot contains the developer's camera image; it was not copied into the workspace |
| Camera formats (read-only query after the third start, camera off) | A throwaway Swift program listed `AVCaptureDevice.formats` for the built-in camera without creating a capture input; it was not kept. Seven formats, all `420v` at 15–30 fps: 1920×1080 (active), 1280×720, 1080×1920, 1760×1328, 640×480, 1328×1760, 1552×1552. So 1280×720 and 640×480 exist as native modes. The app still receives 1920×1080; frame size is an open decision in [decisions](decisions.md#pipeline-and-lifecycle) |
| Developer decision | Frame size **1280×720** |
| Fix 3 (20:36) | No session preset; the device's exact native 1280×720 format is selected while capture is configured, and the active format is logged after start (`Capture running; device active format …`). The unexercised session-reassignment preview fallback was removed. “Inference skips” now counts only frames the classifier schedule declined, and shows “n/a” in Capture only. Release build succeeded (`build/build-release-720.log`); 33 unit tests passed. The previous Release app was closed with SIGTERM first; its camera was already off. **Not yet run on the camera.** As an ad-hoc build, this app may trigger the camera permission prompt again |
| Fix 3 on camera (20:44–20:47) | Three Capture-only starts (Debug, Release, Debug). Every log line reads `device active format 1920×1080, requested 1280×720`, and the screenshots show 1920 × 1080 at 26.9–28.1 fps with 0 AVF drops and “Inference skips” n/a. **720p did not hold.** The 20:47 Debug run already included the added `hd1280x720` session preset (`.inputPriority` does not exist on macOS and does not compile). With Mirror preview off the image was unmirrored and with it on mirrored, so the mirror toggle works (developer screenshots, observed by the agent) |
| Format probe (about 20:50, developer approved) | A throwaway Swift program, not kept, turned the FaceTime camera on for about 1.5 s per trial and recorded only buffer dimensions. Center Stage, Portrait and Studio Light were all off. In a bare session, every method held **1280×720** for both the active format and the delivered buffers: preset plus format before commit (the app's method), format with the lock held across `startRunning`, format set after `startRunning`, and preset alone. A copy of the app's preview setup could not attach a preview connection outside a window, so the preview's effect could not be reproduced |
| Fix 4 on camera (Debug, 20:51) | The app logs the active format after each stage: after configure **1280×720**, after the preview was attached (true) **1280×720**, after `startRunning` **1920×1080**. The app set 1280×720 again on the running session, and 18 ms later the log reads `Capture running; device active format 1280×720`. Developer screenshot: **1280 × 720**, 26.3 delivered fps (an average since Start that includes start-up), 299 delivered, 0 AVF drops, “Inference skips” n/a, upright mirrored preview. So the reset happens in `startRunning`, not when the preview is attached; why it happens in the app and not in the bare probe session is unknown. Afterwards, the unused second format reset after the preview attach was removed. That cleanup compiled in Debug but has not been run on the camera, and unit tests were not rerun. Camera indicator still not reported |
| Unit tests after cleanup | 33 tests, 0 failures |
| Cleaned-up build on camera (Debug built 20:58:24; starts 20:58:28 and 20:58:34) | Both starts log the same sequence: 1280×720 after configure and after preview attach, 1920×1080 after `startRunning`, then 1280×720 again 5–7 ms later. **720p fix confirmed on the final code** |
| First classifier scene (Vision classifier spike, Debug, 20:58–20:59) | Scene: phone **held visibly** in one hand at chest/face height, user looking at it; indoor room light; one distance. Developer screenshot: 1,228 delivered, 0 AVF drops, 1280 × 720, 29.0 delivered fps, 41 inferences, 1,187 inference skips, 0.97 Hz inference rate. Latency latest 17.6 ms, mean 19.8 ms, p95 28.6 ms (**Debug build**, not a Release measurement). **`phone` row: 0.0293, 14 of 1,303 labels score higher.** Top five: adult 0.934, people 0.934, eyeglasses 0.841, optical_equipment 0.841, consumer_electronics 0.729. So the classifier scored a broad `consumer_electronics` label high, but the exact `phone` label stayed low, even with the phone clearly in view and in use. That is one scene with no no-phone baseline yet, so it says nothing about how the score moves. It is consistent with the expectation that a whole-image classifier is not a usable phone signal |

### Evening session: signals and shared testing

### First guided phone check (26 November 2026, 01:50:09–01:50:44)

The developer ran the guided check in the Debug build on the FaceTime HD Camera, with sound on and the phone held below the camera. The phases were 10 s screen, 15 s phone and 10 s screen-again. Two earlier attempts at 01:46:27 and 01:46:33 were cancelled after 1 s and 10 s because the window lost focus ("Window not in front — camera off").

App totals, scored by the requested phase: phone guess in 52% of phone-phase samples and in 45% of screen samples (0% in the first screen phase, 89% in screen-again). 1,051 frames, 1280×720, 29.7 fps, 0 drops, 68 samples, analysis mean 35.2 ms / p95 51.7 ms (Debug), stop 102 ms. Face found in 68 of 68 samples, hands in 0.

The per-sample readings show that those totals mostly measure the person's reaction time and the guess's delay, not misreadings:

| Time into run | What the readings show |
|---|---|
| 0.6–14.0 s | Facing the screen. Tilt from straight-ahead −1.0 to +7.7°, eye openness 0.70–1.14 of straight-ahead (one 0.70 reading at 14.0 s, as the head started down). The phone cue came at about 10.3 s |
| 14.5 s | Head down: tilt +11.8°, eyes 0.56. That was about 4 s after the phone cue |
| 14.5–29.4 s | Head down throughout: tilt +8.8 to +15.2°, eyes 0.40–1.01 (mostly 0.5–0.9), yaw within 8° of straight-ahead. Keyboard and pointer idle |
| 17.6 s | Phone guess switched on, 3.1 s after the head went down, when half of the 8 s window was away |
| 25.3 s | Screen-again cue. The head stayed down for another 4 s |
| 29.9 s | Head back up: tilt +3.2°, eyes 1.17 |
| 29.9–33.6 s | Phone guess still on for 3.7 s while facing the screen, until the window fell below half away. This was a rule defect |

What this establishes, for one person, one sitting and one way of holding a phone:

- **Pitch sign settled.** Looking down raised pitch, as the SDK header states. The earlier reading in the opposite direction came from unlabelled data.
- **Tilt separated the two activities in this run.** Settled at the screen, tilt stayed within −1.0 to +5.9°. The seconds just before the head dropped reached +7.4 and +7.7°, and phone use was at least +8.8°. The 8° threshold therefore has about 1° of margin at the transition, which is narrow.
- **Eye openness helped, but less clearly.** Readings during phone use were mostly 0.5–0.9 of straight-ahead, against 0.95–1.14 while settled at the screen. Some phone samples reached 1.01, and one screen sample read 0.86.
- **Head turning did not help here.** Yaw stayed within 8°, so the 20° turned rule never fired. A phone held to one side may still turn the head, as the 25 Nov readings suggested.
- **Not established:** accuracy, behaviour with the phone held at eye level (as in the 20:59 screenshot), reading paper, looking at the keyboard, other people, lighting or glasses-free eyes. The phases describe what was requested, not independently verified activity.

Changes made from this run:

- The phone guess now clears after the head has faced the screen for 1.5 s (`returnSeconds`), instead of waiting for the 8 s window to empty.
- The guided check is now 12 s screen, 20 s phone and 15 s screen-again. The first 5 s of each phase are logged but not scored (`settle_seconds=5`), and the result line uses only scored samples.
- A running guided check is no longer cancelled when the window loses focus. It still ends after about 47 s and turns the camera off.
- `GuidedReplayTests` replays the 67 logged readings of this run through the estimator, so later rule changes are checked against real data.

Replaying the logged readings with the new rules, scored on the old phase times with 5 s settle: phone guess in 15 of 19 settled phone samples (0.79), and 1 of 18 settled screen samples (0.06). That one sample came 1.1 s after the head came back up. This is a replay of one run, not a new live measurement.

Checks: the estimator, guided-check and replay test classes passed (34 tests) and the Debug app compiled on 26 Nov at 01:54. The full test suite was not rerun. The new rules, phase lengths and focus behaviour have not been tried live.

### Follow-up: unlabelled phone session and guided check

The developer reported completing a screen / phone / screen exercise. In the 21:45:17–21:46:23 readings, the old estimator reported no phone guess. Around 21:45:33–21:45:37 yaw differed from its baseline by about 33–45° and pitch fell by about 4–17°, while input was idle. Those timestamps were not labelled during capture, so this cannot establish which readings were phone use or measure accuracy. Eye landmarks were not recorded in that run.

The prototype now uses an experimental 8° pitch change in either direction, 20° yaw, relative eye-outline openness, and a rolling window of away samples with idle input. These changes can also flag looking up, blinking, reading or other non-phone behaviour. The spoken guided check marks screen, phone and screen-again phases and logs per-phase totals; it was first run live on 26 Nov (see above). Its labels describe the requested activity, not independently verified ground truth.

The interrupted session ran 74 unit tests successfully before a subsequent sound-summary fix. A Debug build succeeded after that fix; the tests were not rerun after it. The guided UI, spoken cues, eye landmarks, revised thresholds and sound-summary fix remain unverified on live input. Earlier timing numbers do not include the new landmark request.

The normal Stop path now preserves the sound status for its summary; it has not yet been verified with a live sound run. The older defect noted below describes the earlier build.

### Earlier evening runs

After the developer's direction change. All runs are the Debug build on the built-in camera. “Camera status flag” is the system's own flag for a camera being switched on by any app, read by `scripts/camera-in-use.swift` without opening the camera. The full text of the last run is in `build/selftest-last.txt`.

| Time | Check | Observed |
|---|---|---|
| 21:19 | Unit tests after adding the signals, the guess and the shared log | 57 tests, 0 failures |
| 21:19:41 | Self-test 1 (12 s) | Refused before the camera opened: permission “not determined” for this build. The system permission log says “Failed to match existing code requirement for subject com.local.FocusAssistant and service kTCCServiceCamera” and lists the stored and the current code hash. At this point a self-test did not raise prompts. The app also failed to quit and was closed by the script |
| 21:25 | Unit tests including the real Vision requests on a blank frame | 60 tests, 0 failures. The first analysis took 5.9 s (model loading); a second probe analysed two 640×480 frames in 0.03 s. Idle counters inside the sandbox: keyboard 313.2 s, pointer 8.4 s; unsandboxed about a second later: 314.3 s and 9.5 s |
| 21:26:19–21:26:36 | Self-test 2 (12 s, no sound). Build: models loaded before the camera starts; a self-test may now raise the prompt. The developer answered the camera prompt after 3 s | **First agent-run capture.** Camera status flag: off before, on during, off after. 341 frames, 1280×720, 29.1 fps, 0 drops, 23 samples, analysis mean 37.8 ms / p95 60.9 ms, stop 101 ms. Face in 22 of 23 samples; the miss was the very first frame (top label `outdoor` 0.50). **Upper-body person detector: 0 of 23.** Hands reported in 13 of 23 samples (one hand in every logged line). Pitch −19.4 / −14.8 / −11.8° (min / mean / max), yaw −6.5 / −2.5 / +1.1°; learned straight-ahead −15.3° / −5.0°. Keyboard idle 359–370 s, pointer idle 0–5.9 s. States: 0.5 s of “no one in view” from the first-frame miss, learning 2.5 s, facing with input 5.7 s, then facing without input 2.6 s once the pointer had been still for 3 s. `phone` label 0.0002–0.0010. The app did not quit by itself |
| 21:34 | Unit tests after three fixes: quit at once when the camera is off; person segmentation instead of the upper-body detector; first 15 frames not analysed | 61 tests, 0 failures |
| 21:35:05–21:36:40 | Self-test 3 (20 s, sound), final build | macOS showed the camera prompt at 21:35:06 and nobody answered. The run ended after 90 s as designed without opening the camera, and the app quit by itself |
| 21:39:08–21:39:32 | Self-test 4 (20 s, sound), same build. The developer answered the camera and microphone prompts within 3 s | **Final build on camera and microphone.** Camera status flag: off before, on during, off after; the app quit by itself. 578 frames, 1280×720, 29.1 fps, 0 drops, 38 samples, analysis mean 49.5 ms / p95 74.7 ms (four Vision requests per sample), stop 207 ms. Face in 38 of 38, so the first-frame miss is gone. Person coverage 0.19–0.23, mean 0.22. Hands 0 of 38. Pitch −10.0 / −6.0 / −2.7°, yaw −2.2 / −0.3 / +2.4°; learned straight-ahead −3.8° / −0.2°. Keyboard idle 0.0–4.0 s (keys were being pressed), pointer idle 0.3–19.4 s. States: learning 2.6 s, then facing with input 16.5 s; no phone flag. Sound: 12 windows, top label `typing_computer_keyboard` in 4 (up to 0.95) and `music` in 8 (0.23–0.72). `phone` label 0.0012–0.0059 |

What these runs establish, and what they do not:

- **The agent can run the app and read the results** without anyone pressing a button in the app. macOS permission prompts still need the developer, once per build.
- **Camera on and off** is now checked by the system flag rather than by eye: on during capture and off afterwards in both successful runs.
- **Head pitch needs the learned baseline.** Facing the screen read about −15° in one run and about −4° in the next. Around its mean it moved by roughly ±4°. The 15° “looking down” rule has margin against that, but **no run has included looking down**, so it is unknown whether real phone use crosses 15°.
- **Person coverage** was about 0.22 with someone at the Mac and below 0.05 on a blank frame. That separates those two cases only. The “face hidden” case has not occurred.
- **Sound partly agreed with the keyboard counter.** In 4 of 12 windows the top label was `typing_computer_keyboard` while keys were being pressed. In the other 8 it was `music` although key presses continued, so the top sound label is not a dependable typing sign by itself. Whether music was playing is unknown; nobody noted what was audible.
- **The `phone` label** was 0.0002–0.006 in the two self-tests, against 0.0293 with a phone held in view at 20:59. Nobody observed what was in the picture during the self-tests, so this is not a confirmed no-phone baseline.
- **Analysis cost** is from a Debug build and is not a performance measurement.

Known defects:

- The summary line reports `sound=off` even when sound ran (self-test 4: `sound=off windows=12`). The status is cleared before the summary is written; the window count and labels are correct. Left unfixed for now because any rebuild makes macOS ask for camera and microphone again. It goes in with the next code change.
- Hands were reported in 13 of 23 samples in one run and 0 of 38 in the next, with no record of where the hands were. The count's meaning is unknown.

Not run at all: looking down, turned away or absent; “Keep running when I switch apps”; Stop pressed by a person on the new window; Quit from the menu bar while running; the Release configuration.

## What still needs a person

The earlier six-step checklist was written for the two-experiment window, which no longer exists. The agent now covers start, stop, frame size, frame rate, drops and camera on/off through the self-test. What is left needs someone at the Mac. Do not save any camera image or video.

1. **Behaviour session, the most useful one.** Launch, press Start, leave “Share readings with the coding agent” ticked. Then, about ten seconds each: face the screen and type; face the screen without touching anything; look down at a phone held below the camera; look down at the keyboard while typing; turn away; leave the desk. Say roughly when each happened. The agent reads the readings with `scripts/readings.sh` and tunes the rules from them.
2. **The window.** Look at it once and report anything cut off, overlapping or confusing.
3. **Permission paths.** Decline a prompt once. The status line should say it was denied and point to System Settings, with the camera off. With only the microphone declined, everything else should still work.
4. **Lifecycle.** Lock, sleep and wake while running: the camera should stop and stay off. With “Keep running when I switch apps” ticked, switch apps and confirm it keeps running; unticked, confirm it stops.
5. **Quit while running** from the menu bar icon. If it hangs, force-quit and say so.

## Measurement procedure — pending, no values invented

Build **Release**, let the machine settle, close the preview, and keep the diagnostics window active. Start with three matched conditions: no app, capture only, then all signals. Both `scripts/selftest.sh` and `scripts/measure.sh` now accept `--release`. A full object-detector condition cannot be measured yet. Match power source, brightness, background workload and thermal conditions. Run each for at least 15 minutes after warm-up, preferably three repeats; rotate the condition order. Camera startup and warm-up are excluded from steady-state summaries but should be reported separately.

Use Instruments Time Profiler / Allocations and available power/energy tooling. The Release build keeps Xcode's debugging entitlement so that Instruments can attach to it; attaching has not been tried yet, so record it if Instruments refuses. By default the app stops on app switches, so either tick “Keep running when I switch apps” or start delayed/background collection before returning to the window. Monitoring during ordinary background work remains unmeasured. Report that limitation prominently. Do not infer watts from CPU percentage.

Record mean/peak/p95 CPU (Activity Monitor convention: 100% = one logical CPU), resident memory after warm-up and growth over time, wall-clock inference mean/p95, delivered frame rate, inference rate, skipped/dropped frames, and incremental system power where measurement is available. If watt measurements are unavailable, record battery delta plus method and confounders. The UI latency window is only the last 300 inferences, and the UI's frame averages are since Start; label those windows correctly. Analysis time covers all four Vision requests of one sample, including reading and ordering all classifier labels.

| Condition | CPU mean / p95 / peak | RSS / trend | Inference mean / p95 | Delivered fps / inference Hz / drops | Power / method |
|---|---|---|---|---|---|
| No app, matched workload | Debug pass (02:10, 2 min): whole system 40.4% of 11 cores (user 25.2, sys 15.2). **Release pass (19:50, 2 min):** whole system 29.4% of 11 cores (user 16.0, sys 13.4) | N/A | N/A | N/A | Not measured |
| Capture only, preview hidden | Debug (2 min): 20.5% / 23.5% / 24.8% (49 samples)<br>**Release (2 min):** 19.9% / 21.5% / 21.6% (48 samples) | Debug: 193 → 197 MB, peak 211 MB<br>**Release:** 196 → 196 MB, peak 197 MB | N/A | Debug: 1280×720, 29.9 fps, 0 drops<br>**Release:** 1280×720, 29.9 fps, 0 drops (3,593 frames, stop 139 ms) | Energy impact 20.6 (Debug) / **20.0 (Release)** (relative score, not watts) |
| All signals, preview hidden | Debug (2 min): 29.4% / 33.0% / 37.1% (49 samples)<br>**Release (2 min):** 24.6% / 26.6% / 27.3% (48 samples) | Debug: 370 → 405 MB, peak 410 MB<br>**Release:** 369 → 370 MB, peak 375 MB | Debug: 54.6 ms / 79.5 ms<br>**Release:** 49.8 ms / 62.8 ms | Debug: 1280×720, 29.0 fps, 0 drops, ~2 Hz<br>**Release:** 1280×720, 29.9 fps, 0 drops, 232 samples (~1.93 Hz, stop 121 ms) | Energy impact 29.4 (Debug) / **24.7 (Release)** (relative score, not watts) |
| Cleared object detector | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable |

After basic checks pass, run 60 minutes continuously and inspect growth, responsiveness, thermal behavior and release on quit. No stability duration has been completed. The product's 30 positive / 40 negative screening episodes, 12-hour false-reminder evaluation, precision/recall and behavioral thresholds belong after genuine localization and the later behavioral engine; none are claimed here.

## Gate 0 status

| Requirement | Actual status |
|---|---|
| Reproducible native app / unit target | Debug build succeeds on current code; 74 tests passed before the final sound-summary fix. Earlier build run on camera and microphone at 21:39 |
| Consent and camera lifecycle | Implemented. Seen live once on the built-in camera: prompt allowed, capture, preview, and a commanded stop in the log. In the evening two agent-run captures started and stopped with the system camera flag on during the run and off after it (stop 101 ms and 207 ms). Still pending: denied-prompt path, status text after the prompt, Stop pressed by a person on the new window, quit while running, lock/sleep |
| Bounded pipeline | Queue ownership and scheduler reviewed/tested in part. Two capture-only runs (1,240 and 205 frames) showed 0 AVF drops; two logged stops closed the camera stream 55 ms and 21 ms after `stopRunning`. 1280×720 delivery confirmed in Debug runs at 20:51 and 20:58, the second on the final code (the format is set again after `startRunning`, which resets it to 1920×1080). Classifier run: 0 AVF drops at 29 fps with inference at ~1 Hz. With four Vision requests at two samples per second: 0 drops at 29.1 fps in two runs, analysis mean 49.5 ms / p95 74.7 ms in Debug. Still pending: longer runs and measured CPU load |
| Classifier spike | One live scene (phone held visibly, Debug): `phone` 0.0293 with 14 labels higher; `consumer_electronics` 0.729. ~1 Hz, mean 19.8 ms / p95 28.6 ms in Debug. Still pending: no-phone baseline, resting phone, look-alike objects, lighting/distance variants |
| Signals and guess | One guided run (26 Nov, 01:50) by one person. Head tilt separated screen (≤ +7.7°) from phone (≥ +8.8°) in that run. The guess came on 3.1 s after the head went down and lingered 3.7 s after it came back; the lingering is now fixed but untested live. Accuracy unknown; no non-phone look-alike activities tried |
| Shared testing | Working: agent-run self-test and shared text readings. Needs the developer's Allow on the macOS prompts after each rebuild |
| Exact detector source/terms | Unresolved; no model acquired. No longer on the path being built |
| Real phone bounding boxes | Not implemented without a cleared model; coordinate mapping only tested synthetically |
| Initial CPU/memory/power | Debug (2 min, busy machine) and **Release (2 min, 19:50 PKT, AC power, preview hidden)** measured. Release: capture-only **19.9% CPU / 196 MB flat**, all signals **24.6% CPU / 370 MB flat** (analysis adds ~4.7% CPU, p95 62.8 ms, 0 drops). Capture-only exceeds the provisional 3–5% target; concrete optimization path identified below (native `420v` instead of 30 fps `32BGRA` conversion, lower hardware fps, and dropping unused requests). No watts; 15-minute and 60-minute runs still needed |
| Progression approval | Not requested; gate has not been met |

Next smallest task: run the revised guided check once more to confirm the faster clearing, then a second guided run holding the phone at eye level, then non-phone activities that also lower the head (reading paper, looking at the keyboard without typing). Do not start Milestone 1 until the developer reviews sufficient Gate 0 evidence and explicitly approves progression.

## Guided checks, 26 Nov 2026 (01:56–01:58 PKT), after the 47 s protocol

Two runs by one person, read from the app's log (`scripts/readings.sh`). One person, two runs: not an accuracy figure.

| Run | Phone phase flagged (settled) | Screen phase flagged | Screen-again flagged |
|---|---|---|---|
| 1. Phone held low, head down | 0.93 | 0.00 | 0.42 |
| 2. Phone held up, head turned 18–30° | 0.83 | 0.00 | 0.00 |

Run 1's 0.42: after the head came back up, upward tilt (−6…−9° from a baseline learned at +7.3°) counted as away and kept the guess on for about 4 s. Fix: only downward tilt counts. Estimator, guided-check and replay tests passed (30 in those classes) after the change; the live behaviour of the fix is untried, and the full suite was not rerun.

### Third run (02:03 PKT), Debug build from 02:00:51 with the downward-only tilt fix

Scored: phone phase 0.66, screen 0.00, screen-again 0.16 (overall facing-screen 0.09). The upward tilt fix held: tilts of −8.7° while facing the screen no longer counted. The new problem was that the person shifted in the chair about 3 s into the phone phase (picture share 0.22 → 0.12). After that, facing the screen read 12–17° turned against the position learned at Start, and the phone itself read 18–25°, just over the 20° threshold. The guess needed about 10 s to switch on, and the 0.16 came from turn readings of 18–24° after the cue to look back.

Change: straight-ahead is now relearned from the last 10 s of face samples taken while the keyboard or mouse is in use, counting only samples that more input followed. The guided check keeps input idle, so it cannot exercise this; it needs a run where the person types, shifts position, types again and then uses the phone. Estimator, guided-check and replay tests passed (37); untried live.

## First resource pass, 26 Nov 2026 (02:10–02:18 PKT)

`scripts/measure.sh 120` and a repeat of the capture-only condition, Debug build, preview hidden, AC power, no thermal warning. `top` sampled the app every 2 s; the first 15 s are left out. Results are in the table above. Limits:

- **Debug build, two minutes each, one repeat, a busy machine.** The no-app level was 40% of all cores, so the background load was not matched or quiet. The procedure asks for Release, 15 minutes, three repeats and rotated order.
- **No watts.** `powermetrics` needs `sudo`; top's energy-impact score followed CPU almost exactly here and adds no independent information.
- Analysis adds about **9% of one core** and about **200 MB** of memory (the Vision models) over capture alone, by subtraction of two short runs. Capture alone costs about 20% of one core at 30 fps 1280×720, which is high for delivering frames; the Debug build, the BGRA conversion and the window's once-a-second updates are suspects, none measured.
- Memory rose 35 MB over two minutes with analysis. Too short to say whether it levels off; the 60-minute run is still needed.
- **The first capture-only run is discarded.** A guided check was started from the window 22 s in. It ended the run at about 80 s with speech playing, and that run delivered **1920×1080** frames. The clean repeat delivered 1280×720. Why the first run got 1920×1080 is unknown: the capture log lines were not found in the system log store.

## Guided checks with the move step, 26 Nov 2026 (62 s protocol)

One person, read from the app's log. Scored samples exclude the first 5 s of each phase. Not an accuracy figure.

| Run | Build | Phone phase flagged | Screen | Screen-again | Straight-ahead yaw at end |
|---|---|---|---|---|---|
| 4 (02:19 PKT) | Relearning without a limit | 0.00 | 0.00 | 0.95 | +8.6° (head near +20° in the phone phase) |
| 5 (02:32 PKT) | Relearning limited to 10° from straight-ahead | 0.86 | 0.00 | 0.05 | +3.0° |

**Run 4.** Relearning dragged straight-ahead yaw from +0.9° to +8.6°. Facing the screen afterwards (yaw +20…+38°) then read as turned. Head pitch stayed within about ±2° in the phone phase, so the head rules had nothing to act on. Change: only face samples within 10° (yaw and pitch) of the current straight-ahead are used for relearning (`relearnMaxShift`). Estimator, guided-check and replay tests passed (38); the full suite was not rerun.

**Run 5**, Debug build from 02:32 with that change:
- The phone guess switched on 7 s into the phone phase. The mouse was still in use for the first 3 s, so this was about 4 s after input stopped. Head tilt was +13…+20° (down), turn below 16°, eye outline 0.45–0.71 of baseline.
- The guess cleared about 5 s after the screen-again cue. The tilt readings stayed +11…+18° until then, so the head was probably still coming up; only 1 of 19 scored screen-again samples was flagged.
- Straight-ahead yaw stayed between +3.0° and +4.6°, so the limit held. Pitch was relearned from +6.9° to −1.9° in the move step (the shift stayed within 10°). This made screen-again read "down" for about 3 s at tilt +10…+11°, which did not turn the guess on.
- **Why this run was detected and run 4 was not is uncertain.** In run 5 the head tilted clearly down (+13…+20°); in run 4 it did not move. The limit fixed the reference drift, but how the phone was held probably mattered more for detection. A phone held low with only the eyes lowered (issue #4) remains undetected.

## Release resource pass, 26 Nov 2026 (19:50–19:57 PKT)

`scripts/measure.sh 120 --release --no-build` on the Release build (`adhoc,runtime`, built 26 Nov 02:37, matching current Swift sources), preview hidden, AC power, no thermal/performance warnings, 15 s warm-up, 2 s `top` interval.

- **Capture-only (120 s):** 19.9% mean / 21.5% p95 / 21.6% peak CPU (1 logical core), **196 → 196 MB** RSS (peak 197 MB), 3,593 frames at 1280×720, 29.9 fps, 0 drops, stop 139 ms.
- **All signals (120 s, no sound):** 24.6% mean / 26.6% p95 / 27.3% peak CPU, **369 → 370 MB** RSS (peak 375 MB), 3,601 frames at 1280×720, 29.9 fps, 0 drops, 232 samples (~1.93 Hz), analysis mean **49.8 ms** / p95 **62.8 ms**, stop 121 ms.
- **Key findings vs Debug:**
  - **Memory is flat in Release:** capture-only stayed at 196 MB and all-signals stayed at 369–370 MB (no growth over 2 min, unlike Debug's 370 → 405 MB).
  - **Inference overhead is modest:** running all four Vision requests at ~2 Hz adds only **~4.7% of one logical core** over capture-only (down from ~8.9% in Debug), with p95 latency 62.8 ms (well below the 250 ms target).
  - **Capture-only dominates CPU (~19.9% of one core), exceeding the provisional 3–5% target.** Concrete optimization path from `CameraService.swift`: (1) drop the forced `kCVPixelFormatType_32BGRA` conversion on all 30 fps frames and keep native `420v` (Vision accepts `420v` directly), (2) clamp hardware frame duration to the format's lower supported rate (15 fps on the built-in camera) or 640×480 when preview is hidden, and (3) drop the unused `VNClassifyImageRequest` / `VNDetectHumanHandPoseRequest` once signals are finalized (which should also cut the ~174 MB Vision memory footprint).
- **Still unmeasured:** watts (`powermetrics`), 15-minute repeated runs, and 60-minute continuous stability.

## False-positive check (no phone), 26 Nov 2026 (21:21–21:22 PKT)

One ~59 s live run on the Release build (`preview=true`, `sounds=true`), read from `scripts/readings.sh`: 1,746 frames at 1280×720, 29.0 fps, 0 drops, 113 samples, analysis mean **50.8 ms** / p95 **66.7 ms**, stop **168 ms**.

| Phase (approximate) | Behavior | `phone_guess=yes` | What happened |
|---|---|---|---|
| `t = 3.7–18.2 s` | Looking at screen & typing (`key = 0.0–0.4 s`) | **0 s (0%)** | Clean `facing-active` (`pitch 0.0…+6.1°`, `eye_open 0.266–0.320`). |
| `t = 19.2–37.0 s` | Looking down at keyboard while typing (`key = 0.0–0.4 s`) | **0 s (0%)** | Active typing suppressed the phone guess throughout. Initially read `down-active` for `6.8 s` (`pitch +7.3…+10.8°`, `eye_open 0.112–0.173`, `eyes 0.39–0.58`). |
| `t = 38.0–57.9 s` | Looking down/aside at paper/desk without typing (`key = 1.4 → 21.3 s`) | **14.1 s** (`t = 44.3–57.9 s`) | Turned `yaw −31.0…−48.2°` (`turn 33.8–51.0°`); entered `turned-idle` at `t = 42.2 s` and flagged `phone_guess=yes` at `t = 44.3 s` (`key = 7.7 s`), clearing immediately when looking back + moving pointer at `t = 58.9 s`. |

Two concrete findings for Milestone 1:
- **Keyboard-looking drifts straight-ahead relearning:** during the keyboard phase, downward tilt (`+4…+7.5°`) stayed inside `relearnMaxShift` (`10°`) while typing, so `ActivityEstimator` relearned `straight_ahead_pitch` down to `+9.8°` and `straight_ahead_eye_open` from `~0.30` down to `0.158` (`t = 25–26.6 s`). That makes subsequent head-down postures look less tilted against the baseline. Relearning should avoid adopting downward-tilted / lowered-eye samples (e.g., gate on `eyeRatio` or tighten downward pitch shift).
- **Idle paper/desk looking triggers `phone_guess=yes`:** as expected without a phone-object detector, looking away/down at paper without keyboard/mouse input looks identical to phone use. Milestone 1 will need a realistic grace period (e.g., 45–60 s) and clear non-judgmental copy / quick-dismiss UX (or an optional phone-object detector later).
- **Sound remains noisy:** 38 windows logged `music:26, dog:4, scuba_diving:3, lion_roar:2, speech:1, thump_thud:1, underwater_bubbling:1`.

## Lifecycle check (lock & quit), 26 Nov 2026 (21:25 PKT)

Verified manually on the Release build (`FocusAssistant`, PID 82755) and cross-checked with the macOS log:
- **Lock screen (`⌃⌘Q`) & unlock:** camera stopped cleanly (`stop=117ms`, green indicator turned off and stayed off after unlock). Because background capture was not enabled in this check, the stop was triggered by window deactivation (`Window not in front — camera off`) rather than the `sessionDidResignActive` notification alone; lock-while-background-enabled remains to be tested in Milestone 1/2.
- **Quit (`⌘Q`) while active/starting:** process exited cleanly (`FocusAssistant` no longer running) and the green camera light turned off without hanging.

## Guided behavior test, 27 Nov 2026 (01:55–01:58 PKT), Debug build with the anti-ratchet relearning cap

Spoken 153 s Milestone 1 test (`Guided behavior test`), read from `scripts/readings.sh`: 4,547 frames at 1280×720, 29.5 fps, 0 drops, 294 samples, analysis mean **44.1 ms** / p95 **65.5 ms**, stop **164 ms**. Face found in 294/294 samples. Straight-ahead pitch was learned at +8.2° and relearned to +9.5° by the end of the keyboard step. The cap held: it did not move again.

**Result: fail.** Idle screen: pass. Keyboard: pass. Quick reply: info. Sustained phone: **fail** (no reminder).

| Phase | Samples | Candidate | Max evidence | Reminders | `phone_guess` (scored) |
|---|---:|---:|---:|---:|---:|
| `screen-idle` (16 s) | 30 | 0 | 0 s | 0 | 0% |
| `keyboard` (14 s) | 27 | 0 | 0 s | 0 | 0% |
| `quick-reply` (34 s) | 66 | 19 | 9.4 s | 0 | 29% |
| `return-screen` (12 s) | 23 | 17 (held over) | 12.9 s | 0 | 0% |
| `sustained-phone` (65 s) | 125 | 79 | **12.5 s** | **0** | 22% |
| `recover` (12 s) | 23 | 14 | 6.2 s | 0 | 0% |

Why the sustained step failed:
- **The head barely tilted down.** Idle samples in `sustained-phone` had tilt p25/p50/p75 = +1.8/+3.7/+5.6°. Only 5% reached the 8° `tiltDegrees` rule, and turn stayed below 12°. In the 26 Nov run 5 the same step read +13…+20°.
- Because of that, the 8 s away share hovered around 0.25–0.75, and `awayFromScreen` flipped on and off. Each stretch of about 5 s below the 0.5 share counted as a reliable return (`idleOnlyWithoutAwayPosture`) and cleared the episode. Evidence never built past 12.5 s of the 45 s grace.
- **Other signals moved, but not cleanly enough to use on their own.**
  - Compared with `screen-idle`, the face sat lower in the picture (`face_y` 0.369 → 0.22–0.25; a drop of at least 0.06 in 88% of sustained samples). But it also dropped in 43% of `return-screen` samples, because the person stayed slumped.
  - Eye outline was at or below 0.75 of baseline in 34% of samples.
  - Head roll rose from about +3.5° to about +9°.
  - `gaze_y` stayed flat again.
- No false triggers: 0 candidate samples while idle at the screen or typing.

**Follow-up (same night):** the idle-at-desk rule was added (see [decisions](decisions.md)). Replaying these 294 logged samples through the new estimator and engine (`GuidedBehaviorReplayTests`):
- gives exactly one `idleAtDesk` reminder, inside `sustained-phone`, and none in the screen, keyboard or quick-reply steps;
- the posture peak stays below 45 s;
- the replay is not a live result.

The test's sustained step is now 110 s, so a live run can check the rule without the quick reply's stretch carrying over.

Earlier open question: with only a slight head tilt, the signal-based path cannot tell this phone posture from slumping at the screen. That leaves three ways forward: combine several weak signals into one score, accept the gap, or add a phone-in-frame detector.

## Guided behavior test, live run (2026-11-27, 02:14–02:17)

- Result: idle_screen pass, keyboard pass, quick_reply info (no reminder, correct), sustained pass.
- One reminder at 105.4 s into the sustained-phone step (kind `sustainedEpisode`, 45.4 s of episode time, 2 pickups). Fired by the existing sustained rule, not the new away-from-Mac rule.
- Problem: `mac_video=on` on all 213 sustained-phone frames, and `idle_stretch=0.0s` on all of them. The Mac-video pause therefore blocked the new idle timer for the whole phone step. Needs checking: is the video detection a false positive, or is it reading something unrelated?
- Mac-video pauses also flipped the state to `observing` twice during the phone step (02:15:07, 02:16:14).
- Face brightness (`face_light`) rose to about 0.26–0.29 during phone use against a frame of about 0.60; not yet compared with the screen-facing baseline.

## Guided behavior test, live run after the video-flag fix (2026-11-27, 02:22–02:25)

- Fix under test: `MacMediaMonitor` counts only display-sleep assertions whose label looks like media playback. Confirmed beforehand with `pmset -g assertions`: Dia holds `NoDisplaySleepAssertion` "Video Wake Lock" while a video plays (matches); Codeshi holds "Electron" (ignored). Safari and Chrome labels not checked.
- `mac_video=off` on all 381 samples (no video was playing), so the away-from-Mac timer ran: `max_idle_stretch` 98.4 s with `cue_share` 0.98 in the sustained-phone step.
- Result: idle_screen pass, keyboard pass, quick_reply info (no reminder, correct), sustained pass. One reminder at 62.3 s into the sustained-phone step (kind `sustainedEpisode`, 45.3 s episode). The head tilt was clearer this time (mean +9.7°), so the posture rule fired before the 90 s away-from-Mac rule could. The idle rule's numbers show it would have fired at about 90 s.
- Quick reply: idle stretch peaked at 21.6 s, far below 90 s, so no early reminder from the new rule.
- Face brightness ratio (face / whole picture): 0.48 at the screen, 0.44 during sustained phone use. The face got slightly darker, not brighter, so phone light is not a usable signal with automatic exposure in this room. Keep logging; do not use.
- Camera: 29.4 fps, 0 drops, 49.0 ms mean / 69.8 ms p95 analysis, stop 125 ms.

## Guided behavior test, eye-level phone run (2026-11-27, 02:28–02:31)

- Purpose: check the away-from-Mac rule on its own, with the head held level and the phone at eye level.
- `mac_video=off` on all 761 samples, so the video pause did not interfere.
- Result (app's own labels): idle_screen pass, keyboard **fail**, quick_reply **fail**, sustained **fail**. Reminders: 0.
- Phone step: `max_idle_stretch` 97.3 s, but `cue_share` 0.17 and `phone_guess` 0.00. Head tilt averaged +1.5° from the straight-ahead reference, and face-lower and eyes-lowered cues were rare. The 90 s rule needs the user to look elsewhere for at least half of that stretch, so it correctly stayed quiet.
- Keyboard step: candidate fired (`away` 0.30, `max_evidence` 2.1 s), but no reminder followed. Quick reply: no candidate, `max_idle_stretch` 21.3 s.
- Conclusion: the away-from-Mac rule needs the face-cue condition as well as idle time. Phone held level at eye level with the face forward is not caught by either. This is the known gap noted in decisions.md.

### Keyboard-step "fail" in the eye-level run: grading, not detection

- The candidate (11 samples, about 5 s, `max_evidence` 2.1 s) came in the first 4–5 s of the keyboard step, before any input: the step opened while the person was still idle from step 1 (pointer idle 15–19 s).
- The head was tilted slightly up (−4…−6° against straight-ahead), but eye openness read 0.54–0.76 of straight-ahead, under the 0.75 eyes-lowered line: most likely a glance down at the keyboard after the spoken prompt. The first trackpad move cleared it and no reminder followed.
- Change: the guided grader now counts candidate/sustained samples from the first key or mouse use in a phase (`away_after_input` in the `GUIDED_BEHAVIOR` line). The keyboard step fails on any reminder, any sustained state, or any candidate after input began. A candidate only before the first input is reported as **info**. Detection rules are unchanged.
- The quick-reply "fail" in the same run was correct for that posture: phone held level, so no phone posture was seen.
