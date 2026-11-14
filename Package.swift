// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TabFlow",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TabFlow",
            path: "Sources/TabFlow",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
