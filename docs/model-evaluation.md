# Model evaluation — Milestone 0

Checked on 25 November 2026. This is an engineering evidence record, not a declaration of commercial licensing clearance or measured detection accuracy.

## Decision

No downloaded object detector is cleared for this increment. Do not acquire or bundle model weights based on the evidence below. Continue with camera capture and a clearly labeled, local Apple Vision **whole-image classification experiment**. This experiment cannot draw genuine phone bounding boxes or distinguish a held phone from one resting on a desk. Gate 0 remains open.

The required bounded research spike did not establish the exact evaluation and redistribution terms for Apple's `YOLOv3TinyFP16.mlmodel`. This is an unresolved provenance/rights question, not a claim that its use is prohibited. A source-code license, model-family name, or another variant's license metadata is insufficient evidence for this artifact.

## Operating-system models used since the evening direction change

On the evening of 25 November 2026 the developer redirected the work from recognising a phone to reading several signals ([decisions](decisions.md#direction-change--25-november-2026-evening)). The app now calls these macOS facilities through their public APIs. Like the classifier below, their weights ship with the operating system: nothing is downloaded, copied into this repository or redistributed by the app, and no third-party model terms are involved.

| Facility | API and revision | What was actually observed |
|---|---|---|
| Face with head angles | `VNDetectFaceRectanglesRequest`, revision 3 | Ran in the sandboxed test host on a blank frame (no face). On the camera: a face in 22 of 23 and 38 of 38 samples, with pitch, yaw and roll reported |
| Person segmentation | `VNGeneratePersonSegmentationRequest`, fast quality, 8-bit mask | Blank frame: coverage below 0.05. On the camera: 0.19–0.23 with a person at the Mac |
| Hand pose | `VNDetectHumanHandPoseRequest`, at most two hands | Blank frame: no hands. On the camera: hands in 13 of 23 samples in one run and 0 of 38 in another, with no record of where the hands were |
| Whole-image classifier | `VNClassifyImageRequest`, revision 2 | See the next section |
| Sound classifier | `SNClassifySoundRequest`, classifier identifier `version1` | Queried without a microphone: 303 labels, 3 s window, 0.5 overlap. Labels include `speech`, `music`, `typing`, `typing_computer_keyboard`, `ringtone`, `telephone`, `silence`. On the microphone: 12 windows in one 20 s run, top labels `typing_computer_keyboard` and `music` |
| Upper-body detector | `VNDetectHumanRectanglesRequest`, revision 2, upper body only | Tried and removed: 0 of 23 live samples while a face was found in 22 |

None of these locates a phone, and none of the numbers above is an accuracy measurement. The first analysis in a process took 5.9 s in the test host (model loading); later ones took tens of milliseconds. Live observations are in [results](poc-results.md#evening-session-signals-and-shared-testing).

## Baseline A: installed Vision classifier — actually queried

Environment: macOS 27.0.1 (26A434), arm64; Xcode 27.1 (27A9275). No camera access, image collection, network inference, or third-party model download was involved in this query.

Executed successfully (exit 0):

```sh
xcrun swift -module-cache-path /tmp/focusassistant-research-module-cache -e 'import Foundation; import Vision; let request = VNClassifyImageRequest(); request.revision = VNClassifyImageRequestRevision2; do { let labels = try request.supportedIdentifiers(); print("revision=\(request.revision) count=\(labels.count)"); print(labels.filter { $0.localizedCaseInsensitiveContains("phone") || $0.localizedCaseInsensitiveContains("mobile") || $0.localizedCaseInsensitiveContains("cellular") }.joined(separator: "\n")) } catch { print("error=\(error)"); exit(1) }'
```

Actual output:

```text
revision=2 count=1303
automobile
headphones
megaphone
microphone
payphone
phone
saxophone
snowmobile
xylophone
```

`phone` is a real supported identifier for revision 2 on this machine. Substring matches are exploratory results, not interchangeable phone classes; `headphones`, `microphone`, `saxophone`, and the other incidental matches must not be treated as phones. `payphone` is not evidence of a handheld mobile device. Validate the exact `phone` identifier at runtime before presenting that classifier result. The app does this: it matches the identifier exactly and shows “not reported by this classifier” when it is absent.

This establishes label availability only. A label inventory is not an inference result or an accuracy benchmark. Whether a small, partially occluded phone is classified in typical laptop-camera frames remains untested. A low classifier score cannot establish absence of a phone. A high score cannot establish its location, handheld use, distraction, or intent. Do not synthesize a bounding box from a classification.

API checks used both [Apple's `VNClassifyImageRequest` documentation](https://developer.apple.com/documentation/vision/vnclassifyimagerequest) and [`supportedIdentifiers()` documentation](https://developer.apple.com/documentation/vision/vnclassifyimagerequest/supportedidentifiers()). The local SDK headers confirm:

| Symbol | Earliest macOS in local header |
|---|---|
| `VNClassifyImageRequest` | 10.15 |
| `supportedIdentifiersAndReturnError:` / Swift `supportedIdentifiers()` | 12.0 |
| `VNClassifyImageRequestRevision2` | 14.0 |
| `VNCoreMLModel`, `VNCoreMLRequest` | 10.13 |

Header locations, relative to the `xcrun --show-sdk-path` result:

```text
System/Library/Frameworks/Vision.framework/Headers/VNClassifyImageRequest.h
System/Library/Frameworks/Vision.framework/Headers/VNCoreMLRequest.h
```

These APIs fit the macOS 14 deployment baseline. Compilation against the installed SDK does not prove behavior on a physical macOS 14 machine. The system supplies the classifier; there is no separately redistributed weight artifact, pinned model checksum, or claim that Apple's internal weights remain identical across OS releases. Record OS build and explicit request revision with future results.

### Result structure on synthetic frames — actually queried

To decide what the diagnostics window should show, a throwaway Swift program ran the same revision-2 request through `VNImageRequestHandler(cvPixelBuffer:orientation:)` on three synthetic 32BGRA buffers: flat gray 640×480, a colour gradient 640×480, and a checkerboard 1280×720. The program was compiled for macOS 14, run once, and not kept in the repository. No camera, real image, or network access was involved. Actual output:

```text
revision=2 supportedIdentifiers=1303
flat-gray: results=1303 uniqueIdentifiers=1303 descending=true nonFinite=0 min=0.0 max=0.08915672 sum=0.80334824
   phone: index=369 confidence=0.00024414062
   first five as returned: outdoor=0.08915672, sky=0.08740252, night_sky=0.087402344, celestial_body=0.046875436, moon=0.046875
gradient: results=1303 uniqueIdentifiers=1303 descending=true nonFinite=0 min=0.0 max=0.03344731 sum=0.2843267
   phone: index=904 confidence=0.0
   first five as returned: document=0.03344731, sticky_note=0.033447266, outdoor=0.010394282, sky=0.010389061, material=0.01033767
checker: results=1303 uniqueIdentifiers=1303 descending=true nonFinite=0 min=0.0 max=0.44116366 sum=0.6339839
   phone: index=886 confidence=0.0
   first five as returned: material=0.44116366, textile=0.02734375, art=0.010498335, decoration=0.010498075, polka_dots=0.010498047
```

For this OS build and these three inputs only: every sample carried all 1,303 labels, including `phone`. Scores were finite, lay between 0 and 1, and were per-label values that did not sum to one. The returned order was descending by score. `phone` sat at zero-based positions 369, 904 and 886, the last two tied at zero with many other labels, so a top-five view would never have shown it.

The app therefore reads the exact `phone` score from every sample, reports how many labels score above it, and does its own ordering instead of relying on the returned order. None of this is accuracy evidence. The synthetic frames contain no phone, and these scores say nothing about real scenes.

## Baseline A: Apple-hosted YOLOv3Tiny FP16 — not acquired

Evidence inspected:

- [Apple Core ML model gallery](https://developer.apple.com/machine-learning/models/) lists `YOLOv3TinyFP16.mlmodel` at 17.7 MB and links its download to Apple's `ml-assets.apple.com` host. The research tool exposed the link label and host, but the complete artifact URL was not observed or followed; no guessed download URL is recorded. The gallery's linked original source is [`pjreddie/darknet`](https://github.com/pjreddie/darknet), not the Ultralytics implementation.
- The gallery text available to this investigation did not state a license applicable to this exact Tiny FP16 artifact. Attempts to read likely companion license documents did not yield an accessible authoritative license. Local `curl` could not resolve `developer.apple.com` in the tool sandbox. A computer-use attempt to open the gallery in an in-app browser returned “The browser access host is unavailable”; no interactive page was opened. These specific access failures do not establish that a license does not exist.
- [Darknet's upstream LICENSE](https://github.com/pjreddie/darknet/blob/master/LICENSE) contains a public-domain dedication for Darknet. That source license does not itself identify the rights in Apple's converted weights or their training data.
- [Apple's `coreml-YOLOv3` model card](https://huggingface.co/apple/coreml-YOLOv3/blob/main/README.md) declares MIT metadata. Its [file listing](https://huggingface.co/apple/coreml-YOLOv3/tree/main), shown at abbreviated revision `d9f5961`, contains full YOLOv3, FP16, and Int8 LUT variants. It does **not** contain Tiny variants. No license inference was made from full YOLOv3 to Tiny.
- [Apple's live-capture example](https://developer.apple.com/documentation/vision/recognizing-objects-in-live-capture) explains Vision object observations, but its example model was trained with Turi Create. The example's behavior and code terms are not evidence about the gallery Tiny artifact's schema or license.

| Provenance field | Status |
|---|---|
| Candidate identity | Gallery `YOLOv3TinyFP16.mlmodel` |
| Exact artifact version / immutable URL | Not pinned; no acquisition approved |
| SHA-256 | Not available; bytes were not downloaded |
| Evaluation license | Not established for this exact artifact |
| Redistribution / commercial rights | Not established |
| Training-data provenance and terms | Not independently established for the converted artifact |
| Input geometry / channels / normalization | Not inspected |
| Output schema / labels / cell-phone class | Not inspected or asserted |
| Core ML deployment compatibility | Not inspected |
| Detection or power measurements | None |

The local `VNCoreMLRequest` header explicitly distinguishes classification, object-recognition, image, and generic feature-value outputs. A future adapter must inspect the acquired model and reject incompatible observations; it must not assume every Core ML model returns `VNRecognizedObjectObservation`.

## Candidate shortlist — not adopted

| Candidate | Evidence checked | Unresolved work before acquisition/integration |
|---|---|---|
| YOLOX-Nano, then Tiny | [Official README](https://github.com/Megvii-BaseDetection/YOLOX/blob/main/README.md) links Nano/Tiny checkpoints from release `0.1.1rc0`; both use 416 px inputs. [Source license](https://github.com/Megvii-BaseDetection/YOLOX/blob/main/LICENSE) is Apache-2.0. [Release page](https://github.com/Megvii-BaseDetection/YOLOX/releases/tag/0.1.1rc0) identifies abbreviated source commit `e1052df`. | Establish exact checkpoint/data terms and full source pin; obtain checksum only after permissible acquisition; review safe loading; isolate and pin conversion tooling; validate upstream/Core ML parity. No conversion begun. |
| Torchvision SSDLite | [Torchvision source](https://github.com/pytorch/vision/blob/main/torchvision/models/detection/ssdlite.py) is a candidate implementation. The [upstream README's pretrained-model section](https://github.com/pytorch/vision/blob/main/README.md#pre-trained-model-license) explicitly separates possible model/data terms from the library license. | Review a pinned weight's actual terms and data provenance, conversion compatibility, IO, and parity. Library licensing alone is insufficient. No checkpoint acquired. |
| Apple-hosted full YOLOv3 FP16 | The Apple model card above declares MIT metadata for the full variant. | Verify complete applicable notice/rights and artifact identity before acquisition. Larger full-model inference cost has not been tested; do not silently substitute it for the requested Tiny baseline. |

No upstream code, weights, test images, or sound assets were copied. No dependency installation, Python environment, remote installation script, model conversion, or cloud service was used. The shortlist is not a list of approved artifacts.

## Next smallest model task

This task is parked. After the direction change the app does not depend on a phone-object detector, so nothing below is being worked on. It stays here in case a detector is wanted later as an extra signal.

Obtain authoritative terms attached to the exact Tiny FP16 artifact (including attribution and redistribution conditions), or establish equivalent evidence for a specific fallback checkpoint. Record a full source revision, immutable download origin, training-data provenance, and permission scope before acquisition. After permissible download, record SHA-256, inspect all IO and labels, assert a cell-phone class, then test actual Vision output types and the same frame's original/mirrored coordinates. Keep uncleared weights outside tracked source. If this cannot be established, retain the camera/classifier prototype and report the blocker.

Live classifier observations, real object-localization results, misses, and resource measurements belong in `docs/poc-results.md`; none are implied by this research record.
