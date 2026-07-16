// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChromaticTunerCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TunerCore", targets: ["TunerCore"])],
    targets: [
        .target(name: "TunerCore"),
        .testTarget(name: "TunerCoreTests", dependencies: ["TunerCore"])
    ]
)
