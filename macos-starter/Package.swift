// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Englishwords",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Englishwords", targets: ["Englishwords"])
    ],
    targets: [
        .executableTarget(
            name: "Englishwords",
            path: "Sources/Englishwords",
            resources: [
                .copy("Resources/dictionary.sqlite"),
                .copy("Resources/wordparts.sqlite"),
                .copy("Resources/THIRD-PARTY-NOTICES.md")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Translation"),
                .linkedFramework("CoreServices")
            ]
        ),
        .testTarget(
            name: "EnglishwordsTests",
            dependencies: ["Englishwords"],
            path: "Tests/EnglishwordsTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
