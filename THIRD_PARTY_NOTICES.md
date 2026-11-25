# Third-party notices — Milestone 0

Reviewed 25 November 2026.

This increment bundles no third-party model weights, downloaded datasets, copied application code, third-party runtime, fonts, sound assets, or analytics SDKs. The app uses Apple's system frameworks supplied by macOS. The Vision requests it calls (image classifier, face rectangles, person segmentation, hand pose) and the SoundAnalysis sound classifier are operating-system facilities accessed through their public APIs; their model weights are not copied into this repository or redistributed by the app.

## Evaluated but not included

The following entries are a research inventory, not redistribution notices for bundled components and not approval to download or ship them:

| Candidate | Source / terms evidence | Inclusion status |
|---|---|---|
| Apple gallery YOLOv3Tiny FP16 | [Apple model gallery](https://developer.apple.com/machine-learning/models/); exact converted artifact terms unresolved | Not downloaded or bundled; no checksum available |
| Darknet | [Upstream LICENSE](https://github.com/pjreddie/darknet/blob/master/LICENSE), public-domain dedication for Darknet | No code or weights copied; does not by itself clear the Apple artifact |
| Apple `coreml-YOLOv3` full variants | [Apple model card](https://huggingface.co/apple/coreml-YOLOv3/blob/main/README.md), MIT metadata | Not downloaded; metadata not applied to Tiny |
| YOLOX-Nano / Tiny | [YOLOX LICENSE](https://github.com/Megvii-BaseDetection/YOLOX/blob/main/LICENSE), Apache-2.0 source license | No source/checkpoints copied; exact weight/data terms unresolved |
| Torchvision SSDLite | [Torchvision pretrained-model disclaimer](https://github.com/pytorch/vision/blob/main/README.md#pre-trained-model-license) | Not installed or downloaded; model terms need separate review |

Taskmaster, Doom-Scroll-Detection, and Ultralytics packages/weights are not incorporated. Naming them in the product specification does not adopt their code or license.

Before any external artifact is added, update this file with its exact name/version, source revision, artifact checksum, complete required copyright/license/NOTICE text, changes made, and redistribution conditions. See `docs/model-evaluation.md` for the evidence and open questions. This document intentionally supplies no invented license or blanket commercial approval.
