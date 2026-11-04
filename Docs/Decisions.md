# Decisions

- Timeline remains the persisted-intent and derived container; the Project split is deferred.
- ZoomSegment uses source time; the UI converts through TimeMap.
- Reveal tilt does not scale below 1×, avoiding outside-source pixels.
- The default minimum zoom scale is 1.5; 1.3 is barely visible.
- The default speed-ramp minimum idle is 4 seconds.
- Multi-clip, epochs, and pause markers are deferred to Part 6.
