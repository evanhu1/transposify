// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Transposify",
    platforms: [.macOS(.v15)],
    targets: [
        // Rubber Band Library (R3 engine), vendored as its single-file build.
        // Apple platforms use the vDSP FFT, so it needs the Accelerate framework.
        .target(
            name: "CRubberBand",
            path: "Sources/CRubberBand",
            sources: ["single/RubberBandSingle.cpp"],
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .executableTarget(
            name: "Transposify",
            dependencies: ["CRubberBand"],
            path: "Sources/Transposify"
        ),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
