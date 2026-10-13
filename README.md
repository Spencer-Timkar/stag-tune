# Stag Tune

Contact spencer@timkar.com for support!

A portrait-first chromatic tuner for iPhone. Pitch is analyzed entirely on-device and
shown as a rolling chromatic scale: the note you are closest to stays at the center of
the screen while the scale slides past it, and a ±50-cent meter fixed at dead center
shows how sharp or flat you are.

## What it does

- Monophonic pitch detection from the microphone
- Smooth cent-space tracking over a ±50-cent field
- Large note and cents readout
- Haptic confirmation after a stable in-tune reading
- Portrait-only layout and automatic screen-awake behavior
- No accounts, network calls, recordings, or ads

## Free and Stag Pro

Tuning is free and unlimited. Stag Pro is a one-time purchase that unlocks the controls
that change how the tuner behaves:

| Setting | Free | Stag Pro |
| --- | --- | --- |
| Concert A | 440 Hz | 390–490 Hz |
| In-tune tolerance | ±10 cents | ±1–10 cents |
| Accidentals | Automatic | Automatic, sharps, or flats |
| Display direction | Sharp moves up | Reversible |

## Running

Open `ChromaticTuner.xcodeproj` in Xcode, choose a connected iPhone, set your development
team and bundle identifier if needed, and run.

A physical iPhone is required for microphone detection. On the simulator the app never
opens an audio input — CoreSimulator deadlocks at `AVAudioEngine.inputNode` — so it shows
"Use iPhone for microphone" instead.

## Layout

- `ChromaticTuner/` — the SwiftUI app: views, settings, the audio engine, and StoreKit
- `Sources/TunerCore/` — the pitch detector and tracker, built as a Swift package that the
  app links as `TunerCore`
- `Tests/TunerCoreTests/` — detector, continuity-filter, and tracker tests
- `docs/` — detection validation notes and the published privacy policy

The Xcode target, the app product, and the package keep their original `Chromatic` names.

## Tests

`swift test` runs the package suite when a matching Command Line Tools SDK is installed.
Setting `TUNER_RECORDING_PCM` to a mono 48 kHz Float32 PCM file additionally replays a real
guitar recording through the detector and the tracker; `docs/detection-validation.md`
records the measured results.
