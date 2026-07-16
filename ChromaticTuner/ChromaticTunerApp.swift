import SwiftUI

@main
struct ChromaticTunerApp: App {
    var body: some Scene {
        WindowGroup {
            TunerView()
                .preferredColorScheme(.dark)
        }
    }
}
