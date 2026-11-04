# Decisions

- Timeline remains the persisted-intent and derived container; the Project split is deferred.
- ZoomSegment uses source time; the UI converts through TimeMap.
- Reveal tilt does not scale below 1×, avoiding outside-source pixels.
- The default minimum zoom scale is 1.5; 1.3 is barely visible.
- The default speed-ramp minimum idle is 4 seconds.
- Multi-clip, epochs, and pause markers are deferred to Part 6.
- SensitivePatterns, fnv1a64, and stableUUID live in LumenCore; LumenAnalysis does not import LumenDirector.
- FaceSample and ActivityPoint are shared plain values in LumenProject.
- Layout data is sampled at 120 Hz; webcam placement is sampled at 60 Hz and linearly interpolated.
- Reveal tilt never scales below 1×, avoiding pixels outside the source.
- OCR samples at 2 Hz with change detection and never stores raw recognized text. Mask tracks use 0.6 s lead/tail and bridge detections across 1.6 s.
- Automatically approved privacy categories are apiKey, jwt, privateKey, envSecret, card, email, and custom; phone and entropy detections remain proposed.
- Speech recognition is on-device only; SpeechAnalyzer and whisper are deferred.
- Transcription reads the raw microphone track; VAD remains in LumenAudio.
- Set LUMEN_NO_OCR=1 to disable sensitive-text OCR analysis.
- Person segmentation is cached as a compact grayscale .lmask sequence; renderer integration is deferred to Part 5.
