# Noisy guitar detection validation

The October 13, 2026 guitar recording exposed false low-note detections during
upper-string playing. Detection now weights down low-frequency rumble, limits
upper-partial emphasis with a gentle low-pass, and compares equal-length sample
ranges at every YIN lag. RMS gating still uses the unweighted signal.

The display requires at least three consecutive observations to acquire a note
(40 ms minimum). Changes larger than 75 cents need 100 ms of consistent evidence;
changes larger than 7.5 semitones need 180 ms. Rejected or missing observations
break confirmation. Small tuning movements continue through the existing median
and adaptive smoothing. Hz, cents, and note now use the same smoothed estimate.

## Recording replay

Measured with 3,072-sample windows, 1,024-sample hops, 48 kHz mono audio, and the
production detector plus phase refiner. Matching means within 50 cents of the
expected open-string MIDI note. Missing detections count as nonmatching. These
are selected sustained-string intervals, not independently measured cents accuracy
or a live-device UI test.

| Audio interval | Expected string | Before | After |
| --- | --- | ---: | ---: |
| 12.2–14.0 seconds | G3 | 11/85 (12.9%) | 77/85 (90.6%) |
| 15.0–17.0 seconds | B3 | 3/93 (3.2%) | 83/93 (89.2%) |
| 18.0–21.0 seconds | E4 | 65/141 (46.1%) | 130/141 (92.2%) |

The personal recording is not stored in the repository. To run the optional
recording regression, decode the supplied `Guitar tuning test.m4a` locally:

```sh
ffmpeg -i '/path/to/Guitar tuning test.m4a' -ac 1 -ar 48000 -f f32le /tmp/tuner-test.f32
TUNER_RECORDING_PCM=/tmp/tuner-test.f32 swift test
```

That regression checks raw detection independently of phase refinement and display
smoothing, requiring more than 80% matching windows in each interval. Without the
environment variable, only the personal-recording test is skipped. Deterministic
tests cover quiet low E, upper strings mixed with rumble and broadband noise at
44.1/48 kHz, chromatic range, phase refinement, and note-change confirmation.

A live iPhone retest with the same guitar and fan is still needed to assess the
complete microphone-to-display experience. Strong tonal interference can still
compete with the instrument; these changes do not guarantee rejection of all fans.

## Device regression correction

The initial continuity filter reset whenever callbacks were more than 100 ms
apart. The idle timer also cleared pending acquisition every 100 ms because no
note had yet updated its timestamp. The original unit tests tested the detector
and confirmation separately, missing this interaction. A new test fails on that
original filter at 128, 186, and 256 ms callback intervals.

`PitchTracker` now owns acquisition, smoothing, and expiry and is used directly
by the app and replay tests. Expiry clears an existing reading once; it never
clears an empty display's pending acquisition. Consecutive observations can be
up to 500 ms apart before confirmation resets. Missing/rejected observations
still reset confirmation. Timestamps are captured at audio delivery, before
queueing analysis. Results from stopped/replaced audio sessions are ignored.

The suite now includes timer ticks between batched callbacks, expiry and
reacquisition, settings reset, invalid input, and the supplied recording through
the actual tracker at 1,024-, 4,800-, and 8,192-sample hops. All 24 tests passed
with both recording regressions enabled.

Xcode's captured crash was in CoreSimulator at `AVAudioEngine.inputNode`, with
"Cleanup: RPC timeout. Apparently deadlocked. Aborting now." Simulator launches
now skip microphone initialization and show "Use iPhone for microphone". Physical
iPhone recording remains enabled. Both iPhone and simulator builds compile.
The device disconnected before installation of the correction; the user elected
to perform the live-device retest themselves.
