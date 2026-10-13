import Foundation

enum AccidentalPreference: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case sharps = "Sharps"
    case flats = "Flats"

    var id: String { rawValue }
}

/// Note spelling for one chromatic octave, indexed by MIDI pitch class.
enum NoteNaming {
    private static let sharpNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    private static let flatNames = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]

    /// Pitch classes that read better as a flat in the keys players actually use.
    /// E♭, A♭, and B♭ are the staple flat-key degrees and the notes of a
    /// half-step-down guitar tuning; C♯ and F♯ appear far more often in written
    /// music than their D♭ and G♭ enharmonic twins.
    private static let automaticFlatPitchClasses: Set<Int> = [3, 8, 10]

    static func name(for midiNote: Int, preference: AccidentalPreference) -> String {
        let pitchClass = (midiNote % 12 + 12) % 12
        let spelledFlat = preference == .flats
            || (preference == .automatic && automaticFlatPitchClasses.contains(pitchClass))
        return spelledFlat ? flatNames[pitchClass] : sharpNames[pitchClass]
    }
}

struct TunerConfiguration: Equatable {
    var referencePitch: Double = 440
    var tolerance: Double = 10
    var accidentalPreference: AccidentalPreference = .automatic
    var hapticsEnabled = true
    var reverseDirection = false
}
