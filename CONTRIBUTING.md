# Contributing to Doomore

Thanks for helping. Doomore is an early, experimental macOS prototype, so the most useful contributions are **evidence** (does the guess work for you?) and **small, tested changes**.

## Ways to help

- **Run the guided phone check** (`scripts/selftest.sh --guided`) and open a "Test result" issue with the per-phase summary. Include your Mac model, macOS version and camera. Never attach pictures or audio.
- Report false positives (flagged while reading paper, eating, and so on) and misses.
- Improve the estimator rules in `FocusAssistant/Detection/ActivityEstimator.swift`, with tests.
- Check behaviour on macOS 14 and on Intel Macs, neither of which has been validated.

## Setup

Requirements: Apple silicon Mac, Xcode with the macOS SDK. No package manager or downloads.

```sh
xcodebuild -project FocusAssistant.xcodeproj -scheme FocusAssistant -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData test
```

## Pull requests

1. Open an issue first for anything larger than a small fix.
2. Keep changes focused and add or update tests in `FocusAssistantTests`.
3. Run the test command above and say in the PR what you did and did not verify.
4. Do not add network calls, analytics, or saving of frames, audio, keystrokes or app names. Privacy is a design rule; see `docs/decisions.md`.
5. Do not add third-party models or code without updating `THIRD_PARTY_NOTICES.md` with the exact source and license.
6. Do not commit signing certificates, team IDs or secrets.

By contributing you agree your work is released under the [MIT License](LICENSE). Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).
