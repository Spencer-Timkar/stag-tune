// swift-tools-version: 6.0
import PackageDescription

// The pitch detector and tracker live here and are linked into the app as the
// TunerCore product. They are not compiled into the app target directly, so a
// file added to Sources/TunerCore is picked up by both without a second place
// to register it.
let package = Package(
    name: "ChromaticTunerCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "TunerCore", targets: ["TunerCore"])],
    targets: [
        .target(name: "TunerCore"),
        .testTarget(name: "TunerCoreTests", dependencies: ["TunerCore"])
    ]
)
