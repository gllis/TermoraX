// swift-tools-version:6.0
// SwiftTerm v1.19.0 (https://github.com/migueldeicaza/SwiftTerm/releases/tag/v1.19.0)
// Vendored for TermoraX: build plugin omitted so Xcode can compile this local package.

import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md", "Apple/Metal/Shaders.metal"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
