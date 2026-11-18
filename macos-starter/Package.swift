// swift-tools-version:6.0
import PackageDescription
import Foundation

let usesSparkle = ProcessInfo.processInfo.environment["EW_ENABLE_SPARKLE"] == "1"
let sparkleDependencies: [Target.Dependency] = usesSparkle ? [.target(name: "Sparkle")] : []
let sparkleTargets: [Target] = usesSparkle ? [
    .binaryTarget(name: "Sparkle", path: "scripts/.cache/sparkle-2.9.6/Sparkle.xcframework")
] : []
let sparkleLinkerSettings: [LinkerSetting] = usesSparkle ? [
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
] : []

let package = Package(
    name: "Englishwords",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Englishwords", targets: ["Englishwords"])
    ],
    targets: [
        .executableTarget(
            name: "Englishwords",
            dependencies: sparkleDependencies,
            path: "Sources/Englishwords",
            resources: [
                .copy("Resources/dictionary.sqlite"),
                .copy("Resources/wordparts.sqlite"),
                .copy("Resources/subtitle.js"),
                .copy("Resources/THIRD-PARTY-NOTICES.md")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedLibrary("z"),
                .linkedFramework("Translation"),
                .linkedFramework("CoreServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("ServiceManagement")
            ] + sparkleLinkerSettings
        ),
        .testTarget(
            name: "EnglishwordsTests",
            dependencies: ["Englishwords"],
            path: "Tests/EnglishwordsTests",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ] + sparkleTargets,
    swiftLanguageModes: [.v5]
)
