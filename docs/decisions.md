# Decisions — Milestone 0 & Milestone 1

25–26 November 2026. Scope: the supplied Behavioral Focus Assistant specification. Milestone 0 Gate 0 was approved by the developer on 26 November 2026 on the signal-based path; Milestone 1 (behavioral engine) is now in progress.

## Direction change — 25 November 2026, evening

The developer redirected the work in the shared conversation: a phone in use is usually below the camera's view, so the app must read “everything”, meaning the person's activity, head position and sounds, and the developer and the agent must be able to test it together. The first live classifier scene pointed the same way: with a phone held in plain view, the whole-image `phone` label scored 0.0293 ([results](poc-results.md)). This overrides the Milestone 0 plan to wait for a licensed phone-object detector before reading any behaviour. It was the developer's decision.

What changed as a result:

- **Signals instead of a phone detector.** Head angles (Vision face request, revision 3), person coverage (Vision person segmentation), hand count (Vision hand pose), keyboard and pointer idle seconds (system idle counters), and optional sound labels (system sound classifier). All are operating-system facilities, so the unresolved third-party model terms do not block this path. The classifier's `phone` score is still shown but not used.
- **A rule-based guess.** `ActivityEstimator` turns the samples into one state. It flags “possible phone use” when the head is down, or the face is hidden while a person is in view, with no keyboard or pointer use for five seconds. Every threshold is a starting value chosen without measurement. The guess is displayed only; nothing reminds or records.
- **Head angles are relative.** Straight-ahead is the median of the first six face samples after Start. The first live run reported about −15° pitch while the developer faced the screen, so an absolute threshold would have been wrong by that much on this Mac.
- **Presence comes from person segmentation.** The upper-body detector (`VNDetectHumanRectanglesRequest`, revision 2, upper body only) found nobody in 23 of 23 live samples while a face was found in 22. It was replaced before anything relied on it. Person coverage has run on a blank frame only, not on the camera.
- **Two analysed frames per second**, up from one, so that a state can be confirmed by two samples within a second. Each analysed frame is published to the UI once; counters alone are still published at most twice per second.
- **Models load before the camera starts.** The first analysis in a process took about six seconds in the unit-test host. Inside a frame callback that would trip the five-second stale-frame watchdog, so Start analyses one blank frame first, and the watchdog now measures from the end of each callback. The first 15 delivered frames are not analysed: the first frame of the first live run showed no face and unrelated labels.
- **Sound is separate from the camera session.** `AVAudioEngine` on the default input feeds the system classifier on its own queue. The camera session's format handling was fragile on this Mac, so no audio input was added to it. Known limit: the default input device is used, so a Bluetooth headset selected as input would be switched to its call mode. Choosing the built-in microphone explicitly is not implemented. This whole path has not run with a microphone yet.
- **Shared testing.** Text readings go to the macOS log while a visible checkbox is ticked (default on), and the `--selftest` launch argument runs the app unattended. Both exist because an agent cannot press buttons in the app (macOS assistive access) and should not need screenshots of the developer's camera image. The log was chosen over a file because the app is sandboxed.
- **Foreground-only is a default, not a rule.** A visible checkbox keeps the camera running across app switches, hiding and minimizing, because keyboard and pointer activity cannot be judged while the person must keep this window in front. Sleep, lock, screen sleep, window close and thermal pressure still stop it. A self-test sets the option itself.
- **Quitting.** When the camera is already off, the app quits at once. `terminate` called from a main-queue block runs a nested run loop that does not drain the main queue, so the asynchronous shutdown reply never arrived and the first two self-tests had to be closed by the script.

## Workspace and toolchain

Initial `git status --short --branch` / `git rev-parse --show-toplevel` reported no Git repository; directory inspection found an empty workspace. There was no existing project or Codeshi source to modify. No Git history, commit, remote, or publication was created. No repository instruction files were found in the workspace or checked ancestor paths.

Observed environment: macOS 27.0.1 (26A434), arm64, Apple M3 Pro, 18 GB RAM; Xcode 27.1 (27A9275), Swift 6.4 compiler, macOS 27.0 SDK. Personal hardware identifiers are deliberately excluded from these records.

Created a standalone Xcode application and hosted XCTest target. `com.local.FocusAssistant` is temporary and local. Apple silicon only (`ARCHS=arm64`); minimum macOS 14 is retained. Swift 5 language mode uses the established AVFoundation delegate/serial-queue pattern. There are no unchecked Sendable declarations in production code. Migrating to Swift 6's full isolation checking requires a separate reviewed ownership design, not suppressing buffer errors.

## Local SDK and primary documentation check

Checked headers under `$(xcrun --show-sdk-path)/System/Library/Frameworks` before adopting APIs, and the linked Apple documentation:

| API / decision | Compatibility evidence |
|---|---|
| Camera permission, capture session/input/output | Public AVFoundation APIs predate macOS 14; [consent documentation](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media) and [capture output](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput) inspected |
| Built-in and external discovery; exclude `isContinuityCamera` | `.external` introduced macOS 14; Continuity query macOS 13. We do not use the system-preferred camera because it may select a phone |
| Runtime/interruption notifications | Local session header permits macOS; `AVCaptureSession.isInterrupted` is unavailable on macOS and is not used |
| Vision request revision 2 / supported identifiers | macOS 14 / macOS 12 respectively; pinned revision and runtime labels, [classifier docs](https://developer.apple.com/documentation/vision/vnclassifyimagerequest) |
| Core ML object observations | Header and [live capture example](https://developer.apple.com/documentation/vision/recognizing-objects-in-live-capture) distinguish actual model outputs; no tensor/observation schema invented |
| Preview connection control | SDK `AVCaptureVideoPreviewLayer.h` and `AVCaptureSession.h`: session-backed layer setters implicitly form connections; use `sessionWithNoConnection` and worker-queue explicit connection instead. Observed on macOS 27 with the built-in camera: AVFoundation rejected the explicit connection (“source and destination media types are incompatible”) in four starts where it was added inside the configuration block that adds the input, and accepted it in the one start made after it was moved to follow the commit ([results](poc-results.md)) |
| Head angles | `VNObservation.h`: pitch is in radians and “positive angle corresponds to nodding head down direction”, macOS 12. Yaw and roll are positive counterclockwise. Which side positive yaw is on screen was not checked. Face request revision 3 is macOS 12 |
| Person segmentation, hand pose | `VNGeneratePersonSegmentationRequest` macOS 12, `VNDetectHumanHandPoseRequest` macOS 11, per the local headers |
| Sound classifier | `SNClassifySoundRequest(classifierIdentifier: .version1)`, macOS 12. Queried without a microphone: 303 labels, 3 s window, 0.5 overlap. `SNAnalyzer.h` says analysis may block and may be called from an `AVAudioEngine` tap callback but not a realtime context |
| Keyboard and pointer idle time | `CGEventSource.secondsSinceLastEventType`. Inside the sandboxed test host it returned keyboard 313.2 s and pointer 8.4 s; an unsandboxed script about one second later returned 314.3 s and 9.5 s. So the sandbox does not block it, and it needs no permission. The persistent lines of the system permission log show the same checks for old and new builds at launch (WindowServer and coreaudiod asking about this app), so reading the counters added none |
| Foreground application ID | `NSWorkspace.shared.frontmostApplication` and `NSWorkspace.didActivateApplicationNotification` (public AppKit API predating macOS 14; reads bundle identifier and display name only, no window titles or contents, no extra permission) |
| Sleep/session/display notifications | Public NSWorkspace header. Prototype additionally stops on diagnostics deactivation; lock and quit verified on hardware on 26 November 2026 (lock with background capture ticked remains to be verified) |

Successful compile at deployment target 14 checks symbol availability but is not execution evidence on macOS 14. The installed SDK is used without silently raising the target. No external model's deployment compatibility can be claimed because none is included.

## Model boundary

No exact downloadable detector artifact met the source/terms evidence requirement during the bounded research spike. Follow the specification's camera-only fallback, with a separately labeled Vision classification experiment. No model download, conversion, training, cloud inference, Python tooling, or copied upstream implementation was introduced. See [model evaluation](model-evaluation.md).

The app's object-detection UI is explicitly unavailable. An overlay mapping implementation and detector contract are tested in isolation; they are not evidence of working live localization. Classifier top labels are never turned into bounding boxes or distraction judgments.

The Signals box shows the score of the exact `phone` identifier for every sample, with the number of labels scoring above it and the top three labels. Top five alone would hide the one value this spike exists to observe: on synthetic frames the request returned all 1,303 labels and `phone` sat hundreds of places down (see [model evaluation](model-evaluation.md)). A count of higher-scoring labels is shown instead of a rank because many labels can tie at zero, as they did on those frames. Ordering and the exact-identifier match are done in `ClassifierReading.summarize` and unit-tested, not assumed from the order Vision returns. This is still a whole-image score; it is not a detector and is not wired to `PhoneDetector`.

## Pipeline and lifecycle

One queue owns session mutation, preview connection mutation, callback processing, and inference. The preview layer is allocated before capture and has no automatic connection. Its connection is added explicitly on that queue after the input/output configuration is committed, because adding it inside the same configuration block was rejected on the test Mac. The preview is optional: if no connection can be made, capture continues and the status line says the preview is unavailable. That degraded path ran once on hardware (1,240 frames without a preview). A fallback that reassigned the layer's session so that AVFoundation formed the connection itself was added and never ran; it was removed on 25 November 2026 because it departed from the explicit-connection rule in the table above. Main-thread view operations alter only layer hierarchy/layout. MainActor owns UI state. No pixel buffer is dispatched across either boundary.

Serial synchronous inference plus AVFoundation late-frame discard permits at most one inference at a time. The tested monotonic schedule admits at most one sample per half second without catch-up (one per second until the direction change above). Per-frame data is not stored; only counters and at most 300 latency numbers remain in memory. Each analysed frame is published to the UI once, and counters alone at most twice per second; this is not a frame queue.

Requested-run identity uses a small lock-protected command token; actual capture state stays queue-confined. Stop invalidates pending startup immediately. Checks before/after blocking setup/start suppress cancelled runs; stop executes after any in-flight system call/inference. Stop status remains visible until teardown returns.

Teardown therefore runs on the same queue that delivers sample callbacks, though never from inside a callback. On hardware (26 November 2026 Release checks), stop took 117–168 ms with no hang on Stop, lock, or Quit.

Start is explicit, permission is requested only there, and callbacks carry a generation token. If the system permission prompt deactivates the window, that request is cancelled like any other deactivation. The answer is then reported in the status line and capture still needs another explicit Start; a granted answer never starts the camera on behalf of a cancelled request. Permission denial, disconnection, runtime interruption, revoked authorization, suspension, >5 seconds without frames, session inactivity, and thermal pressure stop or refuse capture. There is no automatic recovery loop; user-driven retry bounds recovery and prevents repeated camera reopening. A busy-camera property is only a hint; meeting compatibility remains unverified.

By default the window must remain active: hide/minimize/close/app switch cancels pending or running capture, and wake never automatically resumes. A visible checkbox lifts this for app switches, hiding and minimizing (see the direction change above). Background-workload power behavior has not been measured. Built-in camera auto-selection is allowed; external selection is explicit; Continuity Camera is excluded.

**Frame size: 1280×720, the developer's decision on 25 November 2026**, chosen over 1920×1080 (most detail, most processing) and 640×480 (least processing, 4:3, smallest phone). Capture requests the `hd1280x720` session preset, selects the exact native 1280×720 `activeFormat` preferring `420v`, and re-applies 1280×720 after `startRunning` if macOS resets it to 1920×1080. Capture does not stretch frames or change hardware frame duration.

## Distribution and privacy

The source entitlements file requests App Sandbox, camera and microphone (`com.apple.security.device.audio-input`, added with the sound signal); no networking entitlement. Local ad-hoc development signing requires no private identity. The designated requirement of an ad-hoc build is the code hash of that exact build, so camera consent does not carry over to a rebuilt app.

`com.apple.security.get-task-allow` is the debugging entitlement Xcode injects into locally built products. It is not in the source file. A distributed build should not carry a debugging entitlement; archive/export signing belongs to Milestone 3.

No app-created files. No images, audio, coordinates, key presses or app IDs are logged. While “Share readings with the coding agent” is ticked (default on), text readings are written to the macOS log about once a second for shared testing: the guess, angles, counts, idle seconds, behavior state/reason codes, and label names. Frontmost app names and bundle identifiers are kept in memory only and never logged. No history, accounts, real OS notifications, subscriptions, updater or Codeshi integration yet.

## Gate 0 status — Approved (26 November 2026)

On 26 November 2026, after reviewing the Release benchmark (`196 MB` capture-only / `369–370 MB` all signals flat memory, `62.8 ms` p95 analysis latency), guided positive run (`86%` phone vs `0–5%` screen), negative no-phone check (`0%` false flags while typing on screen or keyboard), and lock/quit camera release checks ([results](poc-results.md)), the developer **approved Gate 0 on the signal-based path** and chose to proceed directly to **Milestone 1 (Behavioral Engine)**.

Known items carried forward into Milestones 1–2 (not yet measured or optimized):
- Capture-only CPU is `19.9%` of one core in Release (above the provisional `3–5%` target); concrete optimization path identified (`420v` native output instead of forced `32BGRA`, 15 fps hardware frame rate, drop unused `VNClassifyImageRequest` / `VNDetectHumanHandPoseRequest`).
- Watts (`powermetrics`), 60-minute continuous stability, screen lock with background capture ticked, and live meeting-app conflicts (Zoom/FaceTime) remain to be measured before Gate 2.

## Milestone 1 — Behavioral engine decisions (26 November 2026)

- **Baseline relearning drift fix (`ActivityEstimator`):** The 26 November 2026 negative check showed looking down at the keyboard (`+4…+7.5°` pitch, lowered eyes) while typing drifted straight-ahead pitch to `+9.8°` and eye openness from `~0.30` to `0.158`. Relearning now requires downward pitch change `≤ 5.0°` (`relearnMaxDownwardPitch`) and eye openness `≥ 80%` of baseline (`relearnMinEyeRatio`), while preserving horizontal yaw and upward pitch adaptation for normal chair shifts.
- **Pure temporal state machine (`BehaviorEngine` + `InterventionPolicy` + `MonotonicClock`):** Implements `disabled`, `unavailable`, `paused`, `observing`, `candidate`, `sustainedPhoneUse`, and `cooldown` as pure value types with interpretable reason codes (`BehaviorReason`) and no OS dependencies.
  - Candidate activation requires 3 of 5 valid positive samples spanning ≥2 s, where positive requires **both** away posture and ≥10 s input idle (idle alone never activates or alerts).
  - Dropout/stale safety: missing frames or non-positive samples never add positive duration; steps above `maxStepSeconds` (1.5 s) add zero duration; gaps or unknown quality exceeding 5 s reset any active candidate; out-of-order timestamps are ignored.
  - Multiple-people suppression: `faceCount > 1` maps to `.multiplePeople`, immediately clearing active candidates.
- **Time dynamics for quick replies, MFA, and headphones (spec §13.2):**
  - Episode grace period is `45 s` of corroborated away+idle duration (separate from Milestone 0's 5 s diagnostic `possiblePhoneUse` flag), absorbing short messages, MFA, and music skips even when wearing AirPods/headphones.
  - Rolling short-pickup counter tracks completed unnotified away episodes of `≥ 15 s` within a `12-minute` rolling window; reaching `4` pickups emits a `.repeatedShortPickups` intervention and resets the counter.
- **Foreground app & work context (`WorkContext` + `ForegroundAppMonitor`):** Observes `NSWorkspace.shared.frontmostApplication` bundle ID only (never logged). Supports `.manualWork`, `.selectedApps` (configured coding/writing bundle IDs; arbitrary browsers and terminals excluded by default), and `.inactive`. Known meeting apps (Zoom, FaceTime, Teams, Webex) suppress reminders even in `.manualWork`.
- **Milestone 1 UI boundary:** `DiagnosticsView` displays engine state, reason codes, grace progress, rolling pickup count, a work-context mode picker, pause toggle, and an in-window dry-run reminder banner (`Back to work`, `Taking a break (5 min)` which releases the camera, and `Quick reply / Not a distraction`). Real `UNUserNotificationCenter` delivery and menu-bar settings UI remain scoped to Milestone 2.

## Milestone 1 — Idle-at-desk rule and extra signals (27 November 2026)

The guided behavior test of 27 Nov 2026 failed ([results](poc-results.md)): the phone was held high and the head tilted only about 4°. The posture episode kept restarting and peaked at 12.5 s of the 45 s grace. The developer asked for more than head tilt, including the idea of simply noticing that the Mac has not been used for a while, and left the design to the agent. Decisions:

- **Idle-at-desk rule (`BehaviorEngine`, new reminder kind `idleAtDesk`).**
  - The rule measures one stretch without keyboard or mouse while a single person is at the desk. The stretch starts once input has been idle for 10 s.
  - It also measures the share of that stretch showing any sign of looking elsewhere: strong posture (down, turned or hidden) or a soft cue.
  - It reminds once per stretch, on a sample that itself shows a cue:
    - after **90 s** if the share is at least **50%**;
    - after **300 s** if the share is at least **25%**.
  - Any keyboard or mouse input ends the stretch. So do no person, several people, calibration, stale evidence and the hard gates. Acknowledging a reminder also ends it, and the existing cooldown and suppress-until-return policy still applies.
- **Pure idle (staring at the screen with no cue) still never reminds**, however long it lasts. The developer watches builds and AI agents work without touching the Mac, so a plain "no input for N minutes" reminder would fire during normal work. This keeps spec §5.1 ("idle alone never alerts") in force.
- **Soft cues (`ActivityEstimator`).** A soft cue is either:
  - a downward tilt of 4–8° (`softTiltDegrees`);
  - the face centre 0.06 of picture height lower than straight-ahead (`faceDropShare`). Straight-ahead face height is now learned and relearned along with pitch, yaw and eye openness.

  Soft cues never open a posture episode on their own.
- **Video on this Mac holds the stretch (`MacMediaMonitor`).** Another process holding a display-sleep assertion (browsers and players do while video plays) pauses accumulation. Only assertions whose label looks like media playback count ("video", "media", "play", "movie", "wake lock"). The first version counted any display-sleep assertion, and Electron apps (Codeshi, Slack, VS Code) hold one labelled "Electron" for as long as they run, so the live run of 2026-11-27 read `mac_video=on` on every frame. The label is matched in memory and never stored or logged; app names, window titles and URLs are never read.
- **Measured but not used yet:**
  - Phone light on the face: face-box brightness compared with whole-picture brightness. Automatic exposure may hide it.
  - Mac audio output running: lets a later rule tell sound coming from the phone (heard by the microphone while the Mac is silent) from the Mac's own audio. It is coarse: it is also on during this app's spoken cues and with a headset.

  Both are logged as `face_light`/`frame_light` and `mac_video`/`mac_audio`, so the next runs show whether they separate phone use from screen use.
- **Rejected for now:** sound-only detection (doom-scrolling audio). In the 27 Nov run the classifier heard music and speech in every phase, including idle at the screen. With headphones there is nothing to hear.
- **Guided behavior test:** the sustained step is now 110 s (total 198 s), so the 10 s + 90 s rule fits inside it. Step 4 asks for a touch of the mouse, as a real return to work would, so the quick reply's stretch does not carry over.
- **Relearning cap correction:** the earlier bullet's 5.0° downward relearn limit is now 2.5° above the pitch calibrated at Start (`relearnMaxDownwardPitch`), after keyboard glances ratcheted the reference in the 26–27 Nov runs.
- **Phone-in-picture detector: not pursued (27 Nov).** With the Mac camera the phone and hands are normally outside the frame (0 hands seen in 211 samples of the eye-level phone step), so no detector could find them. A phone held level at eye level with the head straight remains an accepted gap, caught only by the cues above (tilt, turn, slump, soft cues).

## Gate 1 status

**Not passed yet.** Automated deterministic fake-clock tests cover the engine rules, but scripted live episode evaluation and confusion-matrix measurement (spec §8 Milestone 1) have not been run yet.

The developer chose on 27 Nov 2026 to move on to Milestone 2 without the scripted confusion-matrix evaluation, accepting the eye-level-phone gap above. Gate 1 stays formally open until that evaluation is run.

## Milestone 2 — Personal alpha, first increment (27 November 2026)

- **Monitoring runs from the menu bar.** `Start monitoring` is an explicit opt-in and is off at every launch. While monitoring, the camera keeps running with the diagnostics window closed or behind other apps. It never opens the microphone (spec §1.3, §13.1), and the camera preview is drawn only while the window is open. The window's own Start/Stop and its "camera only while in front" default are unchanged when monitoring is off.
- **Menu bar icon:** off `eye.slash`, starting `eye`, monitoring `eye.fill`, paused or on break `pause.circle`, unavailable `exclamationmark.triangle` (`MonitoringStatus`, pure and unit-tested). Status text never claims phone use.
- **Which stops keep monitoring alive:** pause (camera off until Resume), a break (camera off, restarts by itself when the break ends), and lock, sleep or screen sleep (restarts 2 s after wake, only if camera permission is already granted; it never prompts on its own). Any other stop ends monitoring and shows why in the menu, with no retry loop: permission refused, camera failure, thermal pressure. Screen wake was added as a resume trigger because a display that slept without a lock posted neither of the existing wake notifications.
- **Real local notifications (`ReminderNotifier`)** carry the three actions `Back to work`, `Taking a break (5 min)` and `Quick reply / Not a distraction`, mapped to the existing engine actions. Opening or dismissing a notification is not feedback. Permission is asked the first time monitoring starts, never at launch. A refusal shows in the menu with a link to System Settings, without repeated prompts (spec §5.3). The in-window banner remains.
- **Notification sound on.** The person is most likely looking at their phone, so a silent banner on the Mac would go unseen.
- **Work-context mode is remembered** between launches (`UserDefaults`, key `workContextMode`). The default stays manual work mode.
- **Second increment (27 Nov 2026):** first-launch welcome sheet (shown once), a Settings window (menu bar → Settings…), an editable work-app list (bundle IDs only, remembered, add from running apps or a file picker, reset to defaults), a Relaxed / Balanced / Sensitive setting, and opt-in open at login through `SMAppService`. Balanced equals the tested default rules; Relaxed and Sensitive only scale grace, cooldown, pickup count and idle-stretch timings, so the signals and the "unknown evidence never reminds" rules are unchanged. Guided checks always run on Balanced. Monitoring still never starts by itself at login.
- **Still to do in Milestone 2:** the Gate 2 personal-use checks.

### Reminder delivery for testing (27 November 2026)

- Reminders can show a full-screen warning on every display with a looping sound until answered (Settings → Reminder style; default on while testing). Guided checks never show it.
- **Quick test** sensitivity: 5 s idle corroboration, 8 s grace, 30 s cooldown, and a plain idle tier (`idleStretchPlainSeconds = 25`) that reminds after about 30 s at the desk without keyboard or mouse whatever the head does. It exists because live runs with the phone at eye level kept the face straight on (the accepted gap) and never fired. Relaxed, Balanced and Sensitive keep the plain tier off.
