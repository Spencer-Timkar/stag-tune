# Chromatic

A portrait-first chromatic tuner for iPhone. Pitch is analyzed entirely on-device and displayed as a smooth vertical trace: sharp rises, flat falls, and the target remains fixed at center.

## Current v1 prototype

- Monophonic pitch detection from the microphone
- Smooth cent-space tracking over a ±50-cent field
- Three-second fading pitch history
- Large note and cents readout
- Adjustable A reference from 390–490 Hz
- Adjustable ±1–10-cent tolerance
- Sharp/flat notation preference
- Haptic confirmation after a stable in-tune reading
- Portrait-only layout and automatic screen-awake behavior
- No accounts, network calls, recordings, or ads

## Running

Open `ChromaticTuner.xcodeproj` in Xcode, choose an iPhone or connected device, set your development team and bundle identifier if needed, and run. A physical iPhone is recommended for evaluating microphone detection and haptics.

The standalone pitch detector also has unit tests in `Tests/TunerCoreTests` and can be run with `swift test` when a matching Command Line Tools SDK is installed.
