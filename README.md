# Doomore — focus signals (test build)

[![CI](https://github.com/AhmedNavaz/doomore/actions/workflows/ci.yml/badge.svg)](https://github.com/AhmedNavaz/doomore/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: macOS](https://img.shields.io/badge/platform-macOS%2014%2B-lightgray)
![Status: experimental](https://img.shields.io/badge/status-experimental-orange)

> **Early and experimental.** Everything runs on your Mac; nothing is saved or uploaded. Help wanted: see [CONTRIBUTING](CONTRIBUTING.md).

A native macOS prototype for a possible local phone-distraction assistant. It reads several signals at once and shows a guess about what the person at the Mac is doing. **The guess has not been checked for accuracy, and Gate 0 is not passed.** There are no reminders.

## What it does

Direction since the evening of 25 November 2026, decided by the developer: a phone held below the camera cannot be seen, so the app does not depend on recognising a phone in the picture. It combines these signals, all computed on this Mac:

| Signal | Source | What is read |
|---|---|---|
| Head position | Vision face request, revision 3 | Pitch, yaw and roll of the largest face, compared with a straight-ahead position learned in the first three seconds |
| Eye outline | Vision face landmarks | Eye height relative to width, compared with the straight-ahead baseline; not a gaze measurement |
| Person in the picture | Vision person segmentation, fast quality | Share of the picture marked as a person. Tells "left the desk" from "face hidden" |
| Hands in view | Vision hand-pose request | Number of hands found, at most two |
| Keyboard and pointer | System idle counters | Seconds since the last key press and the last pointer use anywhere on the Mac. No keys, clicks, positions or app names |
| Sound | System sound classifier, version 1 (303 labels) | Label names such as speech, music or typing. Optional; uses the default microphone |
| Phone label | Vision whole-image classifier | The score of the exact `phone` label. Shown as a raw number and **not** used by the guess |

Two camera frames per second are analysed. Every model is part of macOS; nothing is downloaded or bundled. See [model evidence](docs/model-evaluation.md).

### The guess

The window shows one line, for example “Head tilted or eyes lowered · no keyboard or mouse”, and how long it has lasted. The rules are in `ActivityEstimator.swift`:

| Rule | Starting value |
|---|---|
| Straight-ahead is learned from the first face samples after Start | 6 samples, about 3 s |
| Tilt or lowered eyes | Pitch changes by at least 8° in either direction, or eye openness falls to 75% of baseline |
| Turned away | Head turned at least 20° from straight-ahead |
| Face hidden | No face, but at least 5% of the picture is a person |
| Using keyboard or mouse | Any key or pointer use in the last 3 s |
| **Possible phone use** | Keyboard and pointer idle for 5 s, with tilt, turn or hidden face in at least half of the recent 8-second window; at least 4 s of samples required |
| A new state replaces the old one | After it persists for 0.4 s |

These are experimental starting values informed by a single unlabelled run and screenshots, not validated thresholds. A tilt in either direction can include looking up; a narrow eye outline can reflect blinking, glasses or head position. Idle input and looking away can equally mean reading paper, writing or eating. The app cannot tell these apart. Unit tests check the rules, not their accuracy.

## Build and launch

Prerequisites: Apple silicon Mac, Xcode with the macOS SDK. Built with Xcode 27.1 on macOS 27.0.1 / M3 Pro. Deployment target is macOS 14; execution on macOS 14 has not been validated. No package manager, downloads, model installation, server or migration is needed.

From the workspace root:

```sh
xcodebuild -project FocusAssistant.xcodeproj -scheme FocusAssistant -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
xcodebuild -project FocusAssistant.xcodeproj -scheme FocusAssistant -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData test
open build/DerivedData/Build/Products/Debug/FocusAssistant.app
```

Build outputs are ignored under `build/`. Launching does not start the camera. The app identifier is `com.local.FocusAssistant`, signed ad-hoc (**Sign to Run Locally**); no certificates or secrets are included. The source entitlements are App Sandbox, camera and microphone. Xcode adds its debugging entitlement to local builds; see [decisions](docs/decisions.md#distribution-and-privacy).

**macOS asks for the camera again after every rebuild.** The stored answer is tied to the exact build, because an ad-hoc signature has no stable identity. This was read from the system permission log on 25 November 2026, not assumed. The same applies to the microphone. Signing with one consistent development certificate would remove the repeat prompts; which certificate to use is the developer's choice and is not set.

## Use it

1. Press **Start** and answer the macOS prompts. If a prompt takes the window out of focus, that Start is cancelled on purpose: the status line reports your answer and you press Start again.
2. Look at the screen for the first three seconds. The app learns that head position as straight-ahead. **Set straight-ahead again** repeats this.
3. Watch **What the app thinks you are doing** and the **Signals** box. The first Start loads the vision models and can take several seconds.
4. **Listen for sounds (microphone)** is ticked by default. Untick it before Start to run without the microphone.
5. **Keep running when I switch apps** is off by default, so the camera stops as soon as this window is not in front. Tick it to keep monitoring while you work elsewhere. Sleep, lock, screen sleep, closing the window and serious thermal pressure always stop the camera.
6. **Stop** shows “Stopping camera…” until the camera is released. Nothing restarts by itself.

Choose the built-in camera, or explicitly select an external one. The camera must offer a native 1280×720 mode. Continuity Camera is excluded.

## Shared testing

The person using the app and a coding agent can both test it and see the same numbers.

- **Shared readings.** While **Share readings with the coding agent** is ticked (the default), the app writes one text line per second to the macOS log: the guess, the head angles, the counts, the idle times and the top labels. Print the recent ones with `scripts/readings.sh [minutes]`. So a person can look down at a phone for ten seconds, and the agent can read what the app saw, without screenshots.
- **Guided phone check.** The window button or `scripts/selftest.sh --guided` starts a 62-second check with spoken screen, move, phone and screen-again cues. In the move step the person shifts position while moving the mouse, so straight-ahead has to be relearned before the phone step; that step is logged but not scored. Phase-labelled readings and per-phase summaries make the results easier to compare; the first 5 seconds of each phase are logged but not scored, because people take time to move. The check keeps running if you switch apps and turns the camera off when it ends. The participant must actually follow the cues. The first live run used the earlier 35-second version.
- **Self-test.** `scripts/selftest.sh [seconds] [--sound] [--capture-only] [--guided] [--no-preview] [--no-build]` builds the Debug app, starts it by itself, prints the readings and a summary, and quits. The default camera run lasts 12 seconds. The app waits up to 90 seconds for a macOS permission prompt. The report is also saved to `build/selftest-last.txt`.
- **Resource measurement.** `scripts/measure.sh [seconds per condition]` runs no app, capture only and all signals one after another with the preview hidden, sampling the app with `top`: CPU mean/p95/peak, memory footprint and macOS's relative energy-impact score. It does not measure watts, which need `sudo powermetrics`. It uses the Debug build. Results go to `build/measure-last.txt`.
- **Camera on or off.** The self-test reports whether any camera on the Mac was switched on before, during and after the run, read from a system status flag by `scripts/camera-in-use.swift`. This stands in for looking at the camera light.

Lines hold numbers and label names only: no pictures, audio, key presses or app names. They live in the macOS log (subsystem `com.local.FocusAssistant`, category `shared`) and age out with it.

## Privacy and implementation

- No frames, audio, screenshots or landmarks are saved or uploaded. No network APIs, analytics SDKs, screen recording, accessibility or Input Monitoring permissions are used. The idle counters need no permission.
- Camera setup, callbacks and analysis run on one serial queue. Late frames are discarded; no per-frame tasks or unbounded queues are created. Pixel buffers are borrowed only during the callback, and only copied numbers and labels reach the main actor.
- Sound runs separately from the camera with `AVAudioEngine` and the system sound classifier on its own queue. Audio buffers are analysed in memory. A missing or refused microphone turns sound off; it never blocks Start.
- `PhoneDetector` and the overlay mapping remain for a possible future object detector. The app does not activate them and draws no boxes.

## What has and has not been checked

On 25 November 2026, 74 unit tests passed before the final sound-summary change; the final Debug sources build. Earlier agent-run self-tests exercised the camera and microphone, before the guided check and eye-landmark changes.

On 26 November 2026 one guided check ran live (see results). The estimator, guided-check and replay tests then passed (34 tests) and the Debug app compiled; the full suite was not rerun.

Not checked: the revised guided check and faster clearing on live input, accuracy of the guess, the window's updated layout, CPU, memory and power, and lock and sleep behaviour. Details and exact numbers are in [results](docs/poc-results.md).

## Evidence and next step

- [Actual results and what is still open](docs/poc-results.md)
- [Architecture and decisions](docs/decisions.md)
- [Models used and licensing research](docs/model-evaluation.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

The next evidence is a run of the revised guided check, one with the phone held at eye level, and non-phone activities that also lower the head, to measure false positives and misses.

## Contributing, license and security

- [Contributing](CONTRIBUTING.md) · [Code of Conduct](CODE_OF_CONDUCT.md) · [Security and privacy](SECURITY.md)
- Released under the [MIT License](LICENSE).
