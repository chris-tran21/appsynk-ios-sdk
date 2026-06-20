// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppSynk",
    platforms: [.iOS(.v14)],
    products: [
        // Default library — SPM chooses static or dynamic linkage based on the client.
        .library(name: "AppSynk", targets: ["AppSynk"]),
        // Static library, for when static linking is explicitly required.
        .library(name: "AppSynkStatic", type: .static, targets: ["AppSynk"]),
        // Dynamic library, for when dynamic linking is explicitly required.
        .library(name: "AppSynkDynamic", type: .dynamic, targets: ["AppSynk"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AppSynk",
            dependencies: [],
            path: "Sources/AppSynk"
        ),
        .testTarget(
            name: "AppSynkTests",
            dependencies: ["AppSynk"],
            path: "Tests/AppSynkTests"
        )
    ]
)
