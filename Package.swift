// swift-tools-version: 6.0
import Foundation
import PackageDescription

// With only the Command Line Tools (no Xcode), Swift Testing lives outside the default search paths. A build that
// picks Xcode through DEVELOPER_DIR (CI does) finds it by itself and must not mix in the tools' copy.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let cltDevLibs = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let usesXcode = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]?.contains(".app/") == true
let testingSwiftFlags: [SwiftSetting] = usesXcode ? [] : [.unsafeFlags(["-F", cltFrameworks, "-plugin-path", cltTestingPlugins])]
let testingLinkerFlags: [LinkerSetting] = usesXcode ? [] : [
    .unsafeFlags(["-F", cltFrameworks, "-framework", "Testing", "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
                  "-Xlinker", "-rpath", "-Xlinker", cltDevLibs]),
]

let package = Package(
    name: "Mate",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Mate", targets: ["Mate"]),
    ],
    targets: [
        .target(
            name: "MateCore",
            path: "Sources/MateCore"
        ),
        .executableTarget(
            name: "Mate",
            dependencies: ["MateCore"],
            path: "Sources/Mate",
            linkerSettings: [
                .linkedFramework("ServiceManagement"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "MateCoreTests",
            dependencies: ["MateCore"],
            path: "Tests/MateCoreTests",
            swiftSettings: testingSwiftFlags,
            linkerSettings: testingLinkerFlags
        ),
    ],
    swiftLanguageModes: [.v5]
)
