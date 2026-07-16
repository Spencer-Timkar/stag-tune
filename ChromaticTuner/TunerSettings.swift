import Foundation

enum AccidentalPreference: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case sharps = "Sharps"
    case flats = "Flats"

    var id: String { rawValue }
}

struct TunerConfiguration: Equatable {
    var referencePitch: Double = 440
    var tolerance: Double = 10
    var accidentalPreference: AccidentalPreference = .automatic
    var hapticsEnabled = true
    var reverseDirection = false
}
